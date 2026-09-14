#!/usr/bin/env bash
#
# find-subs.sh - Find & download subtitles for every movie under this folder.
#
# This is a STANDALONE, deployable version of the d3l0g3 subtitle finder. It
# reuses the EXACT SAME subtitle-finding logic as d3l0g3's /config/get-subs.sh:
#
#   1. subliminal download   (all built-in providers + regielive for Romanian)
#        -> exact-match subtitle saved next to the video (Movie.en.srt / .ro.srt)
#   2. subs-alts.py          (two-tier alternatives dump into a "Subs" subfolder)
#        Tier 1: opensubtitles regielive
#        Tier 2: (only if tier 1 found nothing) the wider fallback provider set
#   3. strip_ro_diacritics   (transliterate diacritics in *.ro.* subs to Latin)
#
# UNLIKE d3l0g3, it does NOT touch Kubernetes/Deluge and it does NOT organize
# (move/rename) files -- it only FINDS subtitles. It walks the folder where it
# is deployed RECURSIVELY, so movies in sub-folders are handled too.
#
# Usage:
#   ./find-subs.sh                 # scan every video under the script's folder
#   ./find-subs.sh /path/to/movies # scan every video under a given folder
#   ./find-subs.sh movie.mkv       # a single video file
#
# Requirements (once):
#   pip install -r requirements.txt        (subliminal + guessit)
#
# Safe/idempotent: subliminal skips videos that already have a subtitle; the
# alternatives pass skips languages that already have candidates. Existing
# subtitle files are never deleted -- subtitles are only ever added.
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${FINDSUBS_CONFIG:-$SCRIPT_DIR/config.yaml}"

# Make the bundled RegieLive provider importable by subs-alts.py, matching how
# d3l0g3 ships subliminal_regielive.provider:RegieLiveProvider.
export PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}"

# Resolve a Python 3 interpreter. Prefer a working `python3`, else fall back to
# `python` (on some Windows setups `python3` is a non-functional Store stub).
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys; sys.exit(0 if sys.version_info[0]==3 else 1)" >/dev/null 2>&1; then
    PY="$cand"; break
  fi
done
[ -n "$PY" ] || { echo "ERROR: a working Python 3 (python3/python) was not found in PATH."; exit 1; }

# --- Load config.yaml (if present) -------------------------------------------
# A tiny Python helper reads the YAML and prints shell-eval-able KEY=value lines
# (config parsing lives in one place). Environment variables still WIN over the
# file; the file wins over the built-in defaults below.
CFG_LANGS=""; CFG_REGIELIVE=""; CFG_ALTS=""; CFG_ALTSDIR=""
CFG_ALTPROVIDERS=""; CFG_ALTPROVIDERS2=""; CFG_STRIPRO=""; CFG_MINSCORE=""; CFG_PATHS=""
if [ -f "$CONFIG_FILE" ]; then
  eval "$("$PY" - "$CONFIG_FILE" <<'PY' 2>/dev/null
import sys
try:
    import yaml
    with open(sys.argv[1], encoding="utf-8") as fh:
        c = yaml.safe_load(fh) or {}
except Exception:
    c = {}
def out(k, v):
    if v is None: return
    if isinstance(v, bool): v = "true" if v else "false"
    print("%s='%s'" % (k, str(v).replace("'", "'\\''")))
p = c.get("paths")
if isinstance(p, str): p = [p]
if isinstance(p, (list, tuple)):
    out("CFG_PATHS", "\n".join(str(x) for x in p if str(x).strip()))
out("CFG_LANGS", c.get("langs"))
out("CFG_REGIELIVE", c.get("regielive"))
out("CFG_ALTS", c.get("alternatives"))
out("CFG_ALTSDIR", c.get("alternativesSubfolder"))
out("CFG_ALTPROVIDERS", c.get("alternativesProviders"))
out("CFG_ALTPROVIDERS2", c.get("alternativesProvidersFallback"))
out("CFG_STRIPRO", c.get("stripRomanianDiacritics"))
out("CFG_MINSCORE", c.get("minScore"))
PY
)"
fi

# --- Configuration: env var > config.yaml > built-in default -----------------
LANGS="${LANGS:-${CFG_LANGS:-en ro}}"
REGIELIVE="${REGIELIVE:-${CFG_REGIELIVE:-true}}"
ALTS="${ALTS:-${CFG_ALTS:-true}}"
ALTSDIR="${ALTSDIR:-${CFG_ALTSDIR:-Subs}}"
ALTPROVIDERS="${ALTPROVIDERS:-${CFG_ALTPROVIDERS:-opensubtitles regielive}}"
ALTPROVIDERS2="${ALTPROVIDERS2:-${CFG_ALTPROVIDERS2:-opensubtitles regielive podnapisi tvsubtitles gestdown addic7ed}}"
STRIPRO="${STRIPRO:-${CFG_STRIPRO:-true}}"
MINSCORE="${MINSCORE:-${CFG_MINSCORE:-60}}"
ALTSCRIPT="${ALTSCRIPT:-$SCRIPT_DIR/subs-alts.py}"

# Video extensions to scan for (same set d3l0g3 uses in largest_video()).
VIDEO_EXPR=( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.m4v" -o -iname "*.mov" -o -iname "*.wmv" )

case "${1:-}" in
  -h|--help)
    sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

# Build subliminal args identically to d3l0g3.
LANG_ARGS=""; for l in $LANGS; do LANG_ARGS="$LANG_ARGS -l $l"; done
PROVIDER_ARGS=""
if [ "$REGIELIVE" = "true" ]; then
  for l in $LANGS; do [ "$l" = "ro" ] && PROVIDER_ARGS="--extend-provider regielive"; done
fi

log(){ echo "[find-subs] $*"; }

# strip_ro_diacritics: transliterate Romanian diacritics to plain Latin letters
# in every Romanian subtitle file (*.ro.<ext>) next to $1 (and in its Subs/).
# Byte-for-byte the same transliteration table d3l0g3 uses.
strip_ro_diacritics(){
  [ "$STRIPRO" = "true" ] || return 0
  local vid="$1" dir
  dir="$(dirname "$vid")"
  local -a files=()
  while IFS= read -r -d "" f; do files+=("$f"); done < <(find "$dir" "$dir/$ALTSDIR" -maxdepth 1 -type f \( -iname "*.ro.srt" -o -iname "*.ro.ass" -o -iname "*.ro.ssa" -o -iname "*.ro.vtt" -o -iname "*.ro.sub" -o -iname "*.ro.[0-9][0-9].*" \) -print0 2>/dev/null)
  [ "${#files[@]}" -gt 0 ] || return 0
  "$PY" - "${files[@]}" <<'PY' 2>/dev/null
import sys
M = {0x103:"a",0xE2:"a",0xEE:"i",0x219:"s",0x15F:"s",0x21B:"t",0x163:"t",
     0x102:"A",0xC2:"A",0xCE:"I",0x218:"S",0x15E:"S",0x21A:"T",0x162:"T"}
for path in sys.argv[1:]:
    try:
        data = open(path, "rb").read()
    except Exception:
        continue
    text = None
    for enc in ("utf-8-sig", "utf-8", "cp1250", "iso-8859-2", "latin-1"):
        try:
            text = data.decode(enc); break
        except Exception:
            pass
    if text is None:
        continue
    new = text.translate(M)
    if new != text:
        try:
            open(path, "w", encoding="utf-8").write(new)
            print("[strip-ro] " + path)
        except Exception:
            pass
PY
}

# _alts_count: number of candidate files in a video's Subs folder (same as d3l0g3).
_alts_count(){
  local vid="$1" d stem
  d="$(dirname "$vid")"; stem="$(basename "${vid%.*}")"
  find "$d/$ALTSDIR" -maxdepth 1 -type f -iname "$stem.*" 2>/dev/null | wc -l
}

# fetch_alternatives: two-tier alternatives dump -- identical to d3l0g3.
fetch_alternatives(){
  [ "$ALTS" = "true" ] || return 0
  [ -f "$ALTSCRIPT" ] || return 0
  local vid="$1"
  [ -n "$vid" ] && [ -f "$vid" ] || return 0
  # tier 1: curated providers (collect alternates for ALL configured languages)
  "$PY" "$ALTSCRIPT" --langs "$LANGS" --providers "$ALTPROVIDERS" --subfolder "$ALTSDIR" --all-langs "$vid" 2>&1 | sed "s/^/[subs-alts] /" || true
  # tier 2: only if tier 1 found nothing AND a (different) wider set is set
  if [ "$(_alts_count "$vid")" -eq 0 ] && [ -n "${ALTPROVIDERS2// }" ] && [ "$ALTPROVIDERS2" != "$ALTPROVIDERS" ]; then
    log "no alternatives from primary providers; widening search"
    "$PY" "$ALTSCRIPT" --langs "$LANGS" --providers "$ALTPROVIDERS2" --subfolder "$ALTSDIR" --all-langs "$vid" 2>&1 | sed "s/^/[subs-alts] /" || true
  fi
}

# fetch: run the SAME exact-match + alternatives + diacritics logic on one video.
fetch(){
  local vid="$1"
  [ -f "$vid" ] || { log "target not found: $vid"; return 0; }
  log "video: $vid"
  # step 1: exact-match download (subliminal skips videos that already have a sub)
  "$PY" -m subliminal download $LANG_ARGS $PROVIDER_ARGS \
      --min-score "$MINSCORE" --encoding utf-8 "$vid" 2>&1 | sed "s/^/[subliminal] /" || true
  # step 2: alternatives dump for any language with no exact match
  fetch_alternatives "$vid"
  # step 3: transliterate Romanian diacritics in any .ro subtitles we just fetched
  strip_ro_diacritics "$vid"
}

# Resolve the scan target(s), highest precedence first:
#   1. a path given on the command line   2. config.yaml `paths`   3. this folder
targets=()
if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
  targets+=("$1")
elif [ -n "${CFG_PATHS:-}" ]; then
  while IFS= read -r line; do [ -n "$line" ] && targets+=("$line"); done <<< "$CFG_PATHS"
else
  targets+=("$SCRIPT_DIR")
fi

echo "==> find-subs (langs: $LANGS, alternatives: $ALTS -> $ALTSDIR/)"
echo "==> scanning: ${targets[*]}"

# Build the list of videos to process (recursively for each directory target).
videos=()
for TARGET in "${targets[@]}"; do
  if [ ! -e "$TARGET" ]; then
    log "WARNING: path not found, skipping: $TARGET"
    continue
  fi
  if [ -f "$TARGET" ]; then
    videos+=("$TARGET")
  else
    while IFS= read -r -d '' v; do videos+=("$v"); done \
      < <(find "$TARGET" -type f \( "${VIDEO_EXPR[@]}" \) -print0 2>/dev/null)
  fi
done

if [ "${#videos[@]}" -eq 0 ]; then
  echo "==> No video files found under: ${targets[*]}"
  exit 0
fi

echo "==> Found ${#videos[@]} video(s). Fetching subtitles..."
for v in "${videos[@]}"; do
  echo "----------------------------------------------------------------"
  fetch "$v"
done
echo "----------------------------------------------------------------"
echo "==> Done."
