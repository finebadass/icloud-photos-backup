# iCloud Photos Backup: a Claude Code skill

Back up your **entire iCloud Photos library** to an external drive: every original photo and video,
plus the video half of every Live Photo. Then **prove** nothing is missing. You talk to Claude in
plain words, and Claude does the rest, with guard-rails that make the risky mistakes impossible.

> "Back up my iCloud Photos to my external drive, oldest first, and check nothing is missing."

Built on [icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader).

- **Where it comes from:** a real backup of **81,000 items (1 TB)**. Three downloads ran in parallel
  for about 20 hours, every file was accounted for, and nothing in iCloud was touched.
- **How it's checked:** this packaged version has 100+ automated checks against a simulated
  icloudpd, and its log reading was checked against the logs of that real run.

## Why not just run icloudpd?

icloudpd is an excellent downloader, and this skill uses it. What the skill adds is everything
around it that people get wrong.

| | icloudpd alone | with this skill |
|---|---|---|
| Deletes in iCloud by accident | possible (`--auto-delete`, `--delete-after-download`, ...) | **impossible**: those options are blocked in code |
| Your Apple ID password | you type it, often into scripts | typed only into icloudpd in **your** terminal; never seen by Claude, never saved |
| A 1 TB library | ~40 h with one stream | parallel date ranges that **can't overlap** (about 20 h with 3) |
| Unplugged drive mid-run | can fill your internal disk | refuses to write anywhere but the marked backup folder |
| Hangs, expired links, flaky Wi-Fi | exit code 0 even when files failed | pass after pass until **nothing is missing and no errors** |
| "Is it really all there?" | you guess | **exact check** against icloudpd's own file list, plus duplicates, a spot check and SHA-256 fingerprints |
| Freeing up your iPhone | easy to delete from iCloud by mistake | a step-by-step guide with the checks that prevent it |

## Install

In Claude Code:

```text
/plugin marketplace add finebadass/icloud-photos-backup
/plugin install icloud-photos-backup@icloud-photos-backup
```

Or copy `skills/icloud-photos-backup` into `~/.claude/skills/`.

Then just ask, for example: *"Back up my iCloud Photos to my external drive."*

## What happens

1. **Setup.** Claude installs a pinned, checksum-verified icloudpd into a private folder, then marks
   your backup folder.
2. **You sign in.** You run one command in your own terminal and type your Apple ID password and
   the 6-digit code there. It's the only thing you do by hand.
3. **Backup.** It runs in the background (it survives closing Claude) and keeps the Mac awake.
   - Big libraries are split into date ranges that download in parallel.
   - A final whole-library pass re-checks everything.
4. **Updates** in plain language whenever you ask, or every 15 minutes if you want.
5. **Verification:** the exact check, an inventory by type and year, an exact-duplicate scan, and
   random files opened from every year. Then a short report.
6. **Optional:**
   - SHA-256 fingerprints, so the backup can be checked years later
   - a verified copy on a second drive
   - quick top-ups with new photos
   - a safe guide to emptying your iPhone

## Safety, in code (not just in the instructions)

- **iCloud is only ever read.** Only an allow-list of options reaches icloudpd; the delete and
  rewrite options are refused (exit 64).
- **The password never passes through the scripts.** `signin.sh` refuses to run without a real
  terminal, so an AI can't run it for you.
- **Your files are never deleted, moved or renamed.** The scripts contain no `rm`/`mv` at all, and
  the test-suite checks that.
- **Never two downloaders on the same files.** Locks per date range and per job enforce it.
- **The drive guard:** files are only written into a folder that carries this backup's random ID.

## Requirements

- macOS 12 or later. The core also runs on Linux.
- Python 3.11 to 3.15, for icloudpd (`brew install python@3.13`, or python.org).
- A drive larger than your library. APFS is recommended.
- Optional: `ffmpeg`, so the spot check can open videos.

## Use it without Claude

The scripts work on their own:

```bash
cd skills/icloud-photos-backup/scripts
bash install-icloudpd.sh
bash setup.sh --apple-id you@example.com --dest "/Volumes/MyDrive/iCloud Photos"
bash doctor.sh
bash signin.sh                 # in your own terminal
bash start.sh --parallel 3     # or just start.sh
bash status.sh
bash verify.sh
python3 -I ipb.py manifest create
```

See [`SKILL.md`](skills/icloud-photos-backup/SKILL.md) and the
[reference guides](skills/icloud-photos-backup/references/).

## Tests

```bash
bash tests/run.sh
```

The suite runs 100+ checks against a fake icloudpd. It needs no network and no Apple account, and
it covers:

- refused options
- sign-in states
- retries, crashes and hangs
- a missing drive and a full disk
- locks
- a parallel job with no file downloaded twice
- the exact check, duplicates, the spot check and the manifest
- top-up, and stop/resume

CI runs it on macOS and Linux.

## Limits (v0.1)

- **Not backed up:** albums, favourites, captions and people. Use `--xmp-sidecar` to keep some
  metadata.
- **Shared Library** needs its own settings file (see `references/setup.md`). **Shared Albums**
  aren't backed up.
- **No built-in schedule yet.** Run a top-up yourself, or ask Claude to.
- **Tested with icloudpd 1.33.0.** Other versions may change the log format the checks read.
- Not affiliated with Apple. iCloud and iCloud Photos are trademarks of Apple Inc.

## Credits and licence

- **[icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader)** (MIT) does
  the downloading. This project installs it; it doesn't include it.
- **This project:** MIT licence, see [LICENSE](LICENSE).
