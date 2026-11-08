#!/bin/bash
# orchestrate.sh - one complete backup job. Started in the background by start.sh.
#   full         ask iCloud what is missing, then one downloader over the whole library
#   parallel N   ask iCloud what is missing, split that list by date into N ranges that cannot
#                overlap, run N downloaders at once, then one final whole-library pass that
#                re-checks everything (it also picks up anything added meanwhile)
#   topup [N]    quick update: newest items first, stop after N already-saved items in a row
# Exit code and STATUS.job follow run-backup.sh (0 = COMPLETE).
set -u
. "$(dirname "$0")/lib.sh"
ipb_init
MODE="${1:-full}"; N="${2:-}"

# Keep the Mac awake (system sleep only; the display may still sleep) for as long as the job runs.
if [ "$(uname)" = Darwin ] && command -v caffeinate >/dev/null 2>&1 && [ -z "${IPB_AWAKE:-}" ]; then
  IPB_AWAKE=1 exec caffeinate -ims /bin/bash "$0" "$@"
fi

JLOCK="$STATE_DIR/job.lock"; JSTATUS="$LOGDIR/STATUS.job"; JLOG="$LOGDIR/job.log"
jlog()    { echo "$(date '+%F %T') [job] $*" | tee -a "$JLOG"; }
jstatus() { echo "$(date '+%F %T') $*" > "$JSTATUS"; jlog "STATUS $*"; }

if ! mkdir "$JLOCK" 2>/dev/null; then
  other=$(cat "$JLOCK/pid" 2>/dev/null)
  if ipb_pid_alive "$other" 'orchestrate\.sh'; then jlog "a backup job is already running (pid $other)"; exit 75; fi
fi
echo $$ > "$JLOCK/pid"; echo "$MODE $N" > "$JLOCK/mode"
busy=$(ipb_running)
if [ -n "$busy" ]; then jstatus "REFUSED - another backup copy is already running (pid $busy)"; exit 75; fi

kids=""
on_stop() {
  trap - TERM INT HUP
  local p
  for p in $kids; do kill -TERM "$p" 2>/dev/null; done
  for p in $kids; do wait "$p" 2>/dev/null; done
  jstatus "STOPPED_BY_USER - start.sh resumes where it left off"
  exit 130
}
trap on_stop TERM INT HUP

# After parallel runs, the freshest Apple session is in one of the slice folders; copy it back so
# the next job starts with a valid session instead of asking for a new sign-in.
refresh_main_session() {
  local newest
  newest=$(ls -t "$COOKIE_ROOT"/*/*.session 2>/dev/null | head -1)
  [ -n "$newest" ] || return 0
  newest=$(dirname "$newest")
  [ "$newest" = "$COOKIE_ROOT/main" ] && return 0
  "$PYTHON" -I "$IPB_PY" copy-session "$newest" "$COOKIE_ROOT/main" >/dev/null 2>&1 ||
    jlog "could not refresh the main session from $newest (next start may ask for a new sign-in)"
  return 0
}

finish() {
  local rc="$1" msg
  refresh_main_session
  case "$rc" in
    0)   if [ "$MODE" = topup ]; then msg="COMPLETE - new photos saved (quick top-up; a full start.sh gives the exact check)"
         else msg="COMPLETE - everything iCloud listed is on the drive; run verify.sh next"; fi;;
    2)   msg="AUTH_NEEDED - Apple wants you to sign in again: run signin.sh in your own terminal, then start.sh";;
    3)   msg="DONE_WITH_ERRORS - some files keep failing; check status.sh and the troubleshooting guide";;
    4)   msg="STOPPED_LOW_DISK - the backup drive is nearly full";;
    5)   msg="STOPPED_DRIVE_MISSING - the backup drive was not found";;
    6|7) msg="STOPPED_FAILING - icloudpd kept failing; see the latest log";;
    8)   msg="EMPTY_LIBRARY - iCloud returned no items; check LIBRARY in the settings / Advanced Data Protection";;
    75|76) msg="REFUSED - another backup copy is already running";;
    130) msg="STOPPED_BY_USER - start.sh resumes where it left off";;
    *)   msg="STOPPED (exit $rc) - see $JLOG";;
  esac
  jstatus "$msg"
  ipb_notify "${msg%% - *}"
  exit "$rc"
}

run_wrapper() {   # $1 = slice name, $2 = session folder, rest = range options; waits for it
  local name="$1" cookies="$2"; shift 2
  SLICE="$name" COOKIES="$cookies" /bin/bash "$IPB_SCRIPTS/run-backup.sh" "$@" >/dev/null 2>&1 &
  kids=$!; wait "$kids"; local rc=$?; kids=""; return "$rc"
}

LISTING=""
make_listing() {   # what iCloud still has to send = the to-do list (used for progress and planning)
  local out rc n
  out="$LOGDIR/listing-$(date '+%Y%m%d-%H%M%S').txt"
  jstatus "LISTING - asking iCloud what is still missing (big libraries: 10+ minutes)"
  ipb_icloudpd_args "$COOKIE_ROOT/main" --only-print-filenames
  "$ICLOUDPD" "${IPB_ARGS[@]}" </dev/null >"$out" 2>"$out.log" &
  kids=$!; wait "$kids"; rc=$?; kids=""
  if [ "$rc" -ne 0 ]; then
    if grep -qE "$IPB_AUTH_RX" "$out" "$out.log" 2>/dev/null; then finish 2; fi
    jlog "listing failed (exit $rc, see $out.log) - continuing without a to-do list"
    return 1
  fi
  n=$(awk -v d="$DEST/" 'index($0, d) == 1' "$out" | sort -u | wc -l | tr -d ' ')   # look-alike items share a path
  echo "$n" > "$LOGDIR/job-listing-count"
  LISTING="$out"
  jlog "to-do list: $n files still to download ($out)"
  return 0
}

date '+%s %F %T' > "$LOGDIR/job-start"
"$PYTHON" -I "$IPB_PY" progress "$DEST" > "$LOGDIR/job-start-progress" 2>/dev/null
: > "$LOGDIR/job-plan.txt"; echo "" > "$LOGDIR/job-listing-count"
jlog "=== job start pid $$ mode=$MODE ${N} ==="

case "$MODE" in
  topup)
    case "$N" in ''|*[!0-9]*) N=200;; esac
    jstatus "TOP-UP - saving photos added since the last backup"
    run_wrapper topup "$COOKIE_ROOT/main" --until-found "$N"; finish $?;;
  full)
    make_listing
    jstatus "RUNNING - one downloader over the whole library"
    run_wrapper full "$COOKIE_ROOT/main"; finish $?;;
  parallel)
    case "$N" in ''|*[!0-9]*) N=3;; esac
    if ! make_listing; then
      jstatus "RUNNING - one downloader (no to-do list to split)"; run_wrapper full "$COOKIE_ROOT/main"; finish $?
    fi
    plan=$("$PYTHON" -I "$IPB_PY" plan "$LISTING" --dest "$DEST" --slices "$N" 2>>"$JLOG")
    echo "$plan" > "$LOGDIR/job-plan.txt"
    nsl=$(echo "$plan" | grep -c '^SLICE ')
    if [ "$nsl" -lt 2 ]; then
      jstatus "RUNNING - one downloader (too little left to split)"; run_wrapper full "$COOKIE_ROOT/main"; finish $?
    fi
    for name in $(echo "$plan" | awk '$1 == "SLICE" {print $2}'); do   # each downloader gets its own session copy
      "$PYTHON" -I "$IPB_PY" copy-session "$COOKIE_ROOT/main" "$COOKIE_ROOT/$name" >>"$JLOG" 2>&1 ||
        { jlog "could not copy the Apple session for $name"; finish 2; }
    done
    pids=""; auth=0; disk=0; stopped=0
    jstatus "SLICES RUNNING - $nsl downloaders on separate date ranges"
    while read -r tag name rest; do
      [ "$tag" = SLICE ] || continue
      set -f; read -r -a range <<< "$rest"; set +f
      SLICE="$name" COOKIES="$COOKIE_ROOT/$name" /bin/bash "$IPB_SCRIPTS/run-backup.sh" ${range[@]+"${range[@]}"} >/dev/null 2>&1 &
      p=$!; kids="$kids $p"; pids="$pids $p"
      jlog "started $name (pid $p): $rest"
      ipb_nap "$STAGGER_S"
    done <<< "$plan"
    for p in $pids; do
      wait "$p"; rc=$?
      case "$rc" in 2) auth=1;; 4|5) disk=$rc;; 130) stopped=1;; esac
      jlog "downloader pid $p finished (exit $rc)"
    done
    kids=""
    [ "$stopped" = 1 ] && finish 130
    [ "$auth" = 1 ] && finish 2
    [ "$disk" != 0 ] && finish "$disk"
    refresh_main_session
    jstatus "FINAL PASS - one downloader re-checks the whole library"
    run_wrapper full "$COOKIE_ROOT/main"; finish $?;;
  *) jlog "unknown mode '$MODE'"; exit 64;;
esac
