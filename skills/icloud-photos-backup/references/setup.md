# Setup details

## Requirements

- **Computer.** macOS 12 or later. The core scripts also run on Linux.
  - Keep a laptop open and on power during the backup.
  - Jobs block system sleep with `caffeinate`, but closing the lid still sleeps most Macs.
- **Python 3.11 to 3.15** for icloudpd. On a Mac, use the python.org installer or
  `brew install python@3.13`.
  - `install-icloudpd.sh` finds a suitable Python by itself, or you can pass `--python /path`.
- **Python 3.9 or later** for the check tools. The `python3` that ships with macOS is fine.
- **A drive with more free space than the library uses, plus about 10%.**
  - APFS is the best format on a Mac.
  - exFAT works, but it has no journal, so unplugging mid-write can damage files.
  - NTFS is read-only on macOS, so it can't be used.
- **Optional:** `ffprobe` (`brew install ffmpeg`), so the spot check can open videos and not just
  check their headers.

## Installing icloudpd

`install-icloudpd.sh` installs icloudpd **1.33.0**, the version these scripts were tested with,
into `~/.local/share/icloud-photos-backup/venv`.

- **Why not a plain `pip install icloudpd`?** On macOS that picks icloudpd's ready-made build, which
  in 1.33.0 crashes at start with `No module named 'unicodedata'`. The script installs the
  plain-Python package (`icloudpd-1.33.0-py3-none-any.whl`) instead.
- **The download is checked first.** Its SHA-256 must match the value pinned in `scripts/lib.sh`
  before anything is installed. The dependencies come from PyPI at the exact versions icloudpd
  pins.
- **Uninstalling** means deleting `~/.local/share/icloud-photos-backup`. That is the user's call.
- **Using an icloudpd you already have:** set `ICLOUDPD=` in the settings. `doctor.sh` warns if
  the version differs. The scripts read icloudpd's log text, so other versions may break the
  progress and exact checks.

## setup.sh options

| Option | Default | When to use |
|---|---|---|
| `--apple-id EMAIL` | (required) | the account to back up |
| `--dest PATH` | (required) | full path of the backup folder; it must sit on a plugged-in drive |
| `--sizes "original adjusted"` | `original` | also save edited versions, as separate files |
| `--library NAME` | `PrimarySync` | back up an iCloud Shared Library (see below) |
| `--xmp-sidecar` | off | also save `.xmp` files with titles, keywords and places |
| `--file-match-policy name-id7` | `name-size-dedup-with-suffix` | one file per iCloud item, with a short ID in each name. **Only for a new, empty folder**: on an existing backup it renames everything, so everything downloads again |
| `--folder-structure F` | `{:%Y/%m}` | e.g. `{:%Y/%m/%d}` for day folders, or `none` |
| `--domain cn` | `com` | Apple IDs from mainland China |
| `--keep-unicode` | off | keep non-English letters in file names (icloudpd strips them by default) |
| `--state-dir DIR` | `~/.local/state/icloud-photos-backup` | a separate sign-in and log folder, e.g. for a second library |
| `--force` | | replace existing settings; the old file is kept as `config.bak` |

**The folder's ID.** Setup writes a small hidden file, `.icloud-photos-backup-id`, into the backup
folder, and the backup only ever writes into a folder that has it. If the drive is unplugged, macOS
can leave an empty `/Volumes/<name>` folder behind. Without this check, a backup could quietly fill
the internal disk.

## iCloud Shared Library

A Shared Library is a separate library, and it is not part of `PrimarySync`. To back it up:

1. Run `bash scripts/libraries.sh` (after signing in). It prints names like `SharedSync-…`.
2. Make a second settings file with its own folder and its own state folder:

   ```bash
   IPB_CONFIG=~/.config/icloud-photos-backup/shared.config bash scripts/setup.sh \
     --apple-id you@example.com --dest "/Volumes/MyDrive/iCloud Shared Library" \
     --library SharedSync-XXXX --state-dir ~/.local/state/icloud-photos-backup-shared
   ```

3. Put the same `IPB_CONFIG=...` in front of every command for that library: `signin.sh`,
   `start.sh`, `status.sh` and `verify.sh`.
   - It needs its own sign-in.
   - You can copy the first one instead:
     `python3 -I scripts/ipb.py copy-session ~/.local/state/icloud-photos-backup/cookies/main ~/.local/state/icloud-photos-backup-shared/cookies/main`.
4. Run the two libraries one after the other, not at the same time.

## Existing backups

- **Made by icloudpd with the same naming** (the default file-match policy, the same folder
  structure): point `--dest` at it. icloudpd skips every file that is already there with the same
  name and size, so only what's missing downloads.
- **Made by icloudpd with day folders** (icloudpd's own default, `{:%Y/%m/%d}`): add
  `--folder-structure "{:%Y/%m/%d}"`. Otherwise everything downloads again.
- **Made some other way** (an export from Photos, Google Takeout, a manual download from
  iCloud.com): the file names and folders differ.
  1. Start a new folder.
  2. Afterwards, run `ipb.py find-outside --search <old folder>` to see what the old copy has that
     the new backup doesn't.

## Sign-in details

- **How it works.** The user runs `signin.sh` in their own terminal, and icloudpd asks for the
  password itself (without echo) and then for the 2FA code.
  - What gets saved is a sign-in session (cookies and tokens) in `<state>/cookies/main`, with
    permissions 700. The password itself is never saved.
  - `signin.sh` refuses to run without a real terminal. This is on purpose, so Claude can't run it
    for the user.
- **The sign-in expires.** Apple asks for a fresh sign-in periodically, typically every couple of
  months. When that happens, a running job ends with `AUTH_NEEDED`. The user runs `signin.sh`
  again, then `start.sh`, and nothing is lost.
- **Advanced Data Protection (ADP).** iCloud data is end-to-end encrypted, so icloudpd needs
  permission for web access.
  - Run `signin.sh --adp` (icloudpd's `--adp-web-access`) and approve the request that appears on
    the iPhone, iPad or Mac.
  - "Access iCloud Data on the Web" must be allowed in the iCloud settings.
- **Hardware security keys.** icloudpd 1.33 includes support for them (fido2), but this skill
  hasn't been tested with them. Follow icloudpd's prompts in the terminal.
- **Mainland-China Apple IDs.** Run setup with `--domain cn`.

## macOS permissions

The first time a terminal app writes to an external drive, macOS may ask "Terminal would like to
access files on a removable volume". The user must click **Allow**.

If it was denied, `doctor.sh` reports it. The fix is in **System Settings > Privacy & Security >
Files and Folders > (the terminal app) > Removable Volumes**. Never try to work around macOS
privacy protection. Ask the user instead.
