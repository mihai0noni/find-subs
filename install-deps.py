#!/usr/bin/env python3
"""install-deps.py - Install the Python dependencies find-subs needs.

Pure-Python, cross-platform installer (no bash / no batch required). Installs
the SAME packages d3l0g3 installs (subliminal + guessit) from requirements.txt;
everything else (babelfish/requests/beautifulsoup4/PyYAML/...) comes in
transitively.

Usage:
    python install-deps.py              # pip install -r requirements.txt
    python install-deps.py --user       # install into the user site (no admin)
    python install-deps.py --venv       # create ./.venv and install into it
    python install-deps.py --wheels DIR # OFFLINE install from a wheels/ folder

Verify afterwards with:  python check-deps.py
"""
from __future__ import annotations

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REQ = os.path.join(HERE, "requirements.txt")


def run(cmd):
    print("    $ " + " ".join(cmd))
    return subprocess.call(cmd)


def venv_python(venv_dir):
    win = os.path.join(venv_dir, "Scripts", "python.exe")
    posix = os.path.join(venv_dir, "bin", "python")
    return win if os.path.isfile(win) else posix


def main(argv):
    if any(a in ("-h", "--help") for a in argv):
        print(__doc__)
        return 0

    user = "--user" in argv
    make_venv = "--venv" in argv
    wheels = None
    if "--wheels" in argv:
        i = argv.index("--wheels")
        if i + 1 >= len(argv):
            print("ERROR: --wheels requires a directory argument.")
            return 2
        wheels = argv[i + 1]

    if not os.path.isfile(REQ):
        print("ERROR: requirements.txt not found next to this script.")
        return 1

    py = sys.executable
    print("==> Using: %s (%d.%d.%d)" % ((py,) + sys.version_info[:3]))

    # Optionally create and target a local virtual environment.
    if make_venv:
        venv_dir = os.path.join(HERE, ".venv")
        print("==> Creating virtual environment: " + venv_dir)
        if run([py, "-m", "venv", venv_dir]) != 0:
            print("ERROR: failed to create venv.")
            return 1
        py = venv_python(venv_dir)
        user = False  # --user is invalid inside a venv

    # Ensure pip exists / is current (best-effort).
    subprocess.call([py, "-m", "ensurepip", "--upgrade"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.call([py, "-m", "pip", "install", "--upgrade", "pip"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    print("==> Installing dependencies from requirements.txt ...")
    if wheels:
        if not os.path.isdir(wheels):
            print("ERROR: wheels dir not found: " + wheels)
            return 1
        print("    (offline: --no-index --find-links %s)" % wheels)
        cmd = [py, "-m", "pip", "install", "--no-index", "--find-links", wheels, "-r", REQ]
    else:
        cmd = [py, "-m", "pip", "install", "-r", REQ]
        if user:
            cmd.insert(4, "--user")

    if run(cmd) != 0:
        print("ERROR: install failed.")
        return 1

    print("==> Done.")
    print('==> Verify with:  "%s" "%s"' % (py, os.path.join(HERE, "check-deps.py")))
    if make_venv:
        print("==> Activate the venv first (e.g. source .venv/bin/activate "
              "or .venv\\Scripts\\activate.bat).")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
