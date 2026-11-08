#!/bin/bash
# stop.sh - stop the running backup cleanly. Half-finished downloads stay as .part files and
# resume on the next start.sh. Deletes nothing.
set -u
. "$(dirname "$0")/lib.sh"
ipb_init
busy=$(ipb_running)
if [ -z "$busy" ]; then echo "Nothing is running."; exit 0; fi
job=$(cat "$STATE_DIR/job.lock/pid" 2>/dev/null)
if ipb_pid_alive "$job" 'orchestrate\.sh'; then targets="$job"; else targets="$busy"; fi
echo "Stopping (pid $targets) - this can take up to a minute..."
for p in $targets; do kill -TERM "$p" 2>/dev/null; done
i=0
while [ -n "$(ipb_running)" ] && [ "$i" -lt 150 ]; do sleep 0.5; i=$((i + 1)); done
for p in $(ipb_running); do ipb_stop_pid "$p" 5; done
for f in "$LOGDIR"/icloudpd.*.pid; do              # any downloader left behind by a killed wrapper
  [ -f "$f" ] || continue
  p=$(cat "$f" 2>/dev/null)
  if ipb_pid_alive "$p" 'icloudpd'; then ipb_stop_pid "$p" 10; fi
done
if [ -n "$(ipb_running)" ]; then echo "Still running: $(ipb_running) - try stop.sh again"; exit 1; fi
case "$(cut -c21- "$LOGDIR/STATUS.job" 2>/dev/null)" in
  STOPPED*|COMPLETE*|AUTH_NEEDED*|DONE_WITH*|EMPTY*|REFUSED*) ;;
  *) echo "$(date '+%F %T') STOPPED_BY_USER - start.sh resumes where it left off" > "$LOGDIR/STATUS.job";;
esac
echo "Stopped. Nothing was lost: start.sh picks up where it left off."
