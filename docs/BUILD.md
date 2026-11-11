# Building EscapeOS

## iOS 26 Liquid Glass tab bar

Apple’s floating Liquid Glass tab bar is applied automatically when the app is **linked against the iOS 26 SDK (Xcode 26)**. This is an OS-level “linked on or after” rule — runtime hacks or custom blur styling cannot substitute for it.

| Build environment | Tab bar appearance | Use case |
|---|---|---|
| **Xcode 26 on macOS** (iOS 26 SDK) | Native Liquid Glass | App Store / public release |
| **Theos on Linux/WSL** (iPhoneOS 16.5 SDK) | Legacy system tab bar | Local sideload / dev |

Do **not** set `UIDesignRequiresCompatibility` in `Info.plist` for release builds — that flag opts out of Liquid Glass.

### Public release (recommended)

1. Open the project on a Mac with **Xcode 26**.
2. Build with the iOS 26 SDK (deployment target iOS 18).
3. Archive and export the IPA for distribution.

The shipping UI is SwiftUI `TabView` in `RootView`. Linking against the iOS 26 SDK is what enables Liquid Glass; Theos/WSL cannot do that because it uses the iPhoneOS 16.5 SDK.

### Local sideload (WSL Theos)

```bash
export THEOS=~/theos
cd ~/apps/EscapeOS
make clean package
```

The Makefile pins `iphone:clang:16.5:18.0` because newer Apple SDKs require Xcode’s Apple Clang and fail under Linux clang.

On a repo checked out on a Windows drive (`/mnt/g/...`), `make package` stops at
`control directory has bad permissions 777`, because drvfs ignores `chmod`. Build
the app in release mode and make the IPA by hand, which is the same payload `package`
would have produced:

```bash
make clean && make FINALPACKAGE=1
rm -rf _scratch && mkdir -p _scratch/Payload
cp -a .theos/_/Applications/EscapeOS.app _scratch/Payload/
(cd _scratch && zip -qry ../EscapeOS.ipa Payload)
```

`EscapeOS/Tunnel/libidevice_ffi.a` is not in git (≈93 MB). Download it from the same GitHub Release as the IPA, or rebuild `jkcoxson/idevice` for `aarch64-apple-ios`, and place it at `EscapeOS/Tunnel/libidevice_ffi.a` before building.

After install, place `pairingFile.plist` again from the PC: iPASide Settings → Pairing file → Place (House Arrest), or share the file in Files.

### App icon

Regenerate PNGs from the master artwork:

```bash
python3 tools/generate_icons.py
```

Master icon: `assets/EscapeOS-icon-master.png` (teal escape/sandbox motif, transparent corners).
