#!/bin/bash
# tests/run.sh - runs every script against a fake icloudpd (tests/fake_icloudpd.py) in a throw-away
# folder. No network, no Apple account, nothing outside the temporary folder is touched.
#   bash tests/run.sh          (the temp folder is kept only when something fails)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
S="$REPO/skills/icloud-photos-backup/scripts"
FAKE="$HERE/fake_icloudpd.py"
PY="$(command -v "${PYTHON:-python3}")"
T="$(mktemp -d "${TMPDIR:-/tmp}/ipb-tests.XXXXXX")"
PASS=0; FAIL=0; W=""; D=""; L=""
ok()     { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
nok()    { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
expect() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else nok "$what"; fi; }
has()    { grep -q -- "$2" "$1" 2>/dev/null; }
ipb()    { "$PY" -I "$S/ipb.py" "$@"; }
nfiles() { find "$D" -type f ! -name '.*' ! -name '*.part' ! -path '*/_*' | wc -l | tr -d ' '; }
backup() { bash "$S/run-backup.sh" "$@" >>"$W/run.out" 2>&1; }
setcfg() { printf '%s="%s"\n' "$1" "$2" >> "$W/config"; }
session(){ mkdir -p "$1"; printf '{"session_token": "fake"}' > "$1/testuserexamplecom.session"; printf '#LWP-Cookies-2.0\n' > "$1/testuserexamplecom"; }
alive()  { local f p; for f in "$W/state/job.lock/pid" "$W"/state/logs/run.lock.*/pid; do
             [ -f "$f" ] || continue; p=$(cat "$f"); ps -p "$p" -o command= 2>/dev/null | grep -qE 'orchestrate|run-backup' && return 0
           done; return 1; }
fresh() {   # a new, isolated install: settings file, marked drive folder, fake sign-in
  W="$T/$1"; D="$W/drive/Photos"; L="$W/state/logs"; echo "== $1"
  mkdir -p "$W/drive" "$W/fake"
  export IPB_CONFIG="$W/config" IPB_DATA="$W/data" IPB_NO_NOTIFY=1 IPB_AWAKE=1 FAKE_STATE="$W/fake" SLICE=full
  export IPB_POLL_S=0.1 IPB_GAP_S=0 IPB_RETRY_BASE_S=0 IPB_WAIT_S=0.1 IPB_STAGGER_S=0 IPB_STALL_S=3 IPB_KILL_GRACE_S=1
  unset FAKE_FAIL_ONCE FAKE_FAIL_ALWAYS FAKE_HANG_ONCE FAKE_DELAY FAKE_AUTH_FAIL FAKE_CRASH_ONCE FAKE_EMPTY FAKE_ITEMS FAKE_EXTRA
  bash "$S/setup.sh" --apple-id test.user@example.com --dest "$D" >"$W/setup.out" 2>&1 || nok "setup.sh failed: $(cat "$W/setup.out")"
  setcfg ICLOUDPD "$FAKE"; setcfg STATE_DIR "$W/state"; setcfg PYTHON "$PY"; setcfg MIN_FREE_GB 0
  session "$W/state/cookies/main"
}
cleanup() {   # stop anything a failed test may have left running (only processes of this test run)
  local f p
  for f in "$T"/*/state/job.lock/pid "$T"/*/state/logs/run.lock.*/pid "$T"/*/state/logs/icloudpd.*.pid; do
    [ -f "$f" ] || continue; p=$(cat "$f" 2>/dev/null)
    ps -p "$p" -o command= 2>/dev/null | grep -qE 'orchestrate|run-backup|fake_icloudpd' && kill "$p" 2>/dev/null
  done
}
trap cleanup EXIT

# ------------------------------------------------------------------------------------ setup
fresh setup
expect "settings file written" test -f "$W/config"
expect "backup folder marked with a random ID" test -s "$D/.icloud-photos-backup-id"
id=$(tr -d '[:space:]' < "$D/.icloud-photos-backup-id")
expect "the ID is stored in the settings" grep -q "DRIVE_ID=\"$id\"" "$W/config"
bash "$S/setup.sh" --apple-id test.user@example.com --dest "$D" >/dev/null 2>&1
expect "setup refuses to overwrite settings without --force" test $? = 1
bash "$S/setup.sh" --apple-id test.user@example.com --dest "$D" --force >/dev/null 2>&1
expect "--force keeps the old settings as config.bak" test -f "$W/config.bak"
expect "--force keeps the folder's existing ID" grep -q "DRIVE_ID=\"$id\"" "$W/config"
IPB_CONFIG="$W/c2" bash "$S/setup.sh" --apple-id a@b.com --dest relative/path >/dev/null 2>&1
expect "setup rejects a relative path" test $? = 64
IPB_CONFIG="$W/c3" bash "$S/setup.sh" --apple-id a@b.com --dest "$W/no-such-drive/Photos" >/dev/null 2>&1
expect "setup refuses when the drive isn't plugged in" test $? = 5
expect "...and creates nothing there" test ! -e "$W/no-such-drive"
IPB_CONFIG="$W/c4" bash "$S/setup.sh" --apple-id a@b.com --dest "$D" --state-dir "$W/state-two" >/dev/null 2>&1
expect "setup --state-dir gives a second library its own state folder" grep -qx "STATE_DIR=\"$W/state-two\"" "$W/c4"

# ------------------------------------------------------------------------------------ safety
fresh safety
for opt in --auto-delete --delete-after-download "--keep-icloud-recent-days 0" --set-exif-datetime \
           --prune-orphans "--password secret" "--album Favorites" --skip-created-before; do
  # shellcheck disable=SC2086
  backup $opt
  expect "refuses '$opt' (exit 64)" test $? = 64
done
expect "no dangerous option ever reached icloudpd" test ! -e "$W/fake/DANGEROUS_OPTION_RECEIVED"
expect "nothing was downloaded by refused runs" test "$(nfiles)" = 0
code=$(grep -hvE '^[[:space:]]*#' "$S"/*.sh | grep -E '(^|[^[:alnum:]_.-])(rm|rmdir|unlink|mv)([[:space:]]|$)')
expect "no shell script contains rm / rmdir / unlink / mv" test -z "$code"
code=$(grep -nE 'os\.(remove|unlink|rmdir|rename)\(|shutil\.(rmtree|move)\(|\.unlink\(' "$S/ipb.py")
expect "ipb.py never removes, renames or moves files" test -z "$code"
bash "$S/signin.sh" </dev/null >"$W/signin.out" 2>&1
expect "signin.sh refuses to run without a real terminal (exit 64)" test $? = 64
expect "...and says where to run it" has "$W/signin.out" "own terminal"

# ------------------------------------------------------------------------------------ outcomes
fresh full
backup; expect "whole-library run completes (exit 0)" test $? = 0
expect "status COMPLETE" has "$L/STATUS.full" " COMPLETE "
expect "132 files saved (the look-alike pair shares one file)" test "$(nfiles)" = 132
expect "files are in year/month folders" test -n "$(ls "$D"/2019/01/IMG_0001.* 2>/dev/null)"
expect "Live Photo video saved next to its photo" test -f "$D/2019/04/IMG_0005_HEVC.MOV" -o -n "$(find "$D" -name 'IMG_0005_HEVC.MOV')"
backup; expect "a second run completes" test $? = 0
expect "...and downloads nothing" test "$(grep 'pass 1 done' "$L/wrapper.full.log" | tail -1 | grep -c 'downloaded=0 ')" = 1
expect "no unfinished .part files" test -z "$(find "$D" -name '*.part')"

fresh retry
FAKE_FAIL_ONCE="IMG_0003.JPG,IMG_0020.MOV" backup
expect "temporary errors are retried and the run completes" test $? = 0
expect "the failed files arrived on a later pass" test -n "$(find "$D" -name IMG_0003.JPG)" -a -n "$(find "$D" -name IMG_0020.MOV)"
expect "the first pass logged 2 errors" grep -q "errors=2" "$L/wrapper.full.log"

fresh persistent
FAKE_FAIL_ALWAYS="IMG_0003.JPG" backup
expect "a file that always fails ends as DONE_WITH_ERRORS (exit 3)" test $? = 3
expect "...after saving everything else" test "$(nfiles)" = 131

fresh crash
FAKE_CRASH_ONCE=1 backup
expect "a crashed pass is retried and the run completes" test $? = 0
expect "all files present after the crash" test "$(nfiles)" = 132

fresh stall
FAKE_HANG_ONCE=30 IPB_STALL_S=1 backup
expect "a hung pass is stopped by the watchdog and the run completes" test $? = 0
expect "the watchdog left a note in the log" grep -q "no output for" "$L/wrapper.full.log"

fresh outcomes
FAKE_AUTH_FAIL=1 backup; expect "rejected sign-in -> AUTH_NEEDED (exit 2)" test $? = 2
mv "$W/state/cookies/main" "$W/state/cookies/away"
backup; expect "no saved sign-in -> AUTH_NEEDED (exit 2)" test $? = 2
expect "...and the status says so" has "$L/STATUS.full" AUTH_NEEDED
mv "$W/state/cookies/away" "$W/state/cookies/main"
FAKE_EMPTY=1 backup; expect "empty library -> EMPTY_LIBRARY (exit 8)" test $? = 8
setcfg MIN_FREE_GB 999999999; backup; expect "not enough space -> STOPPED_LOW_DISK (exit 4)" test $? = 4
setcfg MIN_FREE_GB 0; setcfg DRIVE_WAIT_MAX_MIN 0
mv "$D/.icloud-photos-backup-id" "$W/id-away"
backup; expect "folder without its ID file -> STOPPED_DRIVE_MISSING (exit 5)" test $? = 5
expect "nothing was written into the unmarked folder" test "$(nfiles)" = 0
mv "$W/id-away" "$D/.icloud-photos-backup-id"

# ------------------------------------------------------------------------------------ locks
fresh locks
FAKE_DELAY=0.03 bash "$S/run-backup.sh" >/dev/null 2>&1 & bg=$!
sleep 1.5
SLICE=full bash "$S/run-backup.sh" >/dev/null 2>&1
expect "a second copy of the same run is refused (75)" test $? = 75
SLICE=s1 bash "$S/run-backup.sh" --skip-created-after 2020-01-01T00:00:00 >/dev/null 2>&1
expect "a date slice can't start next to a whole-library run (76)" test $? = 76
wait "$bg"; expect "the first run still completes" test $? = 0
fresh locks2
FAKE_DELAY=0.03 SLICE=s1 bash "$S/run-backup.sh" --skip-created-after 2030-01-01T00:00:00 >/dev/null 2>&1 & bg=$!
sleep 1.5
SLICE=full bash "$S/run-backup.sh" >/dev/null 2>&1
expect "a whole-library run can't start next to a slice (76)" test $? = 76
bash "$S/start.sh" --foreground >/dev/null 2>&1
expect "start.sh refuses while a downloader is running (75)" test $? = 75
wait "$bg"

# ------------------------------------------------------------------------------------ parallel job
fresh parallel
bash "$S/start.sh" --parallel 3 --foreground >"$W/job.out" 2>&1
expect "parallel job completes (exit 0)" test $? = 0
expect "job status COMPLETE" has "$L/STATUS.job" " COMPLETE "
expect "the plan split the work into 3 date ranges" test "$(grep -c '^SLICE ' "$L/job-plan.txt")" = 3
expect "all 132 files present" test "$(nfiles)" = 132
dups=$(cat "$L"/pass-s*.log | grep ' INFO     Downloaded ' | sed 's/.*Downloaded //' | sort | uniq -d | wc -l | tr -d ' ')
expect "no file was downloaded by two downloaders" test "$dups" = 0
expect "each downloader used its own session copy" test -f "$W/state/cookies/s1/testuserexamplecom.session" -a -f "$W/state/cookies/s3/testuserexamplecom.session"
expect "the final whole-library pass found nothing left (the ranges covered everything)" \
  test "$(cat "$L"/pass-full-*.log | grep -c ' INFO     Downloaded ')" = 0
bash "$S/status.sh" >"$W/status.out" 2>&1
expect "status.sh runs" test $? = 0
expect "status shows the finished job" has "$W/status.out" "COMPLETE"
expect "status shows what's on the drive" has "$W/status.out" "On drive:"

# ------------------------------------------------------------------------------------ verification
ipb reconcile >"$W/rec.out" 2>&1
expect "reconcile: exact match (exit 0)" test $? = 0
expect "reconcile explains the look-alike pair" has "$W/rec.out" "look-alike"
f=$(find "$D" -name IMG_0003.JPG); mv "$f" "$W/moved"
ipb reconcile >"$W/rec2.out" 2>&1
expect "reconcile catches a missing file (exit 1)" test $? = 1
expect "...and names it" has "$W/rec2.out" "IMG_0003.JPG"
mv "$W/moved" "$f"
IPB_SPOTCHECK_MAGIC_ONLY=1 bash "$S/verify.sh" >"$W/verify.out" 2>&1
expect "verify.sh: all checks pass" test $? = 0
expect "inventory counts 12 Live Photo videos" grep -qE "Live Photo videos \(estimated\) +12 " "$W/verify.out"
mkdir -p "$D/2020/05"; cp -p "$f" "$D/2020/05/copy-of-IMG_0003.JPG"
ipb dupes >"$W/dupes.out" 2>&1
expect "dupes finds an identical copy" has "$W/dupes.out" "identical-content groups: 1 "
rm "$D/2020/05/copy-of-IMG_0003.JPG"
mkdir -p "$D/2021/03"; printf 'not a photo' > "$D/2021/03/BROKEN.JPG"
ipb spotcheck --magic-only --per-year 1000 >"$W/spot.out" 2>&1
expect "spot check flags a damaged file (exit 1)" test $? = 1
expect "...by name" grep -q "BAD 2021/03/BROKEN.JPG" "$W/spot.out"
rm "$D/2021/03/BROKEN.JPG"

ipb manifest create >"$W/m.out" 2>&1
expect "manifest create" test $? = 0
expect "manifest files written" test -s "$D/_manifest/SHA256SUMS" -a -s "$D/_manifest/index.tsv"
if command -v sha256sum >/dev/null 2>&1; then chk=(sha256sum -c --quiet); else chk=(shasum -a 256 -c --quiet); fi
(cd "$D" && "${chk[@]}" _manifest/SHA256SUMS) >/dev/null 2>&1
expect "standard tools can verify SHA256SUMS" test $? = 0
ipb manifest check >/dev/null 2>&1; expect "manifest check: all match" test $? = 0
cp -p "$f" "$W/orig"
"$PY" -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[-1]^=1; open(p,"wb").write(bytes(b))' "$f"
ipb manifest check >"$W/mc.out" 2>&1
expect "manifest check catches a changed byte (exit 1)" test $? = 1
expect "...and calls it CORRUPT" has "$W/mc.out" "CORRUPT: "
cp -p "$W/orig" "$f"
mv "$f" "$W/moved"; ipb manifest check >"$W/mc2.out" 2>&1
expect "manifest check catches a missing file" test $? = 1 -a -n "$(grep 'MISSING: ' "$W/mc2.out")"
mv "$W/moved" "$f"
mkdir -p "$D/2024/12"; printf '\xff\xd8\xffnew photo' > "$D/2024/12/NEW.JPG"
ipb manifest check >"$W/mc3.out" 2>&1
expect "a new file is reported, not treated as a problem" test $? = 0 -a -n "$(grep 'NEW since the manifest: 1' "$W/mc3.out")"
ipb manifest update >"$W/mu.out" 2>&1
expect "manifest update adds the new file" has "$W/mu.out" "(1 new"
rm "$D/2024/12/NEW.JPG"
ipb reconcile >/dev/null 2>&1; expect "reconcile ignores the _manifest folder" test $? = 0

# ------------------------------------------------------------------------------------ top-up, stop, resume
FAKE_EXTRA=5 bash "$S/start.sh" --top-up 10 --foreground >/dev/null 2>&1
expect "top-up completes" test $? = 0
expect "top-up saved the 6 new files (5 items, one a Live Photo)" test "$(find "$D" -name 'IMG_9*' | wc -l | tr -d ' ')" = 6
expect "top-up stopped early instead of walking the whole library" \
  test "$(cat "$L"/pass-topup-*.log | grep -c 'already exists')" -le 40

fresh stop
FAKE_DELAY=0.05 bash "$S/start.sh" >"$W/start.out" 2>&1
expect "start.sh launches a background job" test $? = 0
sleep 2
bash "$S/stop.sh" >"$W/stop.out" 2>&1
expect "stop.sh stops it" test $? = 0
sleep 0.5
if alive; then nok "nothing is left running"; else ok "nothing is left running"; fi
expect "the status says STOPPED_BY_USER" has "$L/STATUS.job" "STOPPED_BY_USER"
bash "$S/start.sh" --foreground >/dev/null 2>&1
expect "starting again resumes and completes" test $? = 0
expect "...with every file present" test "$(nfiles)" = 132

# ------------------------------------------------------------------------------------ tools
fresh tools
listing="$W/listing.txt"
for m in 2022-12 2023-01 2023-02; do for i in 1 2 3 4; do echo "$D/${m%-*}/${m#*-}/IMG_$m-$i.JPG"; done; done > "$listing"
ipb plan "$listing" --dest "$D" --slices 3 >"$W/plan.out" 2>/dev/null
expect "plan: newest range is open towards now" grep -qx "SLICE s1 --skip-created-before 2023-02-01T00:00:00" "$W/plan.out"
expect "plan: middle range ends on the last microsecond of January" \
  grep -qx "SLICE s2 --skip-created-before 2023-01-01T00:00:00 --skip-created-after 2023-01-31T23:59:59.999999" "$W/plan.out"
expect "plan: oldest range crosses the year boundary correctly" grep -qx "SLICE s3 --skip-created-after 2022-12-31T23:59:59.999999" "$W/plan.out"
ipb plan "$listing" --dest "$D" --slices 8 >"$W/plan8.out" 2>/dev/null
expect "plan never makes more ranges than months" test "$(grep -c '^SLICE' "$W/plan8.out")" = 3
bash "$S/run-backup.sh" >/dev/null 2>&1
mkdir -p "$W/other/sub"; cp "$(find "$D" -name IMG_0003.JPG)" "$W/other/sub/"; printf '\xff\xd8\xff new' > "$W/other/sub/NEW.JPG"
ipb find-outside --search "$W/other" >"$W/fo.out" 2>&1
expect "find-outside: recognises a copy already in the backup" grep -qE "already in the backup \(identical copy\): 1$" "$W/fo.out"
expect "find-outside: finds the photo that isn't" grep -qE "NOT in the backup: +1 " "$W/fo.out"
mkdir -p "$W/bad-session"; echo '{}' > "$W/bad-session/x.session"
ipb copy-session "$W/bad-session" "$W/copy" >/dev/null 2>&1
expect "copy-session rejects an invalid session" test $? = 1
ipb copy-session "$W/state/cookies/main" "$W/copy" >/dev/null 2>&1
expect "copy-session copies a valid one" test $? = 0 -a -f "$W/copy/testuserexamplecom.session"
ipb fsinfo "$D" >"$W/fs.out" 2>&1
expect "fsinfo reports the filesystem" grep -q '^fstype=.' "$W/fs.out"
bash "$S/doctor.sh" >"$W/doctor.out" 2>&1
expect "doctor: ready (exit 0)" test $? = 0
expect "doctor recognises the tested icloudpd version" has "$W/doctor.out" "the tested version"
ipb inventory >"$W/inv.out" 2>&1
expect "inventory runs" test $? = 0

echo
if [ "$FAIL" -eq 0 ]; then
  rm -rf "$T"
  echo "All $PASS checks passed."
else
  echo "$FAIL of $((PASS + FAIL)) checks FAILED - test files kept in $T"; exit 1
fi
