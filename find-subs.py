#!/usr/bin/env python3
"""find-subs.py - Pure-Python, cross-platform subtitle finder.

Same subtitle-finding logic as d3l0g3 / find-subs.sh, but with NO dependency on
bash/find/sed -- so it runs on any OS that has Python 3 (plain Windows without
Git Bash, locked-down Linux, macOS, containers, ...). It traverses one or more
movie folders RECURSIVELY and, per video, runs:

  1. python -m subliminal download  (exact match, all providers + regielive/ro)
  2. subs-alts.py                    (two-tier alternatives dump into "Subs")
  3. Romanian diacritics strip       (transliterate *.ro.* subs to plain Latin)

Where the movie folder(s) come from -- highest precedence first:
  1. a PATH given on the command line     (python find-subs.py "D:/Movies")
  2. environment variables                (LANGS, ALTS, ... ; no path here)
  3. config.yaml next to this script       (paths: [...] plus all the knobs)
  4. built-in defaults                     (this script's own folder)

Usage:
    python find-subs.py               # use config.yaml's `paths`
    python find-subs.py PATH          # scan PATH (folder or single video file)
    python find-subs.py -c other.yaml # use a specific config file
"""
from __future__ import annotations

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG = os.path.join(HERE, "config.yaml")


def _load_config(path):
    """Load config.yaml -> dict. Tolerant: missing file/PyYAML -> {} (fail-open)."""
    if not path or not os.path.isfile(path):
        return {}
    try:
        import yaml  # PyYAML (ships transitively with subliminal via knowit)
        with open(path, "r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
        return data if isinstance(data, dict) else {}
    except Exception as exc:
        print("[find-subs] WARNING: could not read %s (%s); using defaults/env." % (path, exc))
        return {}


# Resolve the config file early (so -c can point elsewhere) without a full parser.
_CFG_PATH = DEFAULT_CONFIG
_ARGV = sys.argv[1:]
if _ARGV and _ARGV[0] in ("-c", "--config") and len(_ARGV) >= 2:
    _CFG_PATH = _ARGV[1]
    _ARGV = _ARGV[2:]
CFG = _load_config(_CFG_PATH)


def _opt(env_key, cfg_key, default):
    """Precedence: environment variable > config.yaml > built-in default."""
    if env_key in os.environ:
        return os.environ[env_key]
    if cfg_key in CFG and CFG[cfg_key] is not None:
        return CFG[cfg_key]
    return default


def _as_bool(v):
    if isinstance(v, bool):
        return v
    return str(v).strip().lower() in ("1", "true", "yes", "on")


# --- Configuration (same knobs / defaults as find-subs.sh / d3l0g3) ----------
LANGS = str(_opt("LANGS", "langs", "en ro")).split()
REGIELIVE = _as_bool(_opt("REGIELIVE", "regielive", True))
ALTS = _as_bool(_opt("ALTS", "alternatives", True))
ALTSDIR = str(_opt("ALTSDIR", "alternativesSubfolder", "Subs"))
ALTPROVIDERS = str(_opt("ALTPROVIDERS", "alternativesProviders", "opensubtitles regielive"))
ALTPROVIDERS2 = str(_opt("ALTPROVIDERS2", "alternativesProvidersFallback",
                         "opensubtitles regielive podnapisi tvsubtitles gestdown addic7ed"))
STRIPRO = _as_bool(_opt("STRIPRO", "stripRomanianDiacritics", True))
MINSCORE = str(_opt("MINSCORE", "minScore", "60"))
ALTSCRIPT = os.environ.get("ALTSCRIPT", os.path.join(HERE, "subs-alts.py"))

# Movie folder(s) from config.yaml `paths` (a string or a list). Used only when
# no PATH is passed on the command line.
_cfg_paths = CFG.get("paths")
if isinstance(_cfg_paths, str):
    CONFIG_PATHS = [_cfg_paths]
elif isinstance(_cfg_paths, (list, tuple)):
    CONFIG_PATHS = [str(p) for p in _cfg_paths if str(p).strip()]
else:
    CONFIG_PATHS = []

VIDEO_EXTS = (".mkv", ".mp4", ".avi", ".m4v", ".mov", ".wmv")
SUB_EXTS = (".srt", ".ass", ".ssa", ".vtt", ".sub")
PY = sys.executable  # the very interpreter running this script

# Romanian diacritics -> plain Latin (same table as d3l0g3's strip_ro_diacritics).
RO_MAP = {
    0x103: "a", 0xE2: "a", 0xEE: "i", 0x219: "s", 0x15F: "s", 0x21B: "t", 0x163: "t",
    0x102: "A", 0xC2: "A", 0xCE: "I", 0x218: "S", 0x15E: "S", 0x21A: "T", 0x162: "T",
}



def log(msg: str) -> None:
    print("[find-subs] " + msg)


def _run(cmd, prefix):
    """Run a subprocess, echo each output line with a prefix, never raise."""
    env = dict(os.environ)
    env["PYTHONPATH"] = HERE + os.pathsep + env.get("PYTHONPATH", "")
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
        out = (proc.stdout or "") + (proc.stderr or "")
        for line in out.splitlines():
            print(prefix + line)
    except Exception as exc:  # fail-open, like the shell version
        print(prefix + "error: %s" % exc)


def _alts_count(video: str) -> int:
    d = os.path.dirname(video)
    stem = os.path.splitext(os.path.basename(video))[0].lower()
    sub_dir = os.path.join(d, ALTSDIR)
    try:
        return sum(1 for n in os.listdir(sub_dir) if n.lower().startswith(stem + "."))
    except OSError:
        return 0


def _is_ro_sub(name: str) -> bool:
    """True for "<stem>.ro.<subext>" and "<stem>.ro.NN.<...>" alternate files."""
    low = name.lower()
    if ".ro." not in low:
        return False
    if any(low.endswith(e) for e in SUB_EXTS):
        return True
    tail = low.split(".ro.", 1)[1]
    return len(tail) >= 2 and tail[:2].isdigit()


def strip_ro_diacritics(video: str) -> None:
    if not STRIPRO:
        return
    d = os.path.dirname(video)
    files = []
    for base in (d, os.path.join(d, ALTSDIR)):
        try:
            for name in os.listdir(base):
                if _is_ro_sub(name):
                    files.append(os.path.join(base, name))
        except OSError:
            continue
    for path in files:
        try:
            data = open(path, "rb").read()
        except OSError:
            continue
        text = None
        for enc in ("utf-8-sig", "utf-8", "cp1250", "iso-8859-2", "latin-1"):
            try:
                text = data.decode(enc)
                break
            except Exception:
                pass
        if text is None:
            continue
        new = text.translate(RO_MAP)
        if new != text:
            try:
                open(path, "w", encoding="utf-8").write(new)
                print("[strip-ro] " + path)
            except OSError:
                pass


def fetch_alternatives(video: str) -> None:
    if not ALTS or not os.path.isfile(ALTSCRIPT) or not os.path.isfile(video):
        return
    langs = " ".join(LANGS)
    # tier 1: curated providers, collect for ALL configured languages
    _run([PY, ALTSCRIPT, "--langs", langs, "--providers", ALTPROVIDERS,
          "--subfolder", ALTSDIR, "--all-langs", video], "[subs-alts] ")
    # tier 2: only if tier 1 found nothing and a different wider set is configured
    if _alts_count(video) == 0 and ALTPROVIDERS2.strip() and ALTPROVIDERS2 != ALTPROVIDERS:
        log("no alternatives from primary providers; widening search")
        _run([PY, ALTSCRIPT, "--langs", langs, "--providers", ALTPROVIDERS2,
              "--subfolder", ALTSDIR, "--all-langs", video], "[subs-alts] ")


def fetch(video: str) -> None:
    if not os.path.isfile(video):
        log("target not found: " + video)
        return
    log("video: " + video)
    # step 1: exact-match download (subliminal skips videos that already have a sub)
    cmd = [PY, "-m", "subliminal", "download"]
    for l in LANGS:
        cmd += ["-l", l]
    if REGIELIVE and "ro" in LANGS:
        cmd += ["--extend-provider", "regielive"]
    cmd += ["--min-score", MINSCORE, "--encoding", "utf-8", video]
    _run(cmd, "[subliminal] ")
    # step 2 + 3
    fetch_alternatives(video)
    strip_ro_diacritics(video)


def _collect_videos(target):
    """Return the list of video files under a target (file or dir, recursive)."""
    vids = []
    if os.path.isfile(target):
        vids.append(target)
    elif os.path.isdir(target):
        for root, _dirs, names in os.walk(target):
            for n in names:
                if n.lower().endswith(VIDEO_EXTS):
                    vids.append(os.path.join(root, n))
    return vids


def main(argv):
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    # Targets: a CLI path wins; otherwise use config.yaml `paths`; else this folder.
    if argv:
        targets = [argv[0]]
    elif CONFIG_PATHS:
        targets = CONFIG_PATHS
    else:
        targets = [HERE]

    print("==> find-subs (langs: %s, alternatives: %s -> %s/)"
          % (" ".join(LANGS), str(ALTS).lower(), ALTSDIR))
    print("==> scanning: %s" % ", ".join(targets))

    videos = []
    missing = []
    for t in targets:
        if not os.path.exists(t):
            missing.append(t)
            continue
        videos.extend(_collect_videos(t))
    for m in missing:
        print("[find-subs] WARNING: path not found, skipping: " + m)

    # de-duplicate while preserving order (in case paths overlap)
    seen = set()
    videos = [v for v in videos if not (v in seen or seen.add(v))]

    if not videos:
        if missing and len(missing) == len(targets):
            print("ERROR: none of the configured paths exist.")
            return 1
        print("==> No video files found under: %s" % ", ".join(targets))
        return 0

    print("==> Found %d video(s). Fetching subtitles..." % len(videos))
    for v in sorted(videos):
        print("----------------------------------------------------------------")
        fetch(v)
    print("----------------------------------------------------------------")
    print("==> Done.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(_ARGV))
    except KeyboardInterrupt:
        sys.exit(130)
