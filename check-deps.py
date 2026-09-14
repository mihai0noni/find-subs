#!/usr/bin/env python3
"""check-deps.py - Preflight check for a new environment.

Verifies everything find-subs needs is present and reports exactly what to fix.
Run this first on any new machine:

    python check-deps.py
"""
from __future__ import annotations

import importlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OK = "[ OK ]"
NO = "[FAIL]"


def check(label, ok, hint=""):
    print(("%s %s" % (OK if ok else NO, label)))
    if not ok and hint:
        print("        -> " + hint)
    return ok


def main():
    print("find-subs environment check")
    print("=" * 48)
    all_ok = True

    # 1. Python 3.9+ (subliminal 2.x needs a modern Python)
    v = sys.version_info
    all_ok &= check(
        "Python %d.%d.%d" % (v.major, v.minor, v.micro),
        v.major == 3 and v.minor >= 9,
        "Install Python 3.9 or newer.",
    )

    # 2. Required packages (subliminal + guessit; the rest are transitive)
    for mod, pipname in (("subliminal", "subliminal"), ("guessit", "guessit"),
                          ("babelfish", "babelfish"), ("bs4", "beautifulsoup4"),
                          ("requests", "requests")):
        try:
            m = importlib.import_module(mod)
            ver = getattr(m, "__version__", "")
            all_ok &= check("import %s %s" % (mod, ver), True)
        except Exception:
            all_ok &= check("import %s" % mod, False,
                            "pip install -r requirements.txt   (or: pip install %s)" % pipname)

    # 3. Bundled files present
    for fname in ("subs-alts.py", os.path.join("subliminal_regielive", "provider.py")):
        all_ok &= check("file %s" % fname, os.path.isfile(os.path.join(HERE, fname)),
                        "Re-copy the find-subs folder; a file is missing.")

    # 3b. config.yaml present and parseable (optional but recommended)
    cfg_path = os.path.join(HERE, "config.yaml")
    if os.path.isfile(cfg_path):
        try:
            import yaml
            with open(cfg_path, encoding="utf-8") as fh:
                cfg = yaml.safe_load(fh) or {}
            paths = cfg.get("paths")
            if isinstance(paths, str):
                paths = [paths]
            paths = [p for p in (paths or []) if str(p).strip()]
            check("config.yaml parsed (%d path(s))" % len(paths), True)
            for p in paths:
                check("  path exists: %s" % p, os.path.isdir(p),
                      "Edit config.yaml `paths` to point at real movie folders.")
        except Exception as exc:
            check("config.yaml parseable", False,
                  "Fix YAML syntax, or `pip install PyYAML`. %s" % exc)
    else:
        check("config.yaml present", True,
              "(optional) create config.yaml to set movie paths; defaults/env still work.")

    # 4. RegieLive provider importable (bundled dir on PYTHONPATH)
    sys.path.insert(0, HERE)
    try:
        importlib.import_module("subliminal_regielive.provider")
        all_ok &= check("RegieLive provider importable", True)
    except Exception as exc:
        all_ok &= check("RegieLive provider importable", False,
                        "Needs babelfish/requests/bs4 (installed with subliminal). %s" % exc)

    print("=" * 48)
    if all_ok:
        print("All good. Run:  python find-subs.py  (or ./find-subs.sh)")
        return 0
    print("Some checks failed -- see the -> hints above.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
