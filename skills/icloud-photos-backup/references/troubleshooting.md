# Troubleshooting

Start with `bash scripts/status.sh` and `bash scripts/doctor.sh`. The logs are in
`~/.local/state/icloud-photos-backup/logs/`:

- `job.log`: the job's steps
- `wrapper.<slice>.log`: one line per pass
- `pass-*.log`: icloudpd's own output

| What you see | Cause | Fix |
|---|---|---|
| `icloudpd --version` crashes with `No module named 'unicodedata'` | icloudpd's ready-made macOS build (1.33.0) | `install-icloudpd.sh --force` (it installs the plain-Python package) |
| `install-icloudpd.sh`: "needs Python 3.11 to 3.15" | the system Python is older | install Python from python.org or with `brew install python@3.13` |
| `AUTH_NEEDED` | not signed in yet, or Apple wants a fresh sign-in | the user runs `signin.sh` in their own terminal, then `start.sh` |
| `signin.sh` fails with `-20101` / "Invalid email/password" | wrong password, wrong Apple ID, or a keyboard-layout surprise | check the Apple ID in the settings; type it again slowly |
| The 2FA code never arrives | it went to another trusted device | use any trusted device, or "Didn't get a code?" on the phone |
| `EMPTY_LIBRARY` | wrong `LIBRARY`, or Advanced Data Protection blocks web access | `libraries.sh`; or `signin.sh --adp` and approve the request on the device |
| `ERROR ... 410 Client Error: Gone` | a download link expired during a long video download | normal; the next pass retries it |
| `ERROR ... Could not connect` / `Connection lost` | network trouble | normal; retried. If it never stops, check the internet connection |
| "no output for ...s - stopping icloudpd" in `wrapper.*.log` | a pass hung, so the watchdog restarted it | nothing to do; the `.part` resumes |
| `DONE_WITH_ERRORS` | the same files keep failing | `grep ' ERROR ' <newest pass log>`. Often a file iCloud can't serve right now (still processing, or damaged upstream); try again later. Report the file names to the user |
| `WAITING_FOR_DRIVE` / `STOPPED_DRIVE_MISSING` | the drive is unplugged, renamed, or the ID file is missing | plug it in. If it was renamed, `setup.sh --dest "<new path>" --force` (the ID is kept) |
| `STOPPED_LOW_DISK` | less than `MIN_FREE_GB` free | use a bigger drive. Don't delete backup files to make room |
| `ALREADY RUNNING` (75) / `REFUSED` (76) | another copy is running | `status.sh`. To stop it, `stop.sh`. Never force a second copy |
| `Operation not permitted` on `/Volumes/...` | macOS privacy settings | allow the terminal app under Privacy & Security > Files and Folders > Removable Volumes |
| `Operation not permitted` on the Photos library or Voice Memos | macOS privacy, on purpose | don't work around it; use the app's own export (see `extras.md`) |
| The job dies when the Mac sleeps | the lid was closed, or it was on battery | keep it open and on power; jobs block idle sleep with `caffeinate` |
| `status.sh` says the process is NOT running but the status says RUNNING | the computer restarted or the job was killed | `start.sh`: it resumes, nothing is lost |
| Counts differ from the iPhone | Hidden album, items still uploading, a Shared Library, Recently Deleted | see `verification.md`, "Explaining count differences" |
| `reconcile` reports MISSING files | the last pass didn't finish, or files were moved | `start.sh` (it fetches only what's missing); then `verify.sh` again |
| Files got corrupted after two downloaders ran on the same folder (e.g. started by hand) | they raced on the same files | 1. compare sizes with what icloudpd expects<br>2. with the user's OK, move suspect files into `_quarantine-YYYYMMDD/`<br>3. run `start.sh` to download clean copies<br>4. then `dupes` and `spotcheck` |
| `screen` isn't installed | some Linux systems | jobs fall back to `nohup` by themselves; `start.sh --foreground` shows errors directly |

## Reading a pass log quickly

```bash
L=~/.local/state/icloud-photos-backup/logs
tail -3 "$L"/wrapper.*.log                      # how each pass ended
grep -h ' ERROR ' "$(ls -t "$L"/pass-*.log | head -1)" | tail -20
grep -c ' INFO     Downloaded ' "$(ls -t "$L"/pass-*.log | head -1)"   # files saved by the newest pass
```
