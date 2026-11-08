#!/bin/bash
# shellcheck disable=SC2034  # the variables set here are used by the scripts that source this file
# lib.sh - shared helpers for the icloud-photos-backup scripts. Sourced, never run directly.
# Written for /bin/bash 3.2 (macOS) as well as bash 4/5 (Linux).
#
# Safety rules that every script in this folder follows (tests/run.sh checks the first two):
#   * nothing here deletes, moves or renames files: no rm, rmdir, unlink or mv anywhere
#   * icloudpd only ever receives the options built in ipb_icloudpd_args plus the short
#     allow-list in run-backup.sh, so the options that delete or change things in iCloud
#     (--auto-delete, --delete-after-download, --keep-icloud-recent-days, ...) can't get through
#   * the Apple ID password never passes through these scripts: signin.sh hands your terminal
#     straight to icloudpd, which asks for it itself

IPB_ICLOUDPD_VERSION="1.33.0"
IPB_ICLOUDPD_WHEEL="icloudpd-1.33.0-py3-none-any.whl"
IPB_ICLOUDPD_WHEEL_SHA256="3ff27038ebc17105a5c75a4202e938d4485d80880f8e88b1b4f299e9edc000b8"
IPB_MARKER=".icloud-photos-backup-id"
IPB_DEFAULT_FOLDERS='{:%Y/%m}'
IPB_AUTH_RX='EOFError|Invalid email/password|[Aa]uthentication is required|FailedLogin|FailedMFA|Two-factor authentication is required|Two-step authentication is required|two-step expired|-20101'

IPB_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IPB_PY="$IPB_SCRIPTS/ipb.py"
IPB_CONFIG="${IPB_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/icloud-photos-backup/config}"
IPB_DATA="${IPB_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/icloud-photos-backup}"

ipb_die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }

# Reads KEY=value lines from the settings file into CFG_KEY variables. Nothing in the file is
# executed (it is parsed, not sourced), so a typo can't run a command.
ipb_load_config() {
  [ -f "$IPB_CONFIG" ] || return 1
  local line key val re='^([A-Z_][A-Z0-9_]*)=(.*)$' q1='^"(.*)"$' q2="^'(.*)'$"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ $re ]] || continue
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    if [[ $val =~ $q1 ]] || [[ $val =~ $q2 ]]; then val="${BASH_REMATCH[1]}"; fi
    # shellcheck disable=SC2088  # a literal "~/" at the start of a value means the home folder
    case "$val" in "~/"*) val="$HOME/${val#\~/}";; esac
    case "$key" in
      APPLE_ID|DEST|DRIVE_ID|STATE_DIR|ICLOUDPD|PYTHON|FOLDER_STRUCTURE|SIZES|LIVE_PHOTO_SIZE|\
      FILE_MATCH_POLICY|LIBRARY|DOMAIN|XMP_SIDECAR|KEEP_UNICODE|MIN_FREE_GB|STALL_MIN|MAX_PASSES|\
      DRIVE_WAIT_MAX_MIN)
        printf -v "CFG_$key" '%s' "$val";;
    esac
  done < "$IPB_CONFIG"
  return 0
}

ipb_int() { case "$2" in ''|*[!0-9]*) ipb_die "$1 must be a whole number (got '$2') in $IPB_CONFIG" 78;; esac; }

# Loads the settings, applies defaults, checks them, and creates the state folders.
ipb_init() {
  ipb_load_config || ipb_die "no settings file at $IPB_CONFIG - run setup.sh first" 78
  APPLE_ID="${CFG_APPLE_ID:-}"; DEST="${CFG_DEST:-}"; DRIVE_ID="${CFG_DRIVE_ID:-}"
  [ -n "$APPLE_ID" ] && [ -n "$DEST" ] && [ -n "$DRIVE_ID" ] ||
    ipb_die "$IPB_CONFIG needs APPLE_ID, DEST and DRIVE_ID - run setup.sh again" 78
  STATE_DIR="${CFG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/icloud-photos-backup}"
  ICLOUDPD="${CFG_ICLOUDPD:-$IPB_DATA/venv/bin/icloudpd}"
  PYTHON="${CFG_PYTHON:-python3}"
  FOLDER_STRUCTURE="${CFG_FOLDER_STRUCTURE:-$IPB_DEFAULT_FOLDERS}"
  SIZES="${CFG_SIZES:-original}"
  LIVE_PHOTO_SIZE="${CFG_LIVE_PHOTO_SIZE:-original}"
  FILE_MATCH_POLICY="${CFG_FILE_MATCH_POLICY:-name-size-dedup-with-suffix}"
  LIBRARY="${CFG_LIBRARY:-PrimarySync}"
  DOMAIN="${CFG_DOMAIN:-com}"
  XMP_SIDECAR="${CFG_XMP_SIDECAR:-no}"
  KEEP_UNICODE="${CFG_KEEP_UNICODE:-no}"
  MIN_FREE_GB="${CFG_MIN_FREE_GB:-20}"; STALL_MIN="${CFG_STALL_MIN:-60}"
  MAX_PASSES="${CFG_MAX_PASSES:-40}"; DRIVE_WAIT_MAX_MIN="${CFG_DRIVE_WAIT_MAX_MIN:-360}"
  ipb_int MIN_FREE_GB "$MIN_FREE_GB"; ipb_int STALL_MIN "$STALL_MIN"
  ipb_int MAX_PASSES "$MAX_PASSES"; ipb_int DRIVE_WAIT_MAX_MIN "$DRIVE_WAIT_MAX_MIN"
  local s
  for s in $SIZES; do
    case "$s" in original|adjusted|alternative|medium|thumb) ;; *) ipb_die "SIZES: unknown size '$s'" 78;; esac
  done
  case "$LIVE_PHOTO_SIZE" in original|medium|thumb) ;; *) ipb_die "LIVE_PHOTO_SIZE must be original, medium or thumb" 78;; esac
  case "$FILE_MATCH_POLICY" in name-size-dedup-with-suffix|name-id7) ;; *) ipb_die "FILE_MATCH_POLICY must be name-size-dedup-with-suffix or name-id7" 78;; esac
  case "$DOMAIN" in com|cn) ;; *) ipb_die "DOMAIN must be com or cn" 78;; esac
  case "$DEST" in /*) ;; *) ipb_die "DEST must be an absolute path" 78;; esac
  LOGDIR="$STATE_DIR/logs"; COOKIE_ROOT="$STATE_DIR/cookies"
  # Timings in seconds. The IPB_* environment overrides exist only so the test-suite runs fast.
  POLL_S="${IPB_POLL_S:-15}"; GAP_S="${IPB_GAP_S:-20}"; RETRY_BASE_S="${IPB_RETRY_BASE_S:-120}"
  WAIT_S="${IPB_WAIT_S:-60}"; STAGGER_S="${IPB_STAGGER_S:-20}"; KILL_GRACE_S="${IPB_KILL_GRACE_S:-20}"
  STALL_S="${IPB_STALL_S:-$((STALL_MIN * 60))}"
  mkdir -p "$LOGDIR" "$COOKIE_ROOT" || ipb_die "cannot create $STATE_DIR"
  chmod 700 "$STATE_DIR" "$COOKIE_ROOT" 2>/dev/null
  return 0
}

# Everything after the icloudpd program name, for this account. $1 = session folder;
# any further arguments are extra GLOBAL options (they must come before --username).
ipb_icloudpd_args() {
  local cookies="$1" s; shift
  IPB_ARGS=(--log-level debug --no-progress-bar --password-provider console --mfa-provider console)
  if [ "$DOMAIN" = cn ]; then IPB_ARGS+=(--domain cn); fi
  if [ $# -gt 0 ]; then IPB_ARGS+=("$@"); fi
  IPB_ARGS+=(--username "$APPLE_ID" --cookie-directory "$cookies" --directory "$DEST"
             --folder-structure "$FOLDER_STRUCTURE" --live-photo-size "$LIVE_PHOTO_SIZE"
             --file-match-policy "$FILE_MATCH_POLICY" --library "$LIBRARY")
  for s in $SIZES; do IPB_ARGS+=(--size "$s"); done
  if [ "$XMP_SIDECAR" = yes ]; then IPB_ARGS+=(--xmp-sidecar); fi
  if [ "$KEEP_UNICODE" = yes ]; then IPB_ARGS+=(--keep-unicode-in-filenames); fi
  return 0
}

# The destination counts as "present" only when it holds the ID file setup.sh wrote. An empty
# mount point (drive unplugged) therefore never receives files, so the internal disk can't fill up.
ipb_drive_ok() {
  [ -d "$DEST" ] && [ -f "$DEST/$IPB_MARKER" ] &&
    [ "$(tr -d '[:space:]' < "$DEST/$IPB_MARKER" 2>/dev/null)" = "$DRIVE_ID" ]
}
ipb_free_gb()    { df -Pk "$1" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}'; }
ipb_mtime()      { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
ipb_has_session(){ ls "$1"/*.session >/dev/null 2>&1; }
ipb_pid_alive()  { [ -n "${1:-}" ] && [ "$1" != "$$" ] && ps -p "$1" -o command= 2>/dev/null | grep -qE -- "$2"; }
ipb_nap()        { sleep "$1" & wait $!; }   # a sleep that a stop signal can interrupt

# Prints the pids of every live backup process of this install (job runner and downloaders).
ipb_running() {
  local f pid out=""
  for f in "$STATE_DIR/job.lock/pid" "$LOGDIR"/run.lock.*/pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    if ipb_pid_alive "$pid" 'orchestrate\.sh|run-backup\.sh'; then out="$out $pid"; fi
  done
  echo "${out# }"
}

# Sends TERM, waits up to $2 seconds, then KILL.
ipb_stop_pid() {
  local pid="$1" grace="${2:-20}" i=0
  kill -TERM "$pid" 2>/dev/null || return 0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt $((grace * 2)) ]; do sleep 0.5; i=$((i + 1)); done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  return 0
}

ipb_notify() {   # best effort: a macOS notification when a job ends
  if command -v osascript >/dev/null 2>&1 && [ -z "${IPB_NO_NOTIFY:-}" ]; then
    osascript -e "display notification \"$1\" with title \"iCloud Photos backup\"" >/dev/null 2>&1
  fi
  return 0
}
