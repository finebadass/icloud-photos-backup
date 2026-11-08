#!/bin/bash
# setup.sh - create the settings file and mark the backup folder. Run once (again with --force).
# usage: setup.sh --apple-id you@example.com --dest "/Volumes/MyDrive/iCloud Photos" [options]
#   --sizes "original adjusted"   also save your edited versions (default: originals only)
#   --library NAME                PrimarySync (your own library, default) or a Shared Library
#                                 name from libraries.sh
#   --xmp-sidecar                 also save .xmp files with extra details (title, keywords, place)
#   --file-match-policy name-id7  one file per iCloud item; names get a short ID. Only for a new,
#                                 empty folder (default: name-size-dedup-with-suffix)
#   --folder-structure F          default "{:%Y/%m}" = year/month folders
#   --domain cn                   Apple IDs from mainland China
#   --keep-unicode                keep non-English letters in file names
#   --state-dir DIR               where the sign-in and logs live (default ~/.local/state/
#                                 icloud-photos-backup); give each settings file its own
#   --force                       replace existing settings (the old file is kept as config.bak)
# The backup folder gets a small hidden ID file. Backups only ever write into a folder holding
# that ID, so an unplugged drive can never make them fill up the computer's own disk.
set -u
. "$(dirname "$0")/lib.sh"
apple=""; dest=""; sizes="original"; library="PrimarySync"; xmp="no"; policy="name-size-dedup-with-suffix"
folders="$IPB_DEFAULT_FOLDERS"; domain="com"; unicode="no"; force=0; statedir=""
need() { [ $# -ge 2 ] && [ -n "$2" ] || ipb_die "$1 needs a value" 64; }
while [ $# -gt 0 ]; do
  case "$1" in
    --apple-id) need "$@"; apple="$2"; shift 2;;
    --dest) need "$@"; dest="$2"; shift 2;;
    --sizes) need "$@"; sizes="$2"; shift 2;;
    --library) need "$@"; library="$2"; shift 2;;
    --xmp-sidecar) xmp="yes"; shift;;
    --file-match-policy) need "$@"; policy="$2"; shift 2;;
    --folder-structure) need "$@"; folders="$2"; shift 2;;
    --domain) need "$@"; domain="$2"; shift 2;;
    --keep-unicode) unicode="yes"; shift;;
    --state-dir) need "$@"; statedir="$2"; shift 2;;
    --force) force=1; shift;;
    -h|--help) sed -n '2,19p' "$0"; exit 0;;
    *) ipb_die "unknown option '$1' (see setup.sh --help)" 64;;
  esac
done
[ -n "$apple" ] && [ -n "$dest" ] || ipb_die "usage: setup.sh --apple-id you@example.com --dest /path/to/backup-folder" 64
case "$apple" in *@*.*) ;; *) ipb_die "'$apple' doesn't look like an Apple ID email" 64;; esac
case "$dest" in /*) ;; *) ipb_die "--dest must be a full path starting with / (e.g. /Volumes/MyDrive/iCloud Photos)" 64;; esac
dest="${dest%/}"
case "$statedir" in ""|/*) ;; *) ipb_die "--state-dir must be a full path" 64;; esac
for v in "$apple" "$dest" "$sizes" "$library" "$folders" "$statedir"; do
  case "$v" in *'"'*|*'\'*) ipb_die "values can't contain \" or \\ characters: $v" 64;; esac
done
for s in $sizes; do case "$s" in original|adjusted|alternative|medium|thumb) ;; *) ipb_die "unknown size '$s'" 64;; esac; done
case "$policy" in name-size-dedup-with-suffix|name-id7) ;; *) ipb_die "--file-match-policy must be name-size-dedup-with-suffix or name-id7" 64;; esac
case "$domain" in com|cn) ;; *) ipb_die "--domain must be com or cn" 64;; esac

if [ -f "$IPB_CONFIG" ] && [ "$force" = 0 ]; then
  echo "Settings already exist at $IPB_CONFIG:"; grep -E '^(APPLE_ID|DEST)=' "$IPB_CONFIG"
  echo "Use --force to replace them (the old file is kept as config.bak)."; exit 1
fi
parent=$(dirname "$dest")
if [ ! -d "$dest" ]; then
  [ -d "$parent" ] || ipb_die "$parent doesn't exist - is the drive plugged in?" 5
  mkdir -p "$dest" || ipb_die "can't create $dest" 73
fi
ls "$dest" >/dev/null 2>&1 || ipb_die "macOS blocks access to $dest - allow your terminal app under System Settings > Privacy & Security > Files and Folders (Removable Volumes), then try again" 77

if [ -f "$dest/$IPB_MARKER" ]; then
  drive_id=$(tr -d '[:space:]' < "$dest/$IPB_MARKER")
  echo "This folder was already set up (ID $drive_id) - keeping its ID."
else
  drive_id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  printf '%s\n' "$drive_id" > "$dest/$IPB_MARKER" || ipb_die "can't write to $dest" 73
fi
years=$(find "$dest" -mindepth 1 -maxdepth 1 -type d -name '[12][0-9][0-9][0-9]' 2>/dev/null | wc -l | tr -d ' ')
if [ "$years" -gt 0 ]; then
  echo "Found an existing backup here ($years year folders). Keep the settings that created it"
  echo "(folder structure, file-match policy, sizes), otherwise files get downloaded again under new names."
  [ "$policy" = name-id7 ] && echo "WARNING: name-id7 renames every file - with an existing backup it re-downloads everything."
fi

py=$(command -v python3 || true)
icloudpd="$IPB_DATA/venv/bin/icloudpd"
if [ ! -x "$icloudpd" ] && command -v icloudpd >/dev/null 2>&1; then
  icloudpd=$(command -v icloudpd)
  echo "Using the icloudpd already on this computer: $icloudpd (install-icloudpd.sh installs the tested version)"
fi
mkdir -p "$(dirname "$IPB_CONFIG")"
[ -f "$IPB_CONFIG" ] && cp -p "$IPB_CONFIG" "$IPB_CONFIG.bak"
umask 077
cat > "$IPB_CONFIG" <<EOF
# icloud-photos-backup settings - written by setup.sh on $(date '+%F %T').
# Plain KEY="value" lines; nothing in this file is executed. Re-run setup.sh --force to change.
APPLE_ID="$apple"
DEST="$dest"
DRIVE_ID="$drive_id"
SIZES="$sizes"
LIVE_PHOTO_SIZE="original"
LIBRARY="$library"
XMP_SIDECAR="$xmp"
FILE_MATCH_POLICY="$policy"
FOLDER_STRUCTURE="$folders"
DOMAIN="$domain"
KEEP_UNICODE="$unicode"
MIN_FREE_GB="20"
STALL_MIN="60"
MAX_PASSES="40"
DRIVE_WAIT_MAX_MIN="360"
PYTHON="${py:-python3}"
ICLOUDPD="$icloudpd"
EOF
if [ -n "$statedir" ]; then printf 'STATE_DIR="%s"\n' "$statedir" >> "$IPB_CONFIG"; fi
echo "Settings saved: $IPB_CONFIG"
echo "Backup folder:  $dest"
echo "Next: bash \"$IPB_SCRIPTS/doctor.sh\""
