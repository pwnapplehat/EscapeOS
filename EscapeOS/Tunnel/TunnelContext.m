//
//  TunnelContext.m
//  EscapeOS
//
//  RPPairing tunnel over LocalDevVPN loopback (default 10.7.0.1:49152).
//  Adapted from StikDebug's JITEnableContext / IdeviceFFIBridge (iOS 26.4+ path).
//

#import "TunnelContext.h"
#import "applist.h"
#import "heartbeat.h"
#include <arpa/inet.h>
#include <os/lock.h>

#define RPPPAIRING_PORT 49152
#define DEFAULT_TUNNEL_IP @"10.7.0.1"

@implementation TunnelContext {
    os_unfair_lock _tunnelLock;
    dispatch_semaphore_t _tunnelSemaphore;
}

+ (instancetype)shared {
    static TunnelContext *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [[TunnelContext alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _adapter = NULL;
        _handshake = NULL;
        _provider = NULL;
        _tunnelConnecting = NO;
        _tunnelLock = OS_UNFAIR_LOCK_INIT;
        _tunnelSemaphore = NULL;
        _lastTunnelError = nil;

        NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSString *logPath = [docs URLByAppendingPathComponent:@"idevice_log.txt"].path;
        idevice_init_logger(Debug, Debug, (char *)logPath.fileSystemRepresentation);
    }
    return self;
}

- (NSError *)_error:(NSString *)msg code:(int)code {
    return [NSError errorWithDomain:@"EscapeOS.Tunnel" code:code
        userInfo:@{ NSLocalizedDescriptionKey: msg }];
}

- (NSURL *)_pairingFileURL {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [docs URLByAppendingPathComponent:@"pairingFile.plist"];
}

- (BOOL)hasPairingFile {
    return [NSFileManager.defaultManager fileExistsAtPath:self._pairingFileURL.path];
}

- (BOOL)savePairingFile:(NSString *)contents error:(NSError **)error {
    BOOL looksLikePairing = [contents containsString:@"DeviceCertificate"]
        || ([contents containsString:@"identifier"] && [contents containsString:@"public_key"]);
    if (!looksLikePairing) {
        if (error) *error = [self _error:@"That file is not a valid pairing file." code:-2];
        return NO;
    }
    return [contents writeToURL:self._pairingFileURL atomically:YES encoding:NSUTF8StringEncoding error:error];
}

- (void)resetPairingFile {
    [NSFileManager.defaultManager removeItemAtURL:self._pairingFileURL error:nil];
    [self _freeTunnelHandles];
}

- (void)_freeTunnelHandles {
    if (_provider) {
        globalHeartbeatToken++;
        idevice_provider_free(_provider);
        _provider = NULL;
    }
    if (_handshake) {
        rsd_handshake_free(_handshake);
        _handshake = NULL;
    }
    if (_adapter) {
        adapter_free(_adapter);
        _adapter = NULL;
    }
}

- (NSString *)_targetIP {
    NSString *deviceIP = [[NSUserDefaults standardUserDefaults] stringForKey:@"TunnelDeviceIP"];
    if (!deviceIP || deviceIP.length == 0) {
        return DEFAULT_TUNNEL_IP;
    }
    return deviceIP;
}

- (struct RpPairingFileHandle *)_loadPairingFile:(NSError **)error {
    NSString *path = self._pairingFileURL.path;
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        if (error) *error = [self _error:@"Pairing file not found. Sideload EscapeOS with iPASide so it can place pairingFile.plist, or import one here." code:-17];
        return NULL;
    }
    struct RpPairingFileHandle *pf = NULL;
    struct IdeviceFfiError *err = rp_pairing_file_read(path.fileSystemRepresentation, &pf);
    if (err) {
        if (error) *error = [self _error:[NSString stringWithFormat:@"Failed to read pairing file: %s", err->message] code:err->code];
        idevice_error_free(err);
        return NULL;
    }
    return pf;
}

- (BOOL)_fillSockaddr:(struct sockaddr_in *)addr port:(uint16_t)port error:(NSError **)error {
    memset(addr, 0, sizeof(*addr));
    addr->sin_family = AF_INET;
    addr->sin_port = htons(port);
    NSString *deviceIP = [self _targetIP];
    if (inet_pton(AF_INET, deviceIP.UTF8String, &addr->sin_addr) != 1) {
        if (error) *error = [self _error:[NSString stringWithFormat:@"Failed to parse target IP address: %@", deviceIP] code:-18];
        return NO;
    }
    return YES;
}

- (BOOL)_createRpTunnel:(NSError **)error {
    struct RpPairingFileHandle *pairingFile = [self _loadPairingFile:error];
    if (!pairingFile) {
        return NO;
    }

    struct sockaddr_in addr;
    if (![self _fillSockaddr:&addr port:RPPPAIRING_PORT error:error]) {
        rp_pairing_file_free(pairingFile);
        return NO;
    }
    NSLog(@"[EscapeOS] RPPairing tunnel target %@:%d", [self _targetIP], RPPPAIRING_PORT);

    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;
    struct IdeviceFfiError *err = tunnel_create_rppairing(
        (const idevice_sockaddr *)&addr,
        (idevice_socklen_t)sizeof(addr),
        "EscapeOS",
        pairingFile,
        NULL,
        NULL,
        &adapter,
        &handshake
    );
    rp_pairing_file_free(pairingFile);

    if (err) {
        if (error) *error = [self _error:[NSString stringWithFormat:@"%s", err->message] code:err->code];
        idevice_error_free(err);
        if (handshake) rsd_handshake_free(handshake);
        if (adapter) adapter_free(adapter);
        return NO;
    }

    if (!adapter || !handshake) {
        if (handshake) rsd_handshake_free(handshake);
        if (adapter) adapter_free(adapter);
        if (error) *error = [self _error:@"Tunnel was created without valid handles." code:-1];
        return NO;
    }

    [self _freeTunnelHandles];
    _adapter = adapter;
    _handshake = handshake;
    return YES;
}

- (BOOL)_createClassicTunnel:(NSError **)error {
    NSString *path = self._pairingFileURL.path;
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        if (error) *error = [self _error:@"Pairing file not found. Sideload EscapeOS with iPASide so it can place pairingFile.plist, or import one here." code:-17];
        return NO;
    }

    struct IdevicePairingFile *pf = NULL;
    struct IdeviceFfiError *err = idevice_pairing_file_read(path.fileSystemRepresentation, &pf);
    if (err) {
        if (error) *error = [self _error:[NSString stringWithFormat:@"Failed to read pairing file: %s", err->message] code:err->code];
        idevice_error_free(err);
        return NO;
    }

    NSLog(@"[EscapeOS] lockdown loopback target %@:%d", [self _targetIP], LOCKDOWN_PORT);

    __block IdeviceProviderHandle *provider = NULL;
    __block int hbCode = -1;
    __block NSString *hbMsg = nil;
    dispatch_semaphore_t firstBeat = dispatch_semaphore_create(0);
    int token = ++globalHeartbeatToken;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        startHeartbeat(pf, &provider, token, ^(int result, const char *message) {
            hbCode = result;
            hbMsg = message ? @(message) : nil;
            dispatch_semaphore_signal(firstBeat);
        });
    });

    if (dispatch_semaphore_wait(firstBeat, dispatch_time(DISPATCH_TIME_NOW, (uint64_t)(20 * NSEC_PER_SEC))) != 0) {
        globalHeartbeatToken++;
        if (error) *error = [self _error:@"Timed out on the LocalDevVPN lockdown tunnel. Enable LocalDevVPN, stay on Wi-Fi, and use a pairing file from iPASide or iLoader." code:-9];
        return NO;
    }
    if (hbCode != 0 || provider == NULL) {
        if (error) *error = [self _error:(hbMsg ?: @"Lockdown tunnel over LocalDevVPN failed.") code:hbCode];
        return NO;
    }

    if (_handshake) {
        rsd_handshake_free(_handshake);
        _handshake = NULL;
    }
    if (_adapter) {
        adapter_free(_adapter);
        _adapter = NULL;
    }
    if (_provider && _provider != provider) {
        idevice_provider_free(_provider);
    }
    _provider = provider;
    return YES;
}

- (BOOL)_createTunnel:(NSError **)error {
    NSError *rpErr = nil;
    if ([self _createRpTunnel:&rpErr]) {
        return YES;
    }
    NSError *classicErr = nil;
    if ([self _createClassicTunnel:&classicErr]) {
        return YES;
    }
    NSString *rpText = rpErr.localizedDescription ?: @"Remote Pairing did not connect";
    NSString *classicText = classicErr.localizedDescription ?: @"lockdown loopback did not connect";
    if (error) {
        *error = [self _error:[NSString stringWithFormat:@"%@ %@ Enable LocalDevVPN on 10.7.0.1, stay on Wi-Fi. The PC is not needed after the pairing file is placed.", rpText, classicText] code:-1];
    }
    return NO;
}

- (BOOL)startHeartbeat:(NSError **)error {
    os_unfair_lock_lock(&_tunnelLock);
    if (_tunnelConnecting) {
        dispatch_semaphore_t sem = _tunnelSemaphore;
        os_unfair_lock_unlock(&_tunnelLock);
        if (sem) { dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER); dispatch_semaphore_signal(sem); }
        if (error) *error = _lastTunnelError;
        return _lastTunnelError == nil;
    }
    _tunnelConnecting = YES;
    _tunnelSemaphore = dispatch_semaphore_create(0);
    dispatch_semaphore_t completionSem = _tunnelSemaphore;
    os_unfair_lock_unlock(&_tunnelLock);

    __block NSError *blockErr = nil;
    __block BOOL done = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSError *createErr = nil;
        BOOL ok = [self _createTunnel:&createErr];
        if (done) return;
        done = YES;
        if (!ok) {
            blockErr = createErr ?: [self _error:@"Failed to connect over LocalDevVPN." code:-1];
            self->_lastTunnelError = blockErr;
        } else {
            self->_lastTunnelError = nil;
        }
        dispatch_semaphore_signal(sem);
    });

    intptr_t timedOut = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (uint64_t)(45 * NSEC_PER_SEC)));
    if (timedOut && !done) {
        done = YES;
        blockErr = [self _error:@"Timed out connecting to the local tunnel. Enable LocalDevVPN with its default Device/Tunnel IPs (10.7.0.1), stay on Wi-Fi, and use a pairing file from iPASide." code:-9];
        self->_lastTunnelError = blockErr;
    }

    os_unfair_lock_lock(&_tunnelLock);
    _tunnelConnecting = NO;
    _tunnelSemaphore = NULL;
    os_unfair_lock_unlock(&_tunnelLock);
    dispatch_semaphore_signal(completionSem);

    if (error) *error = blockErr;
    return blockErr == nil;
}

- (BOOL)ensureHeartbeatWithError:(NSError **)error {
    if ((_adapter && _handshake) || _provider) {
        return YES;
    }
    return [self startHeartbeat:error];
}

- (NSDictionary<NSString *, NSDictionary *> *)getAllAppsInfoWithError:(NSError **)error {
    if (_adapter && _handshake) {
        NSString *errStr = nil;
        NSDictionary *apps = getAllAppsInfo(_adapter, _handshake, &errStr);
        if (errStr) {
            if (error) *error = [self _error:errStr code:-17];
            return nil;
        }
        return (NSDictionary<NSString *, NSDictionary *> *)apps;
    }
    if (_provider) {
        NSString *errStr = nil;
        NSDictionary *apps = getAllAppsInfoFromProvider(_provider, &errStr);
        if (errStr) {
            if (error) *error = [self _error:errStr code:-17];
            return nil;
        }
        return (NSDictionary<NSString *, NSDictionary *> *)apps;
    }
    if (error) *error = [self _error:@"Tunnel not connected. Start heartbeat first." code:-1];
    return nil;
}

- (UIImage *)getAppIconWithBundleId:(NSString *)bundleId error:(NSError **)error {
    if (_adapter && _handshake) {
        NSString *errStr = nil;
        UIImage *icon = getAppIcon(_adapter, _handshake, bundleId, &errStr);
        if (errStr) {
            if (error) *error = [self _error:errStr code:-17];
            return nil;
        }
        return icon;
    }
    if (_provider) {
        NSString *errStr = nil;
        UIImage *icon = getAppIconFromProvider(_provider, bundleId, &errStr);
        if (errStr) {
            if (error) *error = [self _error:errStr code:-17];
            return nil;
        }
        return icon;
    }
    if (error) *error = [self _error:@"Tunnel not connected." code:-1];
    return nil;
}

- (void)dealloc {
    [self _freeTunnelHandles];
}

@end
