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
    python install-deps.py --index-url URL  # use a custom package index (mirror)

Troubleshooting: if pip says  "Location '' is ignored"  and  "Could not find a
version that satisfies subliminal", pip is stuck in OFFLINE mode -- usually a
PIP_NO_INDEX / blank PIP_FIND_LINKS env var (or a pip.ini) on your machine.
Unset those, or install offline properly with  --wheels DIR.

You do NOT need to install pip yourself: this script bootstraps it automatically
(via ensurepip, falling back to get-pip.py) if the environment lacks it.

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


def pip_ok(py):
    """True if `py -m pip` is available."""
    return subprocess.call([py, "-m", "pip", "--version"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0


def ensure_pip(py):
    """Make sure `py -m pip` works; bootstrap it if missing. Returns True on success."""
    if pip_ok(py):
        print("==> pip is present.")
        return True

    print("==> pip not found -- bootstrapping it...")
    # 1) Preferred: the standard-library ensurepip module.
    if subprocess.call([py, "-m", "ensurepip", "--upgrade"]) == 0 and pip_ok(py):
        return True

    # 2) Fallback: download get-pip.py and run it (needs internet).
    print("==> ensurepip unavailable -- trying get-pip.py ...")
    try:
        import tempfile
        import urllib.request
        tmp = os.path.join(tempfile.gettempdir(), "get-pip.py")
        urllib.request.urlretrieve("https://bootstrap.pypa.io/get-pip.py", tmp)
        ok = subprocess.call([py, tmp]) == 0
        try:
            os.remove(tmp)
        except OSError:
            pass
        if ok and pip_ok(py):
            return True
    except Exception as exc:
        print("    get-pip.py failed: %s" % exc)

    # 3) Give up with clear, OS-specific guidance.
    print("ERROR: could not install pip automatically.")
    if sys.platform.startswith("linux"):
        print("       On Debian/Ubuntu:  sudo apt-get install -y python3-pip python3-venv")
        print("       On Fedora/RHEL:     sudo dnf install -y python3-pip")
    elif sys.platform == "darwin":
        print("       Try:  python3 -m ensurepip --upgrade   (or reinstall Python from python.org)")
    else:
        print("       Reinstall Python from https://python.org and tick 'pip' in the installer.")
    return False


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
        if i + 1 >= len(argv) or not str(argv[i + 1]).strip():
            print("ERROR: --wheels requires a non-empty directory argument.")
            return 2
        wheels = argv[i + 1].strip()
    index_url = None
    if "--index-url" in argv:
        j = argv.index("--index-url")
        if j + 1 >= len(argv) or not str(argv[j + 1]).strip():
            print("ERROR: --index-url requires a URL argument.")
            return 2
        index_url = argv[j + 1].strip()

    if not os.path.isfile(REQ):
        print("ERROR: requirements.txt not found next to this script.")
        return 1

    # Warn if the environment is forcing pip offline -- the classic cause of
    # "Location '' is ignored / could not find a version that satisfies ...".
    if not wheels:
        if os.environ.get("PIP_NO_INDEX"):
            print("==> WARNING: PIP_NO_INDEX is set in your environment -- pip will run "
                  "OFFLINE and\n    likely fail to find subliminal. Unset it, or use "
                  "--wheels DIR for an offline install.")
        if os.environ.get("PIP_FIND_LINKS", "x").strip() == "":
            print("==> WARNING: PIP_FIND_LINKS is set to an EMPTY value -- this makes pip "
                  "report\n    \"Location '' is ignored\" and fail. Unset it and retry.")

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

    # Make sure pip is available -- bootstrap it if the environment lacks it.
    if not ensure_pip(py):
        return 1
    # Best-effort: keep pip current (ignore failures, e.g. no network / permissions).
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
        # Online install. Pass an explicit index URL so a stray/blank PIP_* config
        # can't silently drop pip into a broken offline mode.
        cmd = [py, "-m", "pip", "install",
               "--index-url", index_url or "https://pypi.org/simple", "-r", REQ]
        if user:
            cmd.append("--user")


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
