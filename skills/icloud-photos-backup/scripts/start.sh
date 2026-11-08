#!/bin/bash
# start.sh - start (or resume) the backup in the background.
#   start.sh                 one downloader over the whole library
#   start.sh --parallel N    N downloaders on separate date ranges (2-6, 3 is a good default for
#                            big libraries), then one final whole-library pass
#   start.sh --top-up [N]    quick update with the newest items (stops after N already-saved in a row)
#   --foreground             run here instead of in the background (used by the tests)
# The job keeps running after you close Claude or the terminal; the computer must stay on and the
# drive plugged in. Progress: status.sh. Stop: stop.sh. Starting again later resumes; nothing is lost.
set -u
. "$(dirname "$0")/lib.sh"
ipb_init
mode=full; n=""; fg=0
while [ $# -gt 0 ]; do
  case "$1" in
    --parallel) mode=parallel; n="${2:-}"; [ $# -ge 2 ] && shift; shift;;
    --top-up|--topup) mode=topup; case "${2:-}" in [0-9]*) n="$2"; shift;; esac; shift;;
    --foreground) fg=1; shift;;
    -h|--help) sed -n '2,9p' "$0"; exit 0;;
    *) echo "unknown option '$1' (see start.sh --help)" >&2; exit 64;;
  esac
done
if [ "$mode" = parallel ]; then
  case "$n" in [2-6]) ;; *) echo "--parallel needs a number from 2 to 6 (3 is a good default)" >&2; exit 64;; esac
fi

busy=$(ipb_running)
if [ -n "$busy" ]; then
  echo "A backup is already running (pid $busy). Progress: status.sh - to stop it: stop.sh"; exit 75
fi
if ! ipb_drive_ok; then
  echo "The backup folder isn't available: $DEST"
  echo "Plug in the drive. (The folder must contain the hidden $IPB_MARKER file that setup.sh created.)"; exit 5
fi
if ! ipb_has_session "$COOKIE_ROOT/main"; then
  echo "Not signed in to iCloud yet. In your own terminal window, run:"
  echo "  bash \"$IPB_SCRIPTS/signin.sh\""; exit 2
fi
if ! [ -x "$ICLOUDPD" ] && ! command -v "$ICLOUDPD" >/dev/null 2>&1; then
  echo "icloudpd not found at $ICLOUDPD - run install-icloudpd.sh first"; exit 69
fi

echo "$(date '+%F %T') STARTING ($mode${n:+ $n})" > "$LOGDIR/STATUS.job"
cmd=(/bin/bash "$IPB_SCRIPTS/orchestrate.sh" "$mode")
if [ -n "$n" ]; then cmd+=("$n"); fi
if [ "$fg" = 1 ]; then exec "${cmd[@]}"; fi
if command -v screen >/dev/null 2>&1; then
  screen -dmS icloud-photos-backup "${cmd[@]}"
  how="the background (screen session 'icloud-photos-backup')"
else
  nohup "${cmd[@]}" >>"$LOGDIR/job.out" 2>&1 </dev/null &
  how="the background (process $!)"
fi
sleep 3
if [ -z "$(ipb_running)" ] && grep -q ' STARTING' "$LOGDIR/STATUS.job" 2>/dev/null; then
  echo "The background job didn't start. Run: bash \"$IPB_SCRIPTS/start.sh\" --foreground  to see why."; exit 1
fi
echo "Backup started in $how: mode $mode${n:+ $n}."
echo "Now: $(cut -c21- "$LOGDIR/STATUS.job" 2>/dev/null)"
echo "Progress any time: bash \"$IPB_SCRIPTS/status.sh\""
