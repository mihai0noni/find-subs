#!/usr/bin/env python3
"""diag.py - Collect diagnostics for install/subtitle problems.

Run this in the SAME terminal where the error happens, then copy ALL the output:

    python diag.py

It prints: which Python/pip you're using, any PIP_* environment variables or
pip.ini files that could force pip offline, pip's effective config, and whether
find-subs' packages import. Nothing is installed or changed -- read-only.
"""
from __future__ import annotations

import os
import subprocess
import sys


def hdr(t):
    print("\n=== %s ===" % t)


def sh(cmd):
    print("$ " + " ".join(cmd))
    try:
        p = subprocess.run(cmd, capture_output=True, text=True)
        out = (p.stdout or "") + (p.stderr or "")
        print(out.strip() or "(no output)")
    except Exception as exc:
        print("(failed to run: %s)" % exc)


def main():
    print("find-subs diagnostics")

    hdr("Python")
    print("executable : " + sys.executable)
    print("version    : %s" % sys.version.replace("\n", " "))
    print("platform   : " + sys.platform)

    hdr("pip")
    sh([sys.executable, "-m", "pip", "--version"])

    hdr("PIP_* environment variables (these can FORCE pip offline)")
    pip_env = {k: v for k, v in os.environ.items() if k.upper().startswith("PIP_")}
    if pip_env:
        for k, v in sorted(pip_env.items()):
            print("%s = %r" % (k, v))
        if "PIP_NO_INDEX" in pip_env:
            print(">>> PIP_NO_INDEX is set: this forces OFFLINE mode. Unset it.")
        if pip_env.get("PIP_FIND_LINKS", "x").strip() == "":
            print(">>> PIP_FIND_LINKS is EMPTY: causes \"Location '' is ignored\". Unset it.")
    else:
        print("(none set)  <-- good")

    hdr("pip effective config (index-url / no-index / find-links)")
    sh([sys.executable, "-m", "pip", "config", "list"])
    sh([sys.executable, "-m", "pip", "config", "debug"])

    hdr("Can we reach PyPI? (dry-run, installs nothing)")
    sh([sys.executable, "-m", "pip", "install", "--dry-run",
        "--index-url", "https://pypi.org/simple", "subliminal"])

    hdr("Do find-subs packages import?")
    for mod in ("subliminal", "guessit", "babelfish", "bs4", "requests", "yaml"):
        try:
            m = __import__(mod)
            print("[ OK ] %s %s" % (mod, getattr(m, "__version__", "")))
        except Exception as exc:
            print("[FAIL] %s -> %s" % (mod, exc))

    print("\n>>> Copy everything above when reporting the problem.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
