#!/bin/bash
# run-backup.sh - runs icloudpd pass after pass until one pass finds nothing new and logs no errors.
#
# One copy of this script is one "slice": the whole library (SLICE=full, the default) or one date
# range of it (SLICE=s1..sN, set up by orchestrate.sh). Running it again is always safe: icloudpd
# skips files already on the drive (same name and size) and resumes half-finished downloads from
# their .part files. Normally started for you by start.sh.
#
# usage: [SLICE=name] [COOKIES=session-folder] run-backup.sh [--skip-created-before T]
#                                                [--skip-created-after T] [--until-found N] [--recent N]
# exit codes: 0 COMPLETE  2 AUTH_NEEDED  3 DONE_WITH_ERRORS  4 STOPPED_LOW_DISK
#             5 STOPPED_DRIVE_MISSING  6 STOPPED_MAX_PASSES  7 STOPPED_FAILING  8 EMPTY_LIBRARY
#             64 refused option  75 this slice is already running  76 would overlap another copy
#             130 stopped on request
set -u
. "$(dirname "$0")/lib.sh"
ipb_init

SLICE="${SLICE:-full}"
COOKIES="${COOKIES:-$COOKIE_ROOT/main}"
case "$SLICE" in ""|*[!a-z0-9_-]*) echo "bad SLICE name '$SLICE' (use a-z 0-9 _ -)" >&2; exit 64;; esac
WLOG="$LOGDIR/wrapper.$SLICE.log"; STATUS="$LOGDIR/STATUS.$SLICE"
log()    { echo "$(date '+%F %T') [$SLICE] $*" | tee -a "$WLOG"; }
status() { echo "$(date '+%F %T') $*" > "$STATUS"; log "STATUS $*"; }

# Only date ranges and the "newest first" limits may be passed in. Every other icloudpd option
# comes from the settings file, so nothing that deletes or rewrites anything can sneak in.
MODE=full; i=1
while [ "$i" -le $# ]; do
  a="${!i}"; j=$((i + 1)); v="${!j:-}"
  case "$a" in
    --skip-created-before|--skip-created-after) MODE=slice;;
    --until-found|--recent) ;;
    --auto-delete|--delete-after-download|--keep-icloud-recent-days*|--set-exif-datetime|--prune-orphans*|*password*)
      log "REFUSED forbidden option $a (it deletes or changes things, or handles the password)"; exit 64;;
    *) log "REFUSED option '$a' (only date ranges, --until-found and --recent pass through; everything else lives in the settings file)"; exit 64;;
  esac
  case "$v" in ""|--*) log "REFUSED: $a needs a value"; exit 64;; esac
  i=$((i + 2))
done

# One lock per slice. A whole-library run never shares the folder with another copy, and date
# slices only run next to other date slices (orchestrate.sh makes their ranges non-overlapping).
LOCK="$LOGDIR/run.lock.$SLICE"
if ! mkdir "$LOCK" 2>/dev/null; then
  other=$(cat "$LOCK/pid" 2>/dev/null)
  if ipb_pid_alive "$other" 'run-backup\.sh'; then log "ALREADY RUNNING as pid $other - not starting a second copy of '$SLICE'"; exit 75; fi
fi
echo $$ > "$LOCK/pid"; echo "$MODE" > "$LOCK/mode"; echo "$*" > "$LOCK/args"
sleep 0.3
[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] || { log "another copy of '$SLICE' started at the same moment - leaving it to that one"; exit 75; }
for d in "$LOGDIR"/run.lock.*; do
  [ -d "$d" ] && [ "$d" != "$LOCK" ] || continue
  ipb_pid_alive "$(cat "$d/pid" 2>/dev/null)" 'run-backup\.sh' || continue
  if [ "$MODE" = full ] || [ "$(cat "$d/mode" 2>/dev/null)" != slice ]; then
    log "REFUSED: '${d##*/run.lock.}' is running ($(cat "$d/mode" 2>/dev/null)); a whole-library run never shares the folder with another copy"
    exit 76
  fi
done
echo $$ > "$LOGDIR/wrapper.$SLICE.pid"

ipid=""
on_stop() {
  trap - TERM INT HUP
  if [ -n "$ipid" ]; then ipb_stop_pid "$ipid" "$KILL_GRACE_S"; fi
  status "STOPPED_BY_USER - start.sh resumes where it left off"
  exit 130
}
trap on_stop TERM INT HUP

log "=== start pid $$ mode=$MODE | $("$ICLOUDPD" --version 2>&1 | head -1) | session=$COOKIES | args: $* ==="
if ! ipb_has_session "$COOKIES"; then
  status "AUTH_NEEDED - not signed in yet: run signin.sh in your own terminal, then start.sh"
  exit 2
fi

pass=0; quiet=0; stuck=0; fails=0; waited=0
FAIL_CAP=6
while [ "$pass" -lt "$MAX_PASSES" ]; do
  if ! ipb_drive_ok; then
    if [ "$waited" -ge $((DRIVE_WAIT_MAX_MIN * 60)) ]; then
      status "STOPPED_DRIVE_MISSING - $DEST was not found (or lacks its $IPB_MARKER file)"; exit 5
    fi
    status "WAITING_FOR_DRIVE - plug the backup drive back in ($((waited / 60)) min so far)"
    ipb_nap "$WAIT_S"; waited=$((waited + ${WAIT_S%.*})); [ "${WAIT_S%.*}" = 0 ] && waited=$((waited + 1))
    continue
  fi
  waited=0
  fg=$(ipb_free_gb "$DEST")
  if [ -z "$fg" ] || [ "$fg" -lt "$MIN_FREE_GB" ]; then
    status "STOPPED_LOW_DISK - only ${fg:-?} GB free on the drive (limit $MIN_FREE_GB GB)"; exit 4
  fi

  pass=$((pass + 1))
  PLOG="$LOGDIR/pass-$SLICE-$(date '+%Y%m%d-%H%M%S')-$(printf '%02d' "$pass").log"   # unique even for quick passes
  status "RUNNING pass $pass -> $PLOG"
  ipb_icloudpd_args "$COOKIES"
  "$ICLOUDPD" "${IPB_ARGS[@]}" "$@" </dev/null >"$PLOG" 2>&1 &
  ipid=$!; echo "$ipid" > "$LOGDIR/icloudpd.$SLICE.pid"
  while kill -0 "$ipid" 2>/dev/null; do            # watchdog: a log that stops moving = a hung pass
    ipb_nap "$POLL_S"
    age=$(( $(date +%s) - $(ipb_mtime "$PLOG") ))
    if [ "$age" -gt "$STALL_S" ]; then
      log "pass $pass: no output for ${age}s - stopping icloudpd $ipid (its .part file resumes next pass)"
      ipb_stop_pid "$ipid" "$KILL_GRACE_S"
    fi
  done
  wait "$ipid"; rc=$?; ipid=""

  n_dl=$(grep -c "DEBUG    Downloading /" "$PLOG")
  n_have=$(grep -c " already exists$" "$PLOG")
  n_err=$(grep -c " ERROR " "$PLOG")
  total=$(sed -nE 's/.* INFO +Downloading ([0-9]+) .*/\1/p' "$PLOG" | head -1)
  log "pass $pass done rc=$rc downloaded=$n_dl already_present=$n_have errors=$n_err icloud_items=${total:-?}"

  if [ "$rc" -ne 0 ] && grep -qE "$IPB_AUTH_RX" "$PLOG"; then
    status "AUTH_NEEDED - Apple wants you to sign in again: run signin.sh in your own terminal, then start.sh ($PLOG)"; exit 2
  fi
  if [ "$rc" -eq 0 ] && [ "${total:-1}" = 0 ]; then
    status "EMPTY_LIBRARY - iCloud returned 0 items; check LIBRARY in the settings and Advanced Data Protection ($PLOG)"; exit 8
  fi
  if [ "$rc" -eq 0 ] && [ "$n_dl" -eq 0 ]; then
    if [ "$n_err" -eq 0 ]; then
      status "COMPLETE - pass $pass found nothing new and no errors ($n_have files checked) ($PLOG)"; exit 0
    fi
    quiet=$((quiet + 1))
    if [ "$quiet" -ge 2 ]; then
      status "DONE_WITH_ERRORS - $n_err errors keep repeating with nothing new to download ($PLOG)"; exit 3
    fi
  else
    quiet=0
  fi
  if [ "$rc" -ne 0 ]; then
    fails=$((fails + 1))
    if [ "$n_dl" -eq 0 ]; then stuck=$((stuck + 1)); else stuck=0; fi
    if [ "$stuck" -ge "$FAIL_CAP" ]; then
      status "STOPPED_FAILING - icloudpd failed $stuck passes in a row without saving anything ($PLOG)"; exit 7
    fi
    w=$((fails * RETRY_BASE_S)); [ "$w" -gt 1800 ] && w=1800
    log "rc=$rc -> retry in ${w}s"; ipb_nap "$w"
  else
    fails=0; stuck=0; ipb_nap "$GAP_S"
  fi
done
status "STOPPED_MAX_PASSES - $MAX_PASSES passes without finishing; see the latest log"; exit 6
