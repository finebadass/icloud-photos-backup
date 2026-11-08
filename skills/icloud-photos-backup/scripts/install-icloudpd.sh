#!/bin/bash
# install-icloudpd.sh - installs icloudpd 1.33.0, the version these scripts are tested with, into a
# private folder (~/.local/share/icloud-photos-backup/venv). Nothing else on the system changes.
#
# Why not just "pip install icloudpd"? On macOS that picks icloudpd's ready-made build, which in
# 1.33.0 fails to start ("No module named 'unicodedata'"). This installs the plain-Python package
# instead, after checking its SHA-256 against the value pinned in lib.sh.
# Needs Python 3.11-3.15 (icloudpd's own requirement).   Options: --python PATH   --force
set -u
. "$(dirname "$0")/lib.sh"
PY=""; force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --python) PY="${2:-}"; shift 2;;
    --force) force=1; shift;;
    *) echo "usage: install-icloudpd.sh [--python /path/to/python3] [--force]" >&2; exit 64;;
  esac
done
py_ok() { "$1" -c 'import sys; sys.exit(0 if (3, 11) <= sys.version_info[:2] <= (3, 15) else 1)' 2>/dev/null; }
sha_ok() {
  [ -f "$1" ] && [ "$("$PY" -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1")" = "$IPB_ICLOUDPD_WHEEL_SHA256" ]
}
if [ -z "$PY" ]; then
  for c in python3.13 python3.12 python3.14 python3.11 python3.15 python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    p=$(command -v "$c" 2>/dev/null) || continue
    if py_ok "$p"; then PY="$p"; break; fi
  done
fi
if [ -z "$PY" ] || ! py_ok "$PY"; then
  ipb_die "icloudpd needs Python 3.11 to 3.15. On a Mac: install it from python.org, or 'brew install python@3.13', then run this again." 69
fi
VENV="$IPB_DATA/venv"; BIN="$VENV/bin/icloudpd"
if [ "$force" = 0 ] && [ -x "$BIN" ] && "$BIN" --version 2>/dev/null | grep -q "version:$IPB_ICLOUDPD_VERSION"; then
  echo "icloudpd $IPB_ICLOUDPD_VERSION is already installed: $BIN"; exit 0
fi
DL="$IPB_DATA/downloads"; W="$DL/$IPB_ICLOUDPD_WHEEL"
mkdir -p "$DL"
if ! sha_ok "$W"; then
  url=$(curl -fsSL "https://pypi.org/pypi/icloudpd/$IPB_ICLOUDPD_VERSION/json" |
        "$PY" -I -c 'import json,sys; n=sys.argv[1]; print(next(f["url"] for f in json.load(sys.stdin)["urls"] if f["filename"]==n))' "$IPB_ICLOUDPD_WHEEL" 2>/dev/null)
  [ -n "$url" ] || ipb_die "couldn't find $IPB_ICLOUDPD_WHEEL on PyPI (internet connection?)" 69
  echo "Downloading $IPB_ICLOUDPD_WHEEL ..."
  curl -fsSL "$url" -o "$W" || ipb_die "download failed" 69
fi
sha_ok "$W" || ipb_die "SHA-256 of $W doesn't match the pinned value - not installing" 65
echo "Checksum OK ($IPB_ICLOUDPD_WHEEL_SHA256)."
[ -x "$VENV/bin/python" ] || "$PY" -m venv "$VENV" || ipb_die "couldn't create $VENV" 73
"$VENV/bin/python" -m pip install --disable-pip-version-check --quiet --force-reinstall "$W" ||
  ipb_die "pip couldn't install icloudpd (see the messages above)" 70
"$BIN" --version 2>&1 | grep -q "version:$IPB_ICLOUDPD_VERSION" || ipb_die "installed, but '$BIN --version' fails" 70
echo "Installed icloudpd $IPB_ICLOUDPD_VERSION: $BIN"
