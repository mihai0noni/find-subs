#!/usr/bin/env bash
#
# install-deps.sh - Install the Python dependencies find-subs needs.
#
# Installs the SAME packages d3l0g3 installs at container boot (subliminal +
# guessit); everything else (babelfish/requests/beautifulsoup4/PyYAML/...) comes
# in transitively. Reads requirements.txt from this folder.
#
# Usage:
#   ./install-deps.sh              # pip install -r requirements.txt
#   ./install-deps.sh --user       # install into the user site (no admin)
#   ./install-deps.sh --venv       # create ./.venv and install into it
#   ./install-deps.sh --wheels DIR # OFFLINE install from a wheels/ folder
#                                   # (pip install --no-index --find-links DIR)
#
# After it finishes, verify with:  python check-deps.py
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ="$SCRIPT_DIR/requirements.txt"

USER_FLAG=""
MAKE_VENV=""
WHEELS=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --user)   USER_FLAG="--user"; shift ;;
    --venv)   MAKE_VENV="1"; shift ;;
    --wheels) WHEELS="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown option: $1"; exit 2 ;;
  esac
done

[ -f "$REQ" ] || { echo "ERROR: requirements.txt not found next to this script."; exit 1; }

# Resolve a working Python 3 (prefer python3; some Windows 'python3' is a stub).
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys; sys.exit(0 if sys.version_info[0]==3 else 1)" >/dev/null 2>&1; then
    PY="$cand"; break
  fi
done
[ -n "$PY" ] || { echo "ERROR: a working Python 3 (python3/python) was not found in PATH."; exit 1; }
echo "==> Using: $($PY -c 'import sys;print(sys.executable, "(%d.%d.%d)"%sys.version_info[:3])')"

# Optionally create and use a local virtual environment.
if [ -n "$MAKE_VENV" ]; then
  VENV="$SCRIPT_DIR/.venv"
  echo "==> Creating virtual environment: $VENV"
  "$PY" -m venv "$VENV" || { echo "ERROR: failed to create venv."; exit 1; }
  if [ -x "$VENV/bin/python" ]; then PY="$VENV/bin/python"        # POSIX
  elif [ -x "$VENV/Scripts/python.exe" ]; then PY="$VENV/Scripts/python.exe"  # Windows
  fi
  USER_FLAG=""  # --user is invalid inside a venv
fi

# Make sure pip is present and current.
"$PY" -m ensurepip --upgrade >/dev/null 2>&1 || true
"$PY" -m pip install --upgrade pip >/dev/null 2>&1 || true

echo "==> Installing dependencies from requirements.txt ..."
if [ -n "$WHEELS" ]; then
  [ -d "$WHEELS" ] || { echo "ERROR: wheels dir not found: $WHEELS"; exit 1; }
  echo "    (offline: --no-index --find-links $WHEELS)"
  "$PY" -m pip install --no-index --find-links "$WHEELS" -r "$REQ" || { echo "ERROR: install failed."; exit 1; }
else
  "$PY" -m pip install $USER_FLAG -r "$REQ" || { echo "ERROR: install failed."; exit 1; }
fi

echo "==> Done."
echo "==> Verify with:  \"$PY\" \"$SCRIPT_DIR/check-deps.py\""
if [ -n "$MAKE_VENV" ]; then
  echo "==> Activate the venv first, e.g.:  source \"$SCRIPT_DIR/.venv/bin/activate\""
fi
