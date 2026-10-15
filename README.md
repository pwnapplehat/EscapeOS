<div align="center">

<img src="docs/brand/icon.png" alt="EscapeOS" width="128" height="128">

# EscapeOS

On-device file browser and App Store app-data backup/restore for sideloaded iOS, using a path-scoped container sandbox escape. No jailbreak. No Keychain.

**Sideload the IPA with [iPASide](https://github.com/pwnapplehat/iPASide)** (Windows). iPASide creates the same kind of pairing file as [iLoader](https://iloader.site/docs/) and places `pairingFile.plist` after install. An iLoader file can be imported instead. After that, the PC is not required — EscapeOS talks to this iPhone over LocalDevVPN.

</div>

## What it does

- Lists installed user apps through LocalDevVPN + `pairingFile.plist` in Documents. Search by name or bundle ID; A–Z letters on the right jump the list.
- Browses an app Data container (`Documents`, `Library`, `tmp`) after consuming a `bad_query` sandbox extension for that container UUID.
- Creates, previews, edits, and shares files in that container (share keeps the original name). **Import from Files** asks Replace, Keep Both, or Cancel when that name already exists. Compress makes a zip of files and folders in the current directory. Tap zip, 7z, tar, gz, bz2, xz, lz4, lzma, or deb to extract; encrypted zip and 7z ask for a password. RAR is not unpackable. Select in the top right for multi-select Copy, Cut, Paste, Compress, Duplicate, and Delete. Copy Path / Copy Bundle ID put text on the system clipboard and show a confirmation.
- Exports a zip + `manifest.json` (SHA-256 per file) into Files → On My iPhone → EscapeOS → Backups, and restores that archive into the same app's current container. Each backup has **Share / Save to Files**.
- **Search Whole App** finds a file or folder by name anywhere in an app's data. **Favorites** keeps files and folders one tap away at the top of the Apps tab.
- Asks before it deletes: files and folders confirm (a file can opt out with Don’t Ask Again, which Settings can turn back on), as does deleting a backup. Pasting a name that already exists asks Replace, Keep Both, or Cancel. Compress, Share Zip, Duplicate, Paste, Import and Backup check free space first and stop with a clear message instead of failing late.
- **Reclaim** ranks apps by cache/tmp size and can empty Safe buckets (`tmp`, `Library/Caches`, logs, splash snapshots). Session buckets (cookies, WebKit) are opt-in per app. Documents, Preferences, and Application Support are never reclaimed.
- **Reset App Data** on an app’s detail screen empties that app’s Documents, Library, and tmp. It does not touch Keychain or App Groups.

## What it does not do

- Keychain
- Other apps' App Groups
- System paths (`/var/mobile`, parent container directories)
- The app's signed `.app` bundle (Data container only)
- iOS 15, 16, or 17 (the IPA will not install; `MinimumOSVersion` is 18.0)

## Compatibility

The IPA will install on iOS 18.0 or later (`MinimumOSVersion` 18.0). **Opening another app's Data container** uses [bad_query](https://github.com/forcequitOS/bad_query), whose upstream range is **iOS 26.0 through 26.6.1**, plus **iOS 27.0 beta 4** only. Builds outside that list are unsupported, not assumed.

| System | `bad_query` (browse / backup) | App listing (LocalDevVPN) | Hardware |
|---|---|---|---|
| iOS 18.0 – 18.x | Untested upstream (“might also work”). | In this build: lockdown loopback `10.7.0.1:62078`. | **Not tested here** |
| iOS 26.0 – 26.3 | Upstream: yes (26.0–26.6.1). | Remote Pairing listing is a **26.4+** recipe; lockdown on these builds is untested. | **Not tested here** |
| iOS 26.4 – 26.6.1 | Upstream: yes. | Remote Pairing / RSD `10.7.0.1:49152`. | **Verified** 26.5.1 (iPhone 17: list, browse, Select/copy-paste, backup, pairing place, Compress/Extract, share names, Reclaim, Reset App Data) |
| iOS 26.7 and later | **Unsupported** (outside bad_query). | — | — |
| iOS 27.0 beta 4 | Upstream: yes. | Untested here. | **Not tested here** |
| iOS 27.0 beta 5 and later | **Unsupported** (outside bad_query). | — | — |

iOS 15, 16, and 17 cannot install this IPA.

## Requirements

On a compatible build above: phone + LocalDevVPN + Wi-Fi. No USB while using the app.

| | iOS 18 | iOS 26.4 – 26.6.1 |
|---|---|---|
| **App listing** | Lockdown loopback on `10.7.0.1:62078` (StikDebug 17.4–18 recipe). | Remote Pairing / RSD on `10.7.0.1:49152` (StikDebug 3.1+ / iOS 26.4 recipe). |
| **Pairing file** | USB-trust (lockdown) keys are enough. iPASide still writes Remote Pairing keys into the same file. | Lockdown-only files fail. File must include Remote Pairing keys (`identifier`, Ed25519 `public_key` / `private_key`). |

Also required:

- [LocalDevVPN](https://apps.apple.com/app/id6755608044) on default `10.7.0.1`
- Wi-Fi on
- Pairing file from [iPASide](https://github.com/pwnapplehat/iPASide) (Create keys / Place) or iLoader import. PC is only for minting and placing that file.

## Sideload

1. Install [iPASide](https://github.com/pwnapplehat/iPASide/releases/latest) on Windows.
2. Sideload `EscapeOS.ipa` from this repo's [Releases](https://github.com/pwnapplehat/EscapeOS/releases).
3. Trust the developer profile on the iPhone.
4. iPASide places `pairingFile.plist` automatically after sideload. To do it later: Settings → Pairing file → Place.
5. Unplug if you want. Install LocalDevVPN, connect it, leave Wi-Fi on, then open EscapeOS.

## Why a pairing file (not House Arrest)

House Arrest is a **PC → phone** lockdown service. iPASide uses it to write `pairingFile.plist` into EscapeOS's Documents (same path as Files sharing). That is how the pairing file *arrives*. It is not a way for EscapeOS, running on the iPhone, to see other apps.

A sideloaded app cannot enumerate other apps or their Data containers by itself (`LSApplicationWorkspace` and listing `/var/mobile/Containers/…` stay blocked). EscapeOS therefore:

1. Uses the pairing file over LocalDevVPN to talk to `installation_proxy` as a trusted host, which is what fills the app list and each Data-container path.
2. Opens that container with `bad_query` so Documents, Library, and tmp are all reachable. House Arrest's usual `VendDocuments` is Documents-only, and only for apps that enabled file sharing.

Without the pairing file there is no app list and no container paths to open. Keep using iPASide **Place** (or import an iLoader file). The PC is not needed after that.

## Build (Theos / WSL)

This tree is built with Theos against the iPhoneOS 16.5 SDK, deployment target **iOS 18.0** (Linux clang). That IPA is what was verified on iOS 26.5.1. A Mac with Xcode 26 can relink against the iOS 26 SDK for Liquid Glass; see `docs/BUILD.md`.

```sh
export THEOS=~/theos
cd ~/apps/EscapeOS
make package FINALPACKAGE=1
# staged app: .theos/_/Applications/EscapeOS.app
```

After reinstall, place `pairingFile.plist` again from the PC: iPASide Settings → Pairing file → Place (House Arrest), or share the file in Files.

## License

[GNU AGPL-3.0](LICENSE). Third-party origins are listed in [NOTICE](NOTICE): StikDebug adaptations (AGPL-3.0), `jkcoxson/idevice` (MIT), SWCompression / BitByteData (MIT), and `forcequitOS/bad_query` (no upstream license at adaptation time).
