#!/bin/bash
# signin.sh - sign in to iCloud for the backup. YOU run this, in your own terminal window:
# icloudpd asks for your Apple ID password and the 6-digit code itself, so they never pass through
# Claude or these scripts. The sign-in is saved in the private state folder (chmod 700).
#   signin.sh          normal sign-in
#   signin.sh --adp    your account has Advanced Data Protection: approve the request that then
#                      appears on your iPhone, iPad or Mac
set -u
. "$(dirname "$0")/lib.sh"
ipb_init
adp=0
case "${1:-}" in --adp) adp=1;; "") ;; *) echo "usage: signin.sh [--adp]" >&2; exit 64;; esac
if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "Sign-in needs your own terminal window, because it asks for your password."
  echo "Open Terminal (or the terminal panel of your Claude app) and run:"
  echo "  bash \"$IPB_SCRIPTS/signin.sh\"${1:+ $1}"
  exit 64
fi
busy=$(ipb_running)
if [ -n "$busy" ]; then echo "A backup is running (pid $busy). Stop it first with stop.sh, then sign in."; exit 75; fi
if ! [ -x "$ICLOUDPD" ] && ! command -v "$ICLOUDPD" >/dev/null 2>&1; then
  echo "icloudpd not found at $ICLOUDPD - run install-icloudpd.sh first"; exit 69
fi
mkdir -p "$COOKIE_ROOT/main"; chmod 700 "$COOKIE_ROOT" "$COOKIE_ROOT/main"
args=(--password-provider console --mfa-provider console)
if [ "$DOMAIN" = cn ]; then args+=(--domain cn); fi
args+=(--username "$APPLE_ID" --cookie-directory "$COOKIE_ROOT/main" --auth-only)
if [ "$adp" = 1 ]; then args+=(--adp-web-access); fi
echo "Signing in to iCloud as $APPLE_ID."
echo "Type your Apple ID password when asked (nothing shows while you type), then the 6-digit code."
echo
"$ICLOUDPD" "${args[@]}"; rc=$?
echo
if [ "$rc" -eq 0 ] && ipb_has_session "$COOKIE_ROOT/main"; then
  echo "Signed in. Go back to Claude and say \"signed in\". You can close this window."
else
  echo "The sign-in did not finish (exit $rc). Check the Apple ID and password and try again."
  echo "If your account uses Advanced Data Protection, run: bash \"$IPB_SCRIPTS/signin.sh\" --adp"
fi
exit "$rc"
