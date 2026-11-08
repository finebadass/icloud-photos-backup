# Extras

## A second copy on another drive

A backup that sits on one drive is one accident away from gone. Make a second copy:

1. **Create the manifest on the original**, if you haven't yet:
   `python3 -I scripts/ipb.py manifest create`.
2. **Copy.** This keeps dates, resumes if it's interrupted, and never deletes anything on the
   destination:

   ```bash
   rsync -aHE --progress --exclude '.DS_Store' "/Volumes/Original/iCloud Photos/" "/Volumes/Copy/iCloud Photos/"
   ```

   Run it in the background with `caffeinate`, and log its output. 1 TB takes a few hours.
3. **Check the copy against the fingerprints.** The manifest travels inside `_manifest/`:
   `python3 -I scripts/ipb.py manifest check "/Volumes/Copy/iCloud Photos"`.
   - It must say every file matches.
   - Re-copy only the files it names.
4. **Never write into a Time Machine backup volume.**
   - If the second drive holds Time Machine backups, propose a separate APFS volume in the same
     container: `diskutil apfs addVolume <container> APFS "Photos Copy"`.
   - That needs the user's OK first.
5. **Keep the original untouched** until the copy is verified.

The copy carries the hidden ID file too. Later, `setup.sh --dest <copy> --force` can turn the copy
into the active backup without downloading anything again.

## Restore

The backup holds plain files, so any app can read them.

- **Into Photos on a Mac:** File > Import, and select year folders.
  - Photos usually pairs a Live Photo's photo and video again when both are imported together,
    because they carry the same hidden identifier.
  - Test with one month first, into a separate library: hold Option while opening Photos >
    Create New.
- **Back into iCloud:** drag files into icloud.com/photos (fine for smaller batches), or import into
  Photos on a Mac that has iCloud Photos on.
- **What isn't in the backup:** albums, favourites, captions, people and edits. Edits are the
  exception if `SIZES` included `adjusted`. `--xmp-sidecar` keeps some of the rest in `.xmp`
  files.

## Voice memos (macOS)

- **macOS blocks terminal access to the Voice Memos library.** Don't try to get around that.
- **Ask the user to export them:**
  1. Open the Voice Memos app on the Mac. With iCloud sync on, the recordings appear there.
  2. Click one recording, press Cmd+A, and drag them all into a folder, e.g.
     `<backup>/Voice Memos/`.
- **Then check them.** Count the files and compare with the app. Open each one with
  `ffprobe -v error -show_entries format=duration -of csv=p=0 FILE`.
  - Report any that won't open.
  - These are often recordings that were cut off when they were made. They may be broken on the
    phone too, so ask the user to check before deleting anything.
- **Deleting a recording on the iPhone deletes it everywhere when sync is on.** Only after the
  check.

## WhatsApp media

WhatsApp's own iCloud backup can't be opened as files. Export the big chats from the phone:

1. In WhatsApp, go to Settings > Storage and Data > Manage Storage to see the biggest chats.
2. For each one: open the chat, tap its name > **Export Chat** > **Attach Media**, then send it
   with AirDrop to the Mac (or save it to Files, then iCloud Drive).
   - Exports include roughly the latest 10,000 messages with media. Check older media before
     deleting it.
3. Put the zips in a folder on the drive. Unzip them, and check that the media opens.
4. Then free space in Manage Storage: open a chat > Select > delete the big files.
   - Media deleted on the phone also disappears from WhatsApp's backup at its next run.

## Old downloads already on the drive

People often have earlier manual downloads from iCloud.com scattered around their drives. To find
them:

```bash
python3 -I scripts/ipb.py find-outside --search /Volumes/MyDrive --report /tmp/outside.tsv
```

Each photo or video found outside the backup is compared byte for byte with the backup. It gets
listed either as **already in the backup**, or as **NOT in the backup**. Add `--audio` to include
voice recordings.

- **Files NOT in the backup** are often items that were later deleted from iCloud, so they may be
  the only copy left. Ask the user before doing anything with them.
- **To bring them in:**
  1. **Copy** them into the backup. Don't move them, and leave the originals alone unless the user
     asks.
  2. Use the year/month folder of their capture date. That date comes from
     `ffprobe ... format_tags=creation_time` for videos, and the EXIF date for photos. Check that
     the name isn't already taken in that folder.
  3. Verify every copy with `cmp`.
  4. They then show up as EXTRA in the exact check. That's expected.
- **An interrupted copy leaves a partial file.** Check sizes with `cmp`, and delete a partial copy
  only with the user's OK.
