#!/bin/bash
# status.sh - plain-language progress report (read-only).
set -u
. "$(dirname "$0")/lib.sh"
ipb_init
exec "$PYTHON" -I "$IPB_PY" status
