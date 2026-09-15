# find-subs

Standalone, deployable subtitle finder that reuses the **exact same**
subtitle-finding logic as the **d3l0g3** component, but runs anywhere you drop
it (no Kubernetes / Deluge required) and scans the folder it lives in
**recursively**, so movies in sub-folders are handled too.

## What it does (identical to d3l0g3's `/config/get-subs.sh`)

For every video found under the deploy folder (or a path you pass):

1. **Exact match** — `subliminal download -l en -l ro [--extend-provider regielive]
   --min-score 60 --encoding utf-8 <video>`
   → saves `Movie.en.srt` / `Movie.ro.srt` next to the video.
2. **Alternatives** (`subs-alts.py`, two-tier, unchanged from d3l0g3) — for every
   configured language, dumps all candidate releases into a `Subs/` subfolder
   next to the video:
   - **Tier 1:** `opensubtitles regielive`
   - **Tier 2** (only if tier 1 found nothing): `opensubtitles regielive podnapisi
     tvsubtitles gestdown addic7ed`
3. **Romanian diacritics strip** — transliterates diacritics in `*.ro.*` subtitle
   files to plain Latin and re-encodes UTF-8.

The `subs-alts.py` and the RegieLive provider (`subliminal_regielive/provider.py`)
are byte-for-byte copies of the d3l0g3 originals.

> Unlike d3l0g3 this tool only **finds** subtitles. It does **not** organize
> (move/rename) videos into title folders — that step is intentionally left out.

## Point it at your movies (`config.yaml`)

Edit **`config.yaml`** and set `paths` to the folder(s) that hold your movies —
each one is traversed **recursively**:

```yaml
paths:
  - "D:/Movies"
  - "D:/TV Shows"      # add as many as you like
langs: "en ro"
```

Then just run it with no arguments (`python find-subs.py` or `./find-subs.sh`)
and it downloads subtitles for every video under those folders.

All the tuning knobs live in `config.yaml` too (languages, providers, etc. — see
the [Configuration](#configuration) table). Precedence, highest wins:

**command-line PATH  >  environment variable  >  `config.yaml`  >  built-in default.**

So `python find-subs.py "D:/OneOff"` (or `./find-subs.sh "D:/OneOff"`) still
overrides `config.yaml` for that single run.

## Requirements (one-time)

Run the bundled installer — it resolves a working Python 3, upgrades pip, and
installs everything from `requirements.txt` (the same set d3l0g3 installs:
`subliminal` + `guessit`; `babelfish` / `requests` / `beautifulsoup4` / `PyYAML`
come in transitively):

```bash
./install-deps.sh            # Linux / macOS / Git Bash
```
```bat
install-deps.bat             :: Windows (no bash needed)
```
```
python install-deps.py       # any OS with Python 3
```

The installer even **bootstraps pip itself** if the target machine doesn't have
it (via `ensurepip`, falling back to `get-pip.py`) — so you don't have to install
pip separately.

Handy flags (all three installers accept them):

| Flag           | Effect |
|----------------|--------|
| `--user`       | Install into your user site (no admin/root needed) |
| `--venv`       | Create a local `.venv/` and install into it (isolated) |
| `--wheels DIR` | **Offline** install from a folder of pre-downloaded wheels |
| `--index-url URL` | Use a custom package index / mirror |

Prefer doing it by hand instead? That's just:

```
pip install -r requirements.txt      # or: pip install subliminal guessit
```

Then confirm the environment is ready:

```
python check-deps.py
```

**Install error `Location '' is ignored` / `Could not find a version that
satisfies subliminal`?** That means pip is stuck in **offline mode** — almost
always because your machine has one of these set (common on corporate/locked-down
boxes):

- `PIP_NO_INDEX=1` (or `--no-index` in a `pip.ini`), or
- a **blank** `PIP_FIND_LINKS`.

Fix it by clearing them, then re-run the installer:

```bash
unset PIP_NO_INDEX PIP_FIND_LINKS      # Linux/macOS/Git Bash
./install-deps.sh
```
```bat
set "PIP_NO_INDEX="                    :: Windows cmd
set "PIP_FIND_LINKS="
install-deps.bat
```

If you *intend* to install offline, do it properly with a wheels folder instead:
`install-deps.sh --wheels wheels` (see [Deploying](#deploying-to-another-environment)).
Behind a corporate mirror, point pip at it with `--index-url https://your-mirror/simple`.


- **Windows:** to use `find-subs.bat`/`find-subs.sh`, a `bash` (Git Bash or WSL)
  must be on `PATH`. If you don't have bash, use `python find-subs.py` instead —
  it needs nothing but Python.

## Usage

Linux / macOS / Git Bash:

```bash
./find-subs.sh                 # scan the folders in config.yaml (recursive)
./find-subs.sh /path/to/movies # override: scan a given folder instead
./find-subs.sh movie.mkv       # override: a single video file
```

Windows (cmd / double-click):

```bat
find-subs.bat                  :: scan the folders in config.yaml
find-subs.bat "D:\Movies"      :: override with a folder
find-subs.bat "D:\Movies\a.mkv"
```

No bash available? Use the pure-Python version (identical logic, works on any OS
that has Python 3 — plain Windows, locked-down Linux, containers):

```
python find-subs.py                # scan the folders in config.yaml (recursive)
python find-subs.py /path/to/movies
python find-subs.py movie.mkv
python find-subs.py -c other.yaml  # use a specific config file
```

## Deploying to another environment

The whole tool is the `find-subs/` folder — copy it anywhere. Beyond the files
themselves, a target machine needs:

| Prerequisite | Why | Notes |
|--------------|-----|-------|
| **Python 3.9+** | runs everything | `python`/`python3` on `PATH`. subliminal 2.x needs a modern Python. |
| **pip packages** `subliminal` + `guessit` | the actual subtitle engine | `pip install -r requirements.txt`. `babelfish`/`requests`/`beautifulsoup4`/`dogpile.cache` come in transitively. |
| **Network / outbound HTTPS** | providers are online (opensubtitles, regielive, …) | Must reach the subtitle sites; behind a proxy set `HTTPS_PROXY`. |
| **bash + coreutils** (`find`, `sed`) | only for `find-subs.sh` / `find-subs.bat` | Preinstalled on Linux/macOS. On Windows install **Git for Windows** or **WSL** — OR skip bash entirely and run **`find-subs.py`**. |

Recommended first step on any new box — run the self-check, which reports exactly
what (if anything) is missing:

```
python check-deps.py
```

A virtual environment keeps it isolated (optional but recommended) — the
installer can create one for you:

```bash
./install-deps.sh --venv             # creates .venv and installs into it
source .venv/bin/activate            # Linux/macOS/Git Bash
# .venv\Scripts\activate.bat         # Windows cmd
```

**No internet on the target?** On a machine that *does* have internet, download
wheels once (`pip download -r requirements.txt -d wheels/`), copy the `wheels/`
folder along with `find-subs/`, then install offline in one step:

```
./install-deps.sh --wheels wheels    # (or: install-deps.bat --wheels wheels)
```

(equivalent to `pip install --no-index --find-links wheels -r requirements.txt`.)

Nothing else is required: no Kubernetes, no Deluge, no d3l0g3 — this tool is
fully self-contained (it bundles its own copy of `subs-alts.py` and the RegieLive
provider).

## Configuration

Every option can be set in **`config.yaml`** (recommended) or overridden per-run
with an environment variable. Defaults match d3l0g3:

| `config.yaml` key               | Env var         | Default                                                              | Meaning |
|---------------------------------|-----------------|----------------------------------------------------------------------|---------|
| `paths`                         | *(CLI arg)*     | this script's folder                                                 | Movie folder(s) to scan recursively (a list) |
| `langs`                         | `LANGS`         | `en ro`                                                              | ISO 639-1 language codes to fetch |
| `regielive`                     | `REGIELIVE`     | `true`                                                              | Add the RegieLive Romanian provider (only when `ro` is set) |
| `alternatives`                  | `ALTS`          | `true`                                                              | Dump alternatives into a subfolder |
| `alternativesSubfolder`         | `ALTSDIR`       | `Subs`                                                             | Name of the alternatives subfolder |
| `alternativesProviders`         | `ALTPROVIDERS`  | `opensubtitles regielive`                                          | Tier-1 alternatives providers |
| `alternativesProvidersFallback` | `ALTPROVIDERS2` | `opensubtitles regielive podnapisi tvsubtitles gestdown addic7ed`  | Tier-2 fallback providers |
| `stripRomanianDiacritics`       | `STRIPRO`       | `true`                                                              | Strip Romanian diacritics in `*.ro.*` subs |
| `minScore`                      | `MINSCORE`      | `60`                                                               | subliminal exact-match minimum score |

Example (env override for a one-off run):

```bash
LANGS="en" ALTS=false ./find-subs.sh /media/movies
```


## Notes

- **Safe / idempotent:** subliminal skips videos that already have a subtitle;
  the alternatives pass skips languages that already have candidates. Existing
  files are never deleted — subtitles are only ever added.
- Scanned video extensions: `.mkv .mp4 .avi .m4v .mov .wmv` (same as d3l0g3).

## Files

```
find-subs/
├── config.yaml                    # movie paths + all options (edit this)
├── find-subs.sh                    # main script (bash; recursive finder)
├── find-subs.bat                   # Windows wrapper -> find-subs.sh
├── find-subs.py                    # pure-Python finder (no bash needed)
├── check-deps.py                   # environment preflight / self-check
├── install-deps.sh                 # dependency installer (bash)
├── install-deps.bat                # dependency installer (Windows, no bash)
├── install-deps.py                 # dependency installer (pure-Python)
├── requirements.txt                # Python deps (subliminal + guessit)
├── subs-alts.py                    # alternatives finder (copy of d3l0g3)
├── subliminal_regielive/
│   ├── __init__.py
│   └── provider.py                 # RegieLive provider (copy of d3l0g3)
└── README.md
```
