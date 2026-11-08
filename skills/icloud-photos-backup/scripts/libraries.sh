#!/bin/bash
# libraries.sh - lists the photo libraries of this Apple ID: your own (PrimarySync) and an iCloud
# Shared Library if you take part in one. Back one up by putting its name in LIBRARY= (setup.sh
# --library NAME --force); a second settings file (IPB_CONFIG=...) can back up the other. Read-only.
set -u
. "$(dirname "$0")/lib.sh"
ipb_init
ipb_has_session "$COOKIE_ROOT/main" || { echo "Sign in first: run signin.sh in your own terminal."; exit 2; }
busy=$(ipb_running)
[ -n "$busy" ] && { echo "A backup is running (pid $busy); try again when it has finished."; exit 75; }
args=(--log-level info --no-progress-bar --password-provider console --mfa-provider console)
if [ "$DOMAIN" = cn ]; then args+=(--domain cn); fi
"$ICLOUDPD" "${args[@]}" --username "$APPLE_ID" --cookie-directory "$COOKIE_ROOT/main" --list-libraries </dev/null
