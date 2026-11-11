<div align="center">

<img src="docs/brand/icon.png" alt="EscapeOS" width="128" height="128">

# EscapeOS

On-device file browser and backup tool for another app's Data container. No jailbreak. No Keychain.

**Sideload the IPA with [iPASide](https://github.com/pwnapplehat/iPASide)** on Windows. iPASide 1.2.15 or later writes the pairing file and keeps the App Group this IPA needs. A custom certificate that already has App Groups also works: EscapeOS uses a group that is in the installed signature.

</div>

## Sideload

1. Install [iPASide 1.2.15 or later](https://github.com/pwnapplehat/iPASide/releases/latest).
2. Download `EscapeOS-0.3.1.ipa` from [Releases](https://github.com/pwnapplehat/EscapeOS/releases).
3. Sideload that IPA with iPASide. Trust the developer profile on the iPhone when iOS asks.
4. iPASide places `pairingFile.plist` after install. To do it later: Settings → Pairing file → Place.
5. Install [LocalDevVPN](https://apps.apple.com/app/id6755608044), connect it on `10.7.0.1`, leave Wi-Fi on, and open EscapeOS. The PC is not required after the pairing file is in place.

iPASide registers `group.com.ipaside.escapeos` with the Apple ID that signs the app. A custom certificate whose profile already contains App Groups also works.

## What it does

- Lists installed user apps. Search by name or bundle ID. A–Z on the right edge jumps the list. **Search Whole App** finds a name anywhere in that app's data. **Favorites** pins files and folders at the top of the Apps tab.
- Browses that app's Data container: Documents, Library, and tmp. Create, preview, edit, rename, and share. Share keeps the original file name. Import from Files copies the chosen file in, so Open still delivers it after a re-sign, and asks Replace, Keep Both, or Cancel when the name is already there.
- Select for Copy, Cut, Paste, Duplicate, Compress, and Delete. Paste asks Replace, Keep Both, or Cancel when the name exists. Copy Path and Copy Bundle ID go to the clipboard.
- Compresses files and folders to a zip in the current folder. Extracts zip, 7z, tar, gz, bz2, xz, lz4, lzma, and deb. Encrypted zip and 7z ask for a password. RAR is not unpacked.
- Backs up Documents, Library, and tmp to a zip plus `manifest.json` (SHA-256 per file) in Files → On My iPhone → EscapeOS → Backups, and restores that archive into the same app. Backups are not capped at 5,000 files or 512 MB. Share a backup, back up only what you select, and restore only the files you tick.
- Shows progress, speed, and time left on long jobs, with Cancel. Those jobs run one after another.
- Deletes into a Trash (Settings → Trash) that can restore an item without overwriting a name that is already there. Settings can turn Trash off.
- Opens `.db`, `.sqlite`, and `.sqlite3` as tables. Edits happen on a copy. Save refuses if the app changed the database after you opened it, keeps the original in the Trash, and swaps the file in.
- **Reclaim** ranks apps by cache and tmp size and can empty Safe buckets (`tmp`, `Library/Caches`, logs, splash snapshots). Session buckets (cookies, WebKit) are opt-in. Documents, Preferences, and Application Support are never reclaimed.
- **Reset App Data** empties that app's Documents, Library, and tmp. It does not touch Keychain or App Groups.

## What it does not do

- Keychain
- Browsing another app's App Groups, system paths, or the signed `.app` bundle
- iOS 15, 16, or 17. `MinimumOSVersion` is 18.0, so those versions cannot install the IPA

## Compatibility

Opening another app's Data container uses [worse_query](https://github.com/forcequitOS/worse_query). Upstream's range is **iOS 26.0 through 26.7.2**, and **iOS 27.2**. Other builds are unsupported, not assumed. The IPA still installs on iOS 18 or later. Listing apps on iOS 18 is in the code. Container browse is not in worse_query's range there.

| System | Container browse | App list | Hardware |
|---|---|---|---|
| iOS 18 | Not in worse_query's range | Lockdown loopback `10.7.0.1:62078` | Not tested |
| iOS 26.0 – 26.3 | Upstream: yes | Remote Pairing listing is a 26.4+ recipe | Not tested |
| iOS 26.4 – 26.7.2 | Upstream: yes | Remote Pairing / RSD `10.7.0.1:49152` from 26.4 | iPhone 17: container open checked on 2026-11-11 with iPASide and with eSign plus a custom certificate. Earlier 0.1.x screens were checked on iOS 26.5.1 |
| iOS 26.7.3 and later 26.x | Unsupported | — | — |
| iOS 27.2 | Upstream: yes | Not tested | Not tested |
| Other iOS 27 builds, and 27.3 and later | Unsupported | — | — |

## Requirements

- iPhone on a version in the table above, for opening another app's data
- [LocalDevVPN](https://apps.apple.com/app/id6755608044) on `10.7.0.1`, Wi-Fi on, no USB while using EscapeOS
- A pairing file from iPASide (Create keys / Place). An iLoader pairing file can be imported instead

| | iOS 18 | iOS 26.4 and later in the supported range |
|---|---|---|
| App list | Lockdown loopback `10.7.0.1:62078` | Remote Pairing / RSD `10.7.0.1:49152` |
| Pairing file | USB-trust keys are enough. iPASide still writes Remote Pairing keys into the same file | Lockdown-only files fail. The file needs Remote Pairing keys (`identifier`, Ed25519 `public_key` / `private_key`) |

## Why a pairing file

House Arrest is how the PC writes `pairingFile.plist` into EscapeOS. It is not how EscapeOS, running on the phone, sees other apps.

A sideloaded app cannot list other apps or their Data containers by itself. EscapeOS uses the pairing file over LocalDevVPN to talk to `installation_proxy` for the app list and each container path, then opens that container with worse_query so Documents, Library, and tmp are reachable. House Arrest's usual Documents-only sharing is not that.

Without the pairing file there is no app list. After iPASide has placed the file, the PC can stay unplugged.

## Build

Theos, iPhoneOS 16.5 SDK, deployment target iOS 18.0. A Mac with Xcode 26 can relink for Liquid Glass. See [docs/BUILD.md](docs/BUILD.md).

```sh
export THEOS=~/theos
cd ~/apps/EscapeOS
make package FINALPACKAGE=1
```

`EscapeOS/Tunnel/libidevice_ffi.a` is not in git. Take it from the same GitHub release as the IPA.

After a reinstall, place `pairingFile.plist` again from iPASide.

## License

[GNU AGPL-3.0](LICENSE). Third-party origins are in [NOTICE](NOTICE): StikDebug (AGPL-3.0), jkcoxson/idevice (MIT), SWCompression and BitByteData (MIT), and forcequitOS/worse_query (GPL-3.0).
