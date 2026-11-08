#!/bin/bash
# doctor.sh - checks that everything is ready for a backup. Read-only. Fix every FAIL first.
set -u
. "$(dirname "$0")/lib.sh"
fails=0; warns=0
ok()   { printf '  OK    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
echo "iCloud Photos backup - checkup"

if ! ipb_load_config; then
  fail "no settings file at $IPB_CONFIG - run setup.sh first"; echo; echo "Result: run setup.sh first"; exit 1
fi
msg=$( (ipb_init) 2>&1 >/dev/null )
if [ -n "$msg" ]; then fail "${msg#ERROR: }"; echo; echo "Result: fix the settings first"; exit 1; fi
ipb_init
ok "settings: $IPB_CONFIG (Apple ID $APPLE_ID, library $LIBRARY, sizes: $SIZES)"

if "$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
  ok "Python for the check tools: $("$PYTHON" -V 2>&1)"
else
  fail "PYTHON=$PYTHON is missing or older than 3.9 (set PYTHON= in the settings)"
fi

v=$("$ICLOUDPD" --version 2>&1 | head -1)
case "$v" in
  version:"$IPB_ICLOUDPD_VERSION",*) ok "icloudpd $IPB_ICLOUDPD_VERSION (the tested version)";;
  version:*) warn "icloudpd ${v%%,*} - these scripts are tested with $IPB_ICLOUDPD_VERSION (install-icloudpd.sh installs it)";;
  *) fail "icloudpd doesn't start (${ICLOUDPD}): ${v:-not found} - run install-icloudpd.sh";;
esac

if [ ! -d "$DEST" ]; then
  fail "backup folder not found: $DEST - plug in the drive"
elif ! ls "$DEST" >/dev/null 2>&1; then
  fail "macOS blocks access to $DEST - allow your terminal app under System Settings > Privacy & Security > Files and Folders (Removable Volumes)"
elif ! ipb_drive_ok; then
  fail "$DEST is missing its ID file or has a different one - wrong drive? (setup.sh marks the right folder)"
else
  info=$("$PYTHON" -I "$IPB_PY" fsinfo "$DEST" 2>/dev/null)
  fstype=$(echo "$info" | sed -n 's/^fstype=//p'); free=$(echo "$info" | sed -n 's/^free_gb=//p')
  internal=$(echo "$info" | sed -n 's/^internal=//p'); mnt=$(echo "$info" | sed -n 's/^mount=//p')
  ok "backup folder: $DEST (on $mnt, ${fstype:-?}, ${free:-?} GB free)"
  case "$fstype" in
    apfs|hfs|ext4|xfs|btrfs|zfs|"") ;;
    exfat|msdos|vfat|fat32) warn "the drive is formatted $fstype: it works, but it has no journal, so unplugging it mid-copy can damage files (APFS is safer on a Mac)";;
    ntfs) fail "NTFS drives are read-only on macOS - use an APFS or exFAT drive";;
    *) warn "unusual filesystem '$fstype'";;
  esac
  [ "$internal" = yes ] && warn "this folder is on the computer's own disk - a copy on the same disk doesn't protect against that disk failing, and a big library can fill it"
  [ -w "$DEST" ] || fail "no write permission for $DEST"
  if [ -n "$free" ] && [ "$free" -lt "$MIN_FREE_GB" ]; then fail "only $free GB free (the backup stops below $MIN_FREE_GB GB)"; fi
fi

s=$(ls -t "$COOKIE_ROOT/main"/*.session 2>/dev/null | head -1)
if [ -n "$s" ]; then
  when=$("$PYTHON" -c 'import os,sys,time; print(time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(sys.argv[1]))))' "$s" 2>/dev/null)
  ok "signed in to iCloud (sign-in saved $when)"
else
  warn "not signed in yet - the user runs signin.sh in their own terminal window (it asks for the password)"
fi

busy=$(ipb_running)
if [ -n "$busy" ]; then ok "a backup is running right now (pid $busy) - status.sh shows progress"; else ok "no backup running"; fi
if command -v screen >/dev/null 2>&1; then ok "screen is available (jobs keep running in the background)"; else warn "screen not found - jobs run with nohup instead (that works too)"; fi
if [ "$(uname)" = Darwin ]; then
  if command -v caffeinate >/dev/null 2>&1; then ok "jobs keep the Mac awake (caffeinate) - keep it plugged in to power"; else warn "caffeinate not found - stop the Mac from sleeping during the backup"; fi
else
  warn "make sure this computer doesn't sleep during the backup"
fi
if command -v ffprobe >/dev/null 2>&1; then ok "spot checks can open videos (ffprobe)"; else warn "ffprobe not found - videos get a lighter spot check (brew install ffmpeg)"; fi
if [ "$(uname)" = Darwin ]; then ok "spot checks can open photos (sips)"; fi

echo
if [ "$fails" -gt 0 ]; then echo "Result: $fails problem(s) to fix first"; exit 1; fi
echo "Result: ready ($warns warning(s))"
