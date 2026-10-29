# On-device checklist for 0.2.0

The logic behind the 0.2.0 features has automated tests; these screens have not been run on an iPhone.
Work through this with a **throwaway app** (a test app you do not mind losing data in), not one holding
anything you care about. Tick each line, and note anything that behaves differently.

Setup: install the IPA, place the pairing file, connect LocalDevVPN, open a throwaway app's data.

## Queue and progress bar (#11)
- [ ] Copy a folder of a few hundred MB and paste it: a bar appears above the tab bar with a percentage, speed and time left; the rest of the screen stays usable.
- [ ] Start a second heavy task while the first runs (compress something): the bar says "+1 waiting"; the second starts only when the first ends.
- [ ] Tap the X on a running copy: it stops, and the half-written copy is gone.
- [ ] Rename a file during a big copy: it waits, then happens, and no bar flashes for it.
- [ ] Extract a zip: the bar is indeterminate while unpacking, then shows progress while writing.
- [ ] Start a copy that will fail (fill the phone's free space, or paste into a folder that is read-only), leave the folder before it ends: a notice with the reason appears above the tab bar and stays until dismissed.
- [ ] Tap "+N waiting" to open the queue, then Cancel All: the sheet closes, and does not pop up again when the next job starts.

## Trash (#9)
- [ ] Delete a file: the prompt says "Move to Trash". Settings → Trash shows it, with the size.
- [ ] Restore it: it returns to the same folder with the same content.
- [ ] Create a new file with the same name, then restore the trashed one: it returns as "name 2" and the new file is untouched.
- [ ] Delete a folder, restore it: contents intact.
- [ ] Files → On My iPhone → EscapeOS → Trash shows the items.
- [ ] Open the Trash from inside an app's file browser (More menu): items of the app you are in restore; items of other apps say to restore them from Settings, Trash. After restoring, the folder list refreshes.
- [ ] Empty the Trash: confirmation, then it is empty.
- [ ] Turn "Move deleted items to the Trash" off in Settings: Delete says it is permanent, and removes for good.

## Share several (#12)
- [ ] Select three files and a folder → More → Share / Save to Files → Save to Files: all four arrive (the folder as a zip), each under its own name.
- [ ] Select two files whose names differ only by case, if the app has any: both arrive (one numbered).

## Drag and drop (#10)
- [ ] Split View with Files: drag a file onto the list: it lands in the current folder.
- [ ] Drag a **folder** from Files onto the list and onto a folder row: it lands whole. *(What a source app provides for a dragged folder is the part most likely to differ; report what happens.)*
- [ ] Drag a file whose name exists: Replace / Keep Both / Cancel appears and each works.

## Selective backup and restore (#7)
- [ ] Select two items → More → Back Up Selection. Backups tab shows it as Partial with a short list of what it covers.
- [ ] Edit one of those files in the app, then Backups → that backup → Choose What to Restore: tick one item, Continue, Restore. Only that item reverts.
- [ ] Open a full (old) backup → Choose What to Restore: the tree shows folders; ticking a folder ticks everything inside; a half-ticked folder shows a dash.
- [ ] A full backup still restores with "Restore to Device".

## SQLite editor (#8)
- [ ] Open a `.sqlite`/`.db` file (a notes or settings database): tables are listed with row counts.
- [ ] Open a table, change a value, Save. Re-open the app: the change is there. Trash has the original database.
- [ ] Restore that original from the Trash: it comes back beside the edited one as "name 2".
- [ ] While the database is open in EscapeOS, change something in the app, then Save in EscapeOS: it **refuses** and says the database changed. Nothing is overwritten.
- [ ] Edit a value, leave the screen with Close → Keep Editing Later, open the file again: the edit is still there.
- [ ] Open a table with a view or a search index: it is read-only with a reason.
- [ ] Edit a row, make it fail (a NOT NULL column set to empty): the alert with SQLite's message is shown, and the row editor stays open.
- [ ] Close the screen while a save is running: nothing breaks, and after it ends the file's tmp copy is gone (Settings shows no growth).
- [ ] Open a file ending `.db` that is not a database: it says so and offers Open as Hex.

## Regressions to look for
- [ ] Paste across two apps, Cut and paste, Duplicate, Compress, Extract (zip, 7z, tar.gz), Import from Files, full Backup and Restore all still work.
- [ ] Share a single file still opens the share sheet.
