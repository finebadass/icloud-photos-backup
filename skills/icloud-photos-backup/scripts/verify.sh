#!/bin/bash
# verify.sh - read-only checks after a backup. Changes nothing.
#   1. reconcile  - exact: every file icloudpd listed in its last complete pass is on the drive
#   2. inventory  - photos / videos / Live Photo videos, sizes, date range, leftovers
#   3. dupes      - identical files by SHA-256 (sizes first, so it's fast)
#   4. spotcheck  - opens random files from every year
# Results are saved in the logs folder (verify-<date>/). Exit 0 = all good.
set -u
. "$(dirname "$0")/lib.sh"
ipb_init
ipb_drive_ok || ipb_die "the backup folder isn't available: $DEST (plug in the drive)" 5
busy=$(ipb_running)
[ -n "$busy" ] && echo "NOTE: a backup is still running (pid $busy) - these results are provisional."
out="$LOGDIR/verify-$(date '+%Y%m%d-%H%M%S')"; mkdir -p "$out"
echo "== 1/4 reconcile";  "$PYTHON" -I "$IPB_PY" reconcile "$DEST" --report "$out/reconcile.tsv" | tee "$out/reconcile.txt"; r1=${PIPESTATUS[0]}
echo; echo "== 2/4 inventory"; "$PYTHON" -I "$IPB_PY" inventory "$DEST" | tee "$out/inventory.txt"
echo; echo "== 3/4 duplicates"; "$PYTHON" -I "$IPB_PY" dupes "$DEST" --report "$out/dupes.tsv" | tee "$out/dupes.txt"
echo; echo "== 4/4 spot check"; "$PYTHON" -I "$IPB_PY" spotcheck "$DEST" | tee "$out/spotcheck.txt"; r4=${PIPESTATUS[0]}
echo
echo "Saved in: $out"
if [ "$r1" -eq 0 ] && [ "$r4" -eq 0 ]; then echo "RESULT: OK"; exit 0; fi
echo "RESULT: needs attention (reconcile exit $r1, spot check exit $r4)"; exit 1
