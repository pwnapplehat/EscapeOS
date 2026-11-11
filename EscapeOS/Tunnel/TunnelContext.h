//
//  TunnelContext.h
//  EscapeOS
//
//  Two LocalDevVPN paths, same pairing file iLoader writes (lockdown + RP keys):
//  iOS 26.4+ uses RPPairing/RSD on 10.7.0.1:49152. Try that first, then lockdown
//  TCP on port 62078.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "idevice.h"

NS_ASSUME_NONNULL_BEGIN

@interface TunnelContext : NSObject {
    @protected struct AdapterHandle *_adapter;
    @protected struct RsdHandshakeHandle *_handshake;
    @protected struct IdeviceProviderHandle *_provider;
    @protected BOOL _tunnelConnecting;
    @protected NSError *_Nullable _lastTunnelError;
}

@property (class, readonly) TunnelContext *shared;

/// Whether a pairing file is present on disk.
@property (nonatomic, readonly) BOOL hasPairingFile;

/// Save a user-imported pairing file (contents of a .mobiledevicepairing plist).
- (BOOL)savePairingFile:(NSString *)contents error:(NSError **)error;

/// Remove the stored pairing file.
- (void)resetPairingFile;

/// Connect over LocalDevVPN. Tries Remote Pairing (iOS 26.4+), then lockdown.
/// Returns YES on success; on failure fills error.
- (BOOL)startHeartbeat:(NSError **)error;

/// Start the tunnel only if no RSD or lockdown provider is already up.
- (BOOL)ensureHeartbeatWithError:(NSError **)error;

/// Enumerate all installed apps (full info dictionaries). Requires tunnel.
- (nullable NSDictionary<NSString *, NSDictionary *> *)getAllAppsInfoWithError:(NSError **)error;

/// Fetch an app's SpringBoard icon PNG.
- (nullable UIImage *)getAppIconWithBundleId:(NSString *)bundleId error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
