# Changelog

## [0.3.2] - 2026-11-11

### Added

- **An app's App Groups can be browsed** when the install record includes the folder. The app's detail screen lists them. A group whose folder path is missing is shown and cannot be opened. Reset App Data still does not touch groups. Confirmed on device the same day.
- **A backup zip can be imported.** Backups → Import Backup copies an exported EscapeOS backup into Files → On My iPhone → EscapeOS → Backups. A zip that is not one of these backups is refused. A name that is already there is kept, and the import lands beside it. Confirmed on device the same day.

### Changed

- **Search Whole App lands on a file instead of opening it.** A folder still opens. A file opens the folder that contains it and marks that file. Confirmed on device the same day.
- **The IPA no longer installs below iOS 26.0.** `MinimumOSVersion` is 26.0.

## [0.3.1] - 2026-11-11

### Fixed

- **Import from Files and Import Pairing File deliver the file after a re-sign.** Both used SwiftUI's file importer, which returns a security-scoped URL tied to the app's signing identity. When a re-sign gives the app an App ID that is not its bundle id, tapping Open did nothing. The pickers now copy the chosen file into EscapeOS and read that copy. A finished import shows a confirmation. Confirmed on device the same day.

## [0.3.0] - 2026-11-11

### Changed

- **Opening another app's data uses [worse_query](https://github.com/forcequitOS/worse_query) instead of bad_query.** Upstream's range is iOS 26.0 through 26.7.2, and iOS 27.2. The IPA carries an App Group entitlement (`group.com.ipaside.escapeos`). iPASide reads that entitlement and registers the group when it signs. A custom certificate that substitutes its own App Groups still works: EscapeOS uses a group that is actually in the installed signature.
- Checked on an iPhone 17 the same day: another app's data opened after an iPASide sign, and again after eSign with a custom certificate.

## [0.2.1] - 2026-10-29

### Fixed

- **A backup no longer stops at 5,000 files or 512 MB.** Backing up an app with many files, or a lot of data, failed with "Safety limit exceeded (too many files or too much data)", and restoring such a backup was refused too ("Backup exceeds the maximum supported file count" / "size"). Both limits are gone, for backing up and for restoring, whole or chosen files. The only limit left is the free space on the device, which is checked before a backup starts.
  - A backup is written in the ZIP64 form when it needs it (more than 65,535 files, or a file or archive over 4 GB). A small backup is still the same plain zip as before, and backups made by 0.2.0 and earlier restore as before.
  - Files go through in pieces, hashed as they are written, instead of each file being read into memory whole. (0.2.0 said backups already did this. They did not; Compress and Share Zip did. Backups now really do, so a backup holding a very large file no longer risks the app being closed by iOS for memory.) The manifest is written to a scratch file as the backup goes, so it does not pile up in memory either.
  - Restore writes each file to a scratch file beside its destination, checks it against its hash, and only then moves it over the original, so a damaged file never replaces a good one, and the app's data is not left with a half-written file if you cancel. Restore also shows a percentage, speed and time left by size, not only by file count.
  - The Backups list reads only each backup's `backup.json`, and maps the archive instead of loading it into memory, so a list holding a large backup opens quickly.
  - A full disk or other write failure during a backup now says that the write failed, instead of "Container inaccessible".
  - Progress for a backup of many small files is reported a few times a second rather than once per file.

### Not changed

Compress and Share Zip still stop at 20,000 files or 2 GB, and Extract reads each file into memory, so it keeps its limits too. Restoring reads a backup's file list into memory (about half a kilobyte per file), which is fine for hundreds of thousands of files.

**Status.** The new code has automated tests on a computer (1,180 checks, plus a 660 MB backup and restore and a 4.4 GB archive checked with unzip and Python's zipfile), and key lines were broken on purpose to confirm the tests notice. The screens are the ones of 0.2.0 and have not been run on an iPhone; the only change to them is how progress is reported.

## [0.2.0] - 2026-10-29

Builds the six requests left open after 0.1.8 (https://github.com/pwnapplehat/EscapeOS/issues/7, #8, #9, #10, #11 and #12).

**Status.** The logic behind every new feature has automated tests (1,056 checks on a computer), and each was also broken on purpose to confirm the tests notice. The screens that use that logic **have not been run on an iPhone yet**: they build, but nobody has tapped through them. See `docs/device-checklist-0.2.0.md` for what to check on a device. This release is marked a pre-release until that has been done.

### Added

- **Share several items at once** (#12). Select several files and folders, then More, Share / Save to Files. They go to one share sheet, each under its own name; a folder is zipped. Names that would clash (including `Report.pdf` and `report.pdf`, which the iPhone treats as the same name) are numbered, and the staged copies are removed if anything fails.
- **Drag and drop from the Files app** (#10). Drop files or folders onto the folder you are in, or onto a folder in the list. Folders come across whole. A name that already exists asks Replace / Keep Both / Cancel exactly as Paste does, and there is the usual free-space check. Dropped items are copied into a private staging folder the moment they arrive and moved into place afterwards.
- **Progress, speed and time left, and a queue** (#11). Copy, move, compress, extract, share, delete, import, backup and restore no longer put up a spinner that blocks the screen. A bar above the tab bar shows the running job with a percentage, speed and time left wherever those can be known (a total that is only discovered along the way shows what it can), a Cancel button, and how many are waiting. Several heavy tasks started together run one after another instead of at the same time. Quick tasks (rename, new folder) are queued behind them so they cannot run in the middle of a heavy one, but only appear on screen if they turn out slow.
- **Trash with restore** (#9). Deleting moves items to a Trash inside EscapeOS (Settings, Trash; also Files, On My iPhone, EscapeOS, Trash) instead of removing them. It shows what is in it and how big it is, restores an item to where it was (in the app's current data, even after a reinstall) without ever replacing anything (a taken name comes back as `name 2`), saves a copy through the share sheet, and empties with one tap. **Settings, Move deleted items to the Trash** turns it off, which restores the old permanent delete. If EscapeOS is closed while an item is being moved in, the next launch settles it without deleting anything that might be the only copy.
- **Back up and restore selected files** (#7). Back Up Selection (selection bar, More) and Back Up (long-press) save only what you choose, as a backup marked Partial in the Backups list. **Choose What to Restore** opens any backup as a tree of folders with checkboxes (a folder is ticked when everything in it is), and restores only the ticked files. A folder that no longer exists in the app is recreated. The whole backup is still verified against its checksums; only the chosen files are written, and each is checked against its own hash. Older backups open and restore as before.
- **SQLite viewer and editor** (#8). Files ending `.db`, `.sqlite`, `.sqlite3`, `.db3` or `.sqlitedb` open as a database: tables and views with row counts, rows a page at a time, edit a value, add or delete a row. It always works on a private copy, including the write-ahead log, so rows an app has written but not yet merged are there. **Saving** first refuses if the app changed the database after you opened it (saving would overwrite its changes), keeps the original in the Trash, writes the edited database next to the original and swaps it in with one atomic rename, and removes the old log files (replaying them into the new database would corrupt it). Views, virtual tables and search-index tables are read-only, and so is a table with no way to name a row. Unsaved edits are kept if you leave the screen. Share a Copy saves the edited database as one file without touching the app.

### Changed

- **Compress and Share Zip no longer read each file into memory whole.** Zip files are written by streaming, so a large file no longer risks the app being closed by iOS for using too much memory. (This entry first said backups too; backups did not stream until 0.2.1.) Zip entries now store their names as UTF-8, so accented names are not garbled by other tools. Links inside a folder are skipped by Compress and Share Zip: following one could loop back up the tree.
- **Copying and moving between folders and apps keeps the "do not back up" mark** that iOS puts on cache files (it is an extended attribute), as the previous method did, and reports progress and can be cancelled. A cancelled or failed copy removes what it had written.
- **The delete confirmation says what will happen.** With the Trash on it says the items move to the Trash and can be restored; with it off it still says they are deleted permanently.
- **A job that fails after you have left the screen it started from** now leaves a notice above the tab bar (with the reason, until dismissed) instead of failing silently.
- **Import from Files** still cannot take a folder, and now says to drag the folder onto a folder in EscapeOS instead.

### Fixed

- Writing a zip to a full disk could crash the app (the older file API raises an exception Swift cannot catch). It now fails with an error.

### Not in this release

Opening a database over 4 GB, editing the schema (creating or dropping tables), and editing BLOB values in the SQLite editor.

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

- App list via LocalDevVPN. iOS 26.4+ uses Remote Pairing/RSD (`10.7.0.1:49152`). No USB while using the app.
- Path-scoped Data-container browse, edit, share, backup zip + restore. Select for multi-select Copy/Cut/Paste/Duplicate/Delete; Copy Path, Copy Bundle ID, and Copy SHA-256.
- Pairing setup names EscapeOS and iPASide. iLoader is not required; iPASide writes the same merged pairing file as iLoader and places `pairingFile.plist`.
- README shows the app icon with transparent corners (no black frame).
- Supported container access follows [bad_query](https://github.com/forcequitOS/bad_query): **iOS 26.0–26.6.1** and **iOS 27.0 beta 4**. Later 26.x / 27.x builds are unsupported. Hardware-verified: iPhone 17, **iOS 26.5.1**.
- Verified on iPhone 17, iOS 26.5.1, with iPASide placing the pairing file after install (list, browse, Select/copy-paste, backup).
