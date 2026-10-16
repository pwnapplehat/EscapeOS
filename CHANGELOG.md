# Changelog

## [0.1.8] - 2026-10-15

Release after 0.1.6. 0.1.7 was never published; its two fixes are included here, together with features built from the requests in https://github.com/pwnapplehat/EscapeOS/issues/3 and https://github.com/pwnapplehat/EscapeOS/issues/4.

### Fixed

- **Import from Files no longer fails with "That folder is outside this app's data."** Since 0.1.6, adding a file whose name was not already in the folder, and the **Keep Both** choice, both failed with that message; only **Replace** worked. The folder check compared paths with `standardizingPath`, which drops a leading `/private` only when the path exists on disk. An app's container is reported under `/private/var/...`, so the existing folder and the not-yet-created file were normalized differently and the file looked outside its own folder. The check now compares path components without touching the file system, and still rejects `..` escapes, sibling folders and other apps. https://github.com/pwnapplehat/EscapeOS/issues/4
- **"Could not connect to the local tunnel ... InvalidHostID" now says what is wrong.** `InvalidHostID` means the device does not recognise EscapeOS's pairing file (out of date, made for another device, or trust was reset). The message used to tell people to check LocalDevVPN and Wi-Fi, which was not the problem. It now says to place a fresh pairing file with iPASide or import the one the other sideloading app uses. https://github.com/pwnapplehat/EscapeOS/issues/5

- **Sharing a file can no longer delete EscapeOS's own data.** Share used to write the file into EscapeOS's own Documents folder under its original name, replacing whatever had that name. Sharing a file called `Backups` removed every backup archive, and one called `pairingFile.plist` removed the pairing file. Shares are now staged in a folder of their own in the temporary directory, which is swept before the next share.

### Added

- **Search Whole App.** The **+** menu in any folder now has **Search Whole App**, which looks for a file or folder name anywhere in that app's data, not just the folder on screen. Every word you type must appear in the name; case and accents are ignored. Results are shown shallowest first, tap one to open the file or jump to the folder. It follows no symlinks, stops at 500 matches or 150,000 items, and can be cancelled.
- **Favorites.** Long-press a file or folder and choose **Add to Favorites**, or use **Add Folder to Favorites** in the **+** menu. Favorites are listed at the top of the Apps tab and open in one tap. If an app is reinstalled (its data folder changes), favorites still open at the same place inside it. Swipe a favorite to remove it.
- **Share / Save to Files** on every backup in the Backups tab, so an archive can be sent or saved outside the app.
- **Replace / Keep Both / Cancel when pasting.** Pasting a file whose name already exists in the folder, in the same app or across apps, now asks instead of silently saving `name 2`. Replace is only offered for a file over a file: a folder is never replaced, a folder never replaces a file, and an item is never replaced by itself. Replacing copies to a hidden temporary name first and swaps it in with one atomic rename, so a failure leaves the existing file as it was.
- **Free-space check before large work.** Compress, Share Zip, Duplicate, Paste, Import from Files and Backup now check how much room they need before they start and stop with a clear "Not enough free space" message that says how much is needed and how much is free, instead of failing after a long wait.

### Changed

- **Deleting a file now asks first.** Until now only folders asked; a file was deleted the instant Delete was tapped or swiped. The confirmation names exactly what will be deleted. **Delete, Don’t Ask Again** is offered for files for people who find the prompt slow, and **Settings → Confirm before deleting files** turns it back on. Folders always ask.
- **Deleting a backup archive asks first** and says it cannot be undone.

### Not in this release

SQLite editor, selective backup and restore of single files, drag and drop from Files, a trash with restore, an operation queue and progress for every operation are tracked as separate issues.

## [0.1.6] - 2026-09-18

Production IPA after 0.1.5.

### Changed

- **Import from Files** asks **Replace**, **Keep Both**, or **Cancel** when that name is already in the folder, instead of silently writing `foo 2.txt`. Replace overwrites the existing file at the same path. A same-named **folder** is never replaced with a file (Keep Both lands beside it). https://github.com/pwnapplehat/EscapeOS/issues/2

## [0.1.5] - 2026-08-17

Production IPA after 0.1.4. Hardware-checked on iPhone 17, iOS 26.5.1 (list, browse, Reclaim skip-on-denied, Reset App Data).

### Added

- **Reclaim** tab ranks apps by Safe cache/tmp bytes. Per-app Reclaim Space from App Detail. Batch reclaims Safe buckets only. Session buckets (cookies, WebKit, HTTP storage) are opt-in with a second confirm. Reclaim never deletes Documents, Preferences, or Application Support. Opening an app after a tab scan reuses those Safe sizes instead of measuring again. Locked cache files (permission denied) are skipped instead of failing the whole reclaim.
- **Reset App Data** on App Detail empties Documents, Library, and tmp for that app (not Keychain). Resetting EscapeOS itself also warns that the pairing file will be deleted.

## [0.1.4] - 2026-08-17

Production IPA after 0.1.3. Hardware-checked on iPhone 17, iOS 26.5.1 (list, browse, pairing place, extract, A–Z).

### Added

- Password prompt when extracting an encrypted zip (ZipCrypto and WinZip AES-128/192/256) or encrypted 7z (AES-256, including encrypted names).
- Extract via vendored [SWCompression](https://github.com/tsolomko/SWCompression) 4.8.6: 7z, tar, gzip, bzip2, xz, lz4, lzma, tgz/tbz/txz, and deb. Password zip uses EscapeOS’s own reader. Password 7z uses AES-256 + SHA-256 (same as 7-Zip). RAR is not included (RARLab unrar license).

### Changed

- A–Z letters stay on the right edge; the Apps list scrollbar is hidden so the index receives taps.
- File rows are tappable across the whole cell. Deleting a **file** does not confirm; **folders** still confirm. File viewer Save no longer shows a success alert.
- Removed unused UIKit tab-bar shell (Theos ships SwiftUI `TabView`). `.tar.lz4` / `.tar.lzma` unwrap like the other tarballs.

### Fixed

- Archive member paths cannot leave the extract folder (`..`, `\`, absolute names in gzip headers).
- Password prompt always shows **Extract** (iOS 26 hides disabled alert actions, so an empty-field disable left only Cancel).
- Import Pairing File uses the same Files picker types as Import from Files, so `pairingFile.plist` and iLoader `.mobiledevicepairing` can be selected.

## [0.1.3] - 2026-08-16

Production IPA after 0.1.1. Hardware-checked on iPhone 17, iOS 26.5.1 (list, browse, pairing place).

### Added

- **Compress** in the file browser (long-press or Select → More) zips files and folders into the current folder.
- **Extract** for zip / IPA: tap the archive (or Extract in the menu) to unpack a folder next to it. Open as Hex stays on the menu.

### Fixed

- Share / Save to Files keeps the original filename (no `shared_` prefix). Folders share as `FolderName.zip`.
- Empty Apps list says “No apps found.” instead of a blank search miss.

A–Z jump is the same small index as 0.1.1 (no extra inset beside search).

v0.1.0 and v0.1.1 are unchanged on GitHub.

## [0.1.1] - 2026-08-16

### Added

- **Apps search** and an **A–Z jump index** on the right edge of the app list.
- **Copy confirmation** (banner + haptic) for Bundle ID, name, path, SHA-256, and file Copy/Cut.

v0.1.0 is unchanged on GitHub. This is a new tag and IPA.

## [0.1.0] - 2026-08-14

First public sideload IPA.

- App list via LocalDevVPN. iOS 26.4+ uses Remote Pairing/RSD (`10.7.0.1:49152`); iOS 18 falls back to lockdown loopback (`10.7.0.1:62078`). No USB while using the app.
- Path-scoped Data-container browse, edit, share, backup zip + restore. Select for multi-select Copy/Cut/Paste/Duplicate/Delete; Copy Path, Copy Bundle ID, and Copy SHA-256.
- Pairing setup names EscapeOS and iPASide. iLoader is not required; iPASide writes the same merged pairing file as iLoader and places `pairingFile.plist`.
- README shows the app icon with transparent corners (no black frame).
- Supported container access follows [bad_query](https://github.com/forcequitOS/bad_query): **iOS 26.0–26.6.1** and **iOS 27.0 beta 4**. Later 26.x / 27.x builds are unsupported. IPA `MinimumOSVersion` is 18.0; iOS 18 listing is in code, untested. Hardware-verified: iPhone 17, **iOS 26.5.1**.
- Verified on iPhone 17, iOS 26.5.1, with iPASide placing the pairing file after install (list, browse, Select/copy-paste, backup).
