# How it works (for debugging)

## Pieces

| File | Role |
|---|---|
| `scripts/lib.sh` | settings loader (parsed, never executed), defaults, the icloudpd argument list, helpers |
| `scripts/start.sh` | checks the preconditions, then runs `orchestrate.sh` in the background (`screen`, or `nohup`) |
| `scripts/orchestrate.sh` | one job: the to-do list, an optional split into date ranges, the downloaders, the final pass; writes `STATUS.job` |
| `scripts/run-backup.sh` | one downloader: runs icloudpd pass after pass; writes `STATUS.<slice>` |
| `scripts/ipb.py` | read-only tools (status, the exact check, inventory, duplicates, spot check, manifest, planning) |
| `scripts/stop.sh` | TERM to the job, which TERMs its downloaders, which stop icloudpd |

Everything lives in `<state>` (default `~/.local/state/icloud-photos-backup/`):

- `cookies/main/` holds the saved sign-in. `cookies/s1..sN/` hold the per-downloader copies.
- `logs/` holds:
  - `STATUS.job` and `STATUS.<slice>`: one line each, `YYYY-MM-DD HH:MM:SS STATE - text`
  - `job.log` and `wrapper.<slice>.log`: one line per event and per pass
  - `pass-<slice>-<timestamp>-<NN>.log`: icloudpd's own debug output for one pass
  - `listing-*.txt`: the to-do list, from `icloudpd --only-print-filenames`
  - `job-plan.txt`: the date ranges, one `SLICE` line each
  - `job-start`, `job-start-progress` and `job-listing-count`: used for progress and ETA
  - `run.lock.<slice>/` and `../job.lock/`: lock folders that hold the pid

## Passes

icloudpd walks the whole library, newest first.

- For each file it either:
  - logs `DEBUG <path> already exists` (same name and same size on the drive), or
  - downloads it: `DEBUG Downloading <path>...`, then `INFO Downloaded <path>`.
- Downloads go to a `<checksum>.part` file first and are renamed once complete. A stopped pass
  resumes the `.part` next time, using HTTP Range.
- icloudpd's exit code is 0 even when single files failed, so `run-backup.sh` counts the log lines
  itself.
- Passes repeat until one pass downloads nothing and logs no `ERROR`. That status is `COMPLETE`.
- Two passes in a row with nothing new but the same errors give `DONE_WITH_ERRORS`.
- A failing icloudpd (non-zero exit) gets retried with growing waits: 2, 4, 6 ... minutes, up to 30.
  Six failures in a row without progress give `STOPPED_FAILING`.

## Date ranges (`--parallel N`)

icloudpd 1.33 has no working multi-threading (`--threads-num` is deprecated and always 1), so speed
comes from several icloudpd processes, each limited to a date range.

1. `orchestrate.sh` saves the to-do list, and `ipb.py plan` cuts it into N ranges of whole months
   with roughly equal estimated download time. The estimate assumes 0.4 s per file plus its size
   at about 8 MB/s, with averages of 2.5 MB per photo, 8 MB per Live Photo video and 70 MB per
   video.
2. Ranges use `--skip-created-before YYYY-MM-01T00:00:00` and `--skip-created-after <last
   microsecond of the month before>`.
   - icloudpd reads these as local time and compares them strictly.
   - The ranges touch but never overlap, and together they cover all time. So every item belongs
     to exactly one downloader, and no file can be written by two processes.
3. Each downloader gets its own copy of the sign-in (`ipb.py copy-session`), because concurrent
   icloudpd processes must not share session files.
4. When all of them finish, the freshest session is copied back to `cookies/main`. Then one
   whole-library pass runs. It catches anything that slipped between ranges or was added
   meanwhile, and its log is the basis for the exact check.

## Locks

| Lock | Refuses |
|---|---|
| `run.lock.<slice>` holding the pid and mode (`full` or `slice`) | a second copy of the same slice (exit 75) |
| a whole-library run (`full` or `topup`) | anything else running next to it (exit 76) |
| a date slice | a whole-library run running next to it (exit 76) |
| `job.lock` | a second job |

`start.sh` refuses if any of these is held by a live process. A lock with a dead pid is treated as
free, so a crash never blocks the next start.

These locks exist because of a real incident. Two downloaders on the same folder once raced on 73
files and left 12 of them corrupt.

## Safety checks in code

- **Only a short allow-list of options reaches icloudpd.** `run-backup.sh` passes through only
  `--skip-created-before`, `--skip-created-after`, `--until-found` and `--recent`. Everything else
  comes from the settings file through `ipb_icloudpd_args`. Delete options and anything with
  "password" in it are refused (exit 64).
- **The drive guard.** Before every pass, the backup folder must exist and contain
  `.icloud-photos-backup-id` with the ID from the settings. If it doesn't, the status becomes
  `WAITING_FOR_DRIVE`, then `STOPPED_DRIVE_MISSING`.
- **The space guard.** If free space falls below `MIN_FREE_GB` (default 20), the status becomes
  `STOPPED_LOW_DISK`.
- **The watchdog.** If a pass log hasn't changed for `STALL_MIN` (default 60) minutes, that
  icloudpd is stopped. The next pass resumes the `.part` file.
- **No deleting.** The scripts contain no `rm`, `rmdir`, `unlink` or `mv`, and `ipb.py` never
  removes, renames or moves a file. `tests/run.sh` checks both.
