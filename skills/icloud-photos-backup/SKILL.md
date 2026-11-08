---
name: icloud-photos-backup
description: Back up an entire iCloud Photos library - full-quality originals plus the video half of every Live Photo - to an external drive or folder, then prove it is complete with an exact check. Built on icloudpd; never deletes or changes anything in iCloud and never handles the Apple ID password. Use when someone wants to download, back up, export or archive their iCloud Photos or photo library, keep a local copy of it, add new photos to an existing backup, check a photo backup, find duplicate photos, copy a backup to a second drive, or safely free up iPhone storage once everything is saved.
---

# iCloud Photos backup

Saves every photo and video in iCloud Photos (the unmodified originals, plus the video half of each
Live Photo) into year/month folders on a drive. It keeps going until a pass finds nothing missing,
then proves the result with an exact check against icloudpd's own list of files. It grew out of a
real backup of 81,000 items (1 TB) and is covered by an automated test-suite.

Runs on macOS (the core also works on Linux). It uses icloudpd 1.33.0 (MIT licence), installed in a
private folder.

## Ground rules: never break these

1. **Nothing in iCloud is deleted or changed.** Only use these scripts. Never run icloudpd directly
   with `--auto-delete`, `--delete-after-download`, `--keep-icloud-recent-days`, `--prune-orphans`
   or `--set-exif-datetime`. The scripts refuse those options anyway.
2. **Never see the Apple ID password or 2FA codes.** The user signs in themselves, by running
   `signin.sh` in their own terminal window.
   - Never ask them to paste a password or code into the chat.
   - If they do paste one, don't use it. Tell them to change it if they're worried.
3. **Never delete, move or rename the user's files without a clear yes for that exact action.**
   - First show what you want to do, why, and the proof (for example, matching hashes).
   - Prefer moving files into a `_quarantine-YYYYMMDD` folder over deleting them.
4. **Never modify photos or videos.** No EXIF edits, conversions or renames.
5. **One backup per folder at a time.** Start jobs only with `start.sh`, never with icloudpd or
   `run-backup.sh` by hand. Two downloaders writing the same files corrupt them.
6. **Don't call it done before `verify.sh` passes.** Give real numbers and explain every gap.
7. **Talk plainly.** Many users aren't technical: keep updates short, avoid jargon, ask one
   question at a time.

## Where things are

- `$SKILL` means this skill's folder, the base directory shown when the skill loads.
  - Run the scripts with `bash "$SKILL/scripts/<name>.sh"`.
  - Run the Python tools with `python3 -I "$SKILL/scripts/ipb.py" <command>`.
- Settings live in `~/.config/icloud-photos-backup/config`, as plain `KEY="value"` lines.
- The saved sign-in and the logs live in `~/.local/state/icloud-photos-backup/`, which only the
  user can read.
- Background reading, only when you need it:
  - `references/setup.md`: requirements, options, Shared Library, existing backups, sign-in
    details.
  - `references/how-it-works.md`: passes, date ranges, locks, logs. Read it when debugging.
  - `references/verification.md`: reading results, explaining count gaps, handling duplicates.
  - `references/free-up-iphone.md`: freeing iPhone space safely after the backup.
  - `references/extras.md`: second-drive copy, restore, voice memos, WhatsApp, old downloads.
  - `references/troubleshooting.md`: errors and fixes.

## Workflow

### 1. Understand the goal

Common goals are a first full backup, adding new photos to an existing backup, checking a backup,
copying it to a second drive, and freeing up the iPhone. Find out only:

- **The Apple ID email.**
- **Where to save.** Usually a drive plus a folder, such as `/Volumes/MyDrive/iCloud Photos`.
  - The drive needs at least the size of the library plus about 10%.
  - The size is shown on the iPhone under Settings > [name] > iCloud > Photos.
- **Originals only, or edited versions too.** Originals only is the default. For edits too, use
  `--sizes "original adjusted"`.
- **Whether they use an iCloud Shared Library.** It is backed up separately; see `setup.md`.

Use the defaults for everything else. Don't ask about them.

### 2. Install, configure, check

```bash
bash "$SKILL/scripts/install-icloudpd.sh"     # pinned icloudpd 1.33.0, private folder (needs Python 3.11-3.15)
bash "$SKILL/scripts/setup.sh" --apple-id you@example.com --dest "/Volumes/MyDrive/iCloud Photos"
bash "$SKILL/scripts/doctor.sh"
```

- Fix every FAIL before going on.
- Mention a WARN to the user only if it matters to them, such as a folder on the internal disk or
  an exFAT drive.
- If the folder already holds a backup made earlier with icloudpd or another tool, read
  `setup.md` ("Existing backups") before running setup.

### 3. Sign in: the user does this

In one message, tell the user to open their own terminal (the Terminal app, or the terminal panel of
their Claude app) and run this command, with the full path written out:

```bash
bash "/full/path/to/scripts/signin.sh"
```

- They type their Apple ID password (nothing shows while typing), then the 6-digit code.
- Afterwards, run `doctor.sh` and confirm it reports "signed in".
- For Advanced Data Protection, they run `signin.sh --adp` and approve the request on their device.
- For mainland-China Apple IDs, run setup with `--domain cn`.

### 4. Start

```bash
bash "$SKILL/scripts/start.sh"                  # one downloader
bash "$SKILL/scripts/start.sh" --parallel 3     # libraries over ~10,000 items: 3 date ranges at once
```

- **What the job does.**
  - It runs in the background (a `screen` session), so closing Claude or the terminal doesn't
    stop it.
  - First it asks iCloud what is missing, which takes 10+ minutes for big libraries.
  - Then it downloads, pass after pass, until a pass finds nothing new and logs no errors.
  - In parallel mode it finishes with one whole-library pass that re-checks everything.
- **Speed.**
  - One downloader runs at about 8 MB/s.
  - Three in parallel took a 1 TB library to about 20 hours.
  - Don't go above 3-4, because Apple may slow things down.
- **What to tell the user.**
  - Keep the computer on, plugged in and online, and the drive connected.
  - They can open files while it runs, but must not move, rename or delete them.
  - Pausing is fine: `stop.sh` now, then `start.sh` later picks up where it left off.

### 5. Watch

```bash
bash "$SKILL/scripts/status.sh"
```

Summarise the status in 3-5 plain lines: how far along it is, files and GB saved, speed and time
left, errors, and anything the user needs to do. If they want regular updates, offer a recurring
check, for example `/loop 15m` running `status.sh`.

| Status | Meaning | What to do |
|---|---|---|
| LISTING, RUNNING, SLICES RUNNING, FINAL PASS, TOP-UP | working | nothing |
| COMPLETE | everything iCloud listed is on the drive | go to step 6 |
| AUTH_NEEDED | Apple wants a fresh sign-in (typically every couple of months) | the user runs `signin.sh`, then `start.sh` (it resumes) |
| WAITING_FOR_DRIVE | drive unplugged or asleep | plug it back in; resumes by itself (gives up after 6 h) |
| STOPPED_LOW_DISK | drive almost full | bigger drive; never delete backup files to make room without asking |
| DONE_WITH_ERRORS, STOPPED_FAILING | some files keep failing | read the ERROR lines in the newest log, see `troubleshooting.md`, then `start.sh` again |
| EMPTY_LIBRARY | iCloud returned 0 items | wrong `LIBRARY`, or Advanced Data Protection (`signin.sh --adp`) |
| STOPPED_BY_USER | `stop.sh` was used | `start.sh` resumes |
| REFUSED | another copy is already running | check `status.sh`; never start a second copy |

On long runs, errors such as "410 Gone" or "Could not connect" are normal. The next pass retries
them.

### 6. Verify: required before calling it done

```bash
bash "$SKILL/scripts/verify.sh"                        # exact check + inventory + duplicates + spot check
python3 -I "$SKILL/scripts/ipb.py" manifest create     # SHA-256 fingerprints for future checks and copies
```

`verification.md` covers how to read the results, how to explain gaps, and how to handle duplicates.
Gaps usually come from look-alike items, Live Photo counts, the Hidden album, or the phone's count
differing from iCloud's.

### 7. Report

Keep it short and concrete. For example:

> ✅ Backup complete and verified.
> - 24,512 items from iCloud are now 26,083 files: 20,140 photos, 3,872 videos and 2,071 Live
>   Photo videos. 210 GB in total, June 2016 to October 2026.
> - Exact check: 0 missing. 3 look-alike items share a file with an identical twin.
> - No duplicates. Spot check: 40 random files from every year opened fine.
> - Nothing in iCloud was touched: the backup only downloads, and delete options are blocked.

Also say what isn't done yet, and what needs the user's OK.

## After the backup

- **New photos later:** run `start.sh --top-up`, which takes minutes. Run a full `start.sh` now and
  then for the exact check.
- **A second copy on another drive:** see `extras.md` (copy, then check against the manifest).
- **Freeing up the iPhone:** read `free-up-iphone.md` before giving any advice. With iCloud Photos
  on, deleting a photo on the iPhone also deletes it from iCloud and every other device.
- **Voice memos, WhatsApp media, or old downloads already on the drive:** see `extras.md`.
- **Restoring into Photos:** see `extras.md`, section "Restore".
