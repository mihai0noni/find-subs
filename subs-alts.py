#!/usr/bin/env python3
"""Download ALL alternative subtitle candidates for a video into a subfolder.

Used as a fallback by get-subs.sh: after the normal `subliminal download` run,
any configured language that ended up with NO subtitle next to the video is
considered "no exact match" (e.g. no subtitle for the video's exact release).
For each such language we list every candidate subtitle from a small, fixed set
of providers (default: opensubtitles + regielive for Romanian) -- NOT every site
subliminal knows -- download them all, and save them into a subfolder (default
"Subs") next to the video, named:

    <video-stem>.<lang>.<NN>.<release>.<ext>

so the releases can be told apart (e.g. a "-playWEB" sub for a "-NTb" video).
Languages that already have a subtitle next to the video are skipped (their
exact match was found).

With --all-langs the selection is inverted: alternates are collected for EVERY
configured language (even ones that already have an exact match), so other-
release candidates are always gathered in parallel with the exact-match retry.
To stay idempotent, a language that already has alternates in the subfolder is
skipped, so this pass runs once per language rather than on every sweeper cycle.

Usage:
    subs-alts.py --langs "en ro" [--providers "opensubtitles regielive"] \
                 [--subfolder Subs] [--min-score 0] [--all-langs] VIDEO

Only the video file path is required; the script is a no-op (exit 0) on any
error so it can never break the calling hook.
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import sys

logging.basicConfig(level=logging.CRITICAL)

# subtitle extensions a media player understands
SUB_EXTS = ('.srt', '.ass', '.ssa', '.vtt', '.sub')


def _sanitize(text: str) -> str:
    """Make a string safe to embed in a filename."""
    text = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '', text or '')
    text = re.sub(r'\s+', ' ', text).strip().strip('.')
    return text[:80]


def _lang_present(video_dir: str, stem: str, alpha2: str) -> bool:
    """Return True if a subtitle for ``alpha2`` already sits next to the video."""
    prefix = (stem + '.' + alpha2).lower()
    try:
        for name in os.listdir(video_dir):
            low = name.lower()
            if not low.endswith(SUB_EXTS):
                continue
            # matches "<stem>.<lang>.ext" and "<stem>.<lang>.<anything>.ext"
            if low == prefix + os.path.splitext(low)[1] or low.startswith(prefix + '.'):
                return True
    except OSError:
        pass
    return False


def _alts_present(dest_dir: str, stem: str, alpha2: str) -> bool:
    """Return True if we already collected an alternate for ``alpha2`` in Subs/.

    Alternates are named "<stem>.<alpha2>.<NN>[.<release>].<ext>", so we look
    for any file whose name starts with "<stem>.<alpha2>." in the subfolder.
    Used as an idempotency guard: once a language has candidates, the parallel
    "collect for all languages" pass skips it so we do not re-download the same
    alternates on every sweeper cycle.
    """
    prefix = (stem + '.' + alpha2 + '.').lower()
    try:
        for name in os.listdir(dest_dir):
            low = name.lower()
            if low.endswith(SUB_EXTS) and low.startswith(prefix):
                return True
    except OSError:
        pass
    return False



def main(argv):
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument('--langs', default='')
    parser.add_argument('--providers', default='opensubtitles regielive')
    parser.add_argument('--subfolder', default='Subs')
    parser.add_argument('--min-score', type=int, default=0)
    # when set, collect alternates for EVERY configured language (not only the
    # ones missing an exact match next to the video). Languages that already
    # have alternates in the subfolder are still skipped, so this pass runs once
    # per language and does not re-download on every sweeper cycle.
    parser.add_argument('--all-langs', action='store_true')
    parser.add_argument('video')
    args = parser.parse_args(argv)

    video_path = args.video
    if not os.path.isfile(video_path):
        return 0

    try:
        from babelfish import Language
        from subliminal import Video, region, refine, provider_manager
        from subliminal.core import ProviderPool
    except Exception as exc:  # defensive
        print('[subs-alts] subliminal unavailable: %s' % exc)
        return 0

    # a cache backend is required by some providers/refiners
    try:
        if not region.is_configured:
            region.configure('dogpile.cache.memory')
    except Exception:
        pass

    # build the language set (skip anything babelfish cannot parse)
    languages = set()
    lang_by_alpha2 = {}
    for code in args.langs.split():
        code = code.strip()
        if not code:
            continue
        lang = None
        for conv in ('fromietf', 'fromalpha2'):
            try:
                lang = getattr(Language, conv)(code)
                break
            except Exception:
                continue
        if lang is None:
            continue
        languages.add(lang)
        lang_by_alpha2[code] = lang
    if not languages:
        return 0

    # the alternatives dump is restricted to this provider list (single source of
    # releases, no mixing across many sites). Register RegieLive if requested.
    requested = [p.strip() for p in args.providers.split() if p.strip()]
    if 'regielive' in requested:
        try:
            if 'regielive' not in provider_manager.names():
                provider_manager.register(
                    'regielive = subliminal_regielive.provider:RegieLiveProvider'
                )
        except Exception:
            pass
    # keep only providers subliminal actually knows about (skip typos / missing plugins)
    try:
        known = set(provider_manager.names())
    except Exception:
        known = set()
    providers = [p for p in requested if not known or p in known]
    if not providers:
        return 0

    # build the video + refine it for rich matching metadata
    try:
        video = Video.fromname(os.path.basename(video_path))
    except Exception:
        return 0
    try:
        refine(video)
    except Exception:
        pass

    video_dir = os.path.dirname(os.path.abspath(video_path))
    stem = os.path.splitext(os.path.basename(video_path))[0]
    dest_dir = os.path.join(video_dir, args.subfolder)

    # Decide which languages to collect alternates for:
    #  - default: only languages with NO exact match next to the video.
    #  - --all-langs: every configured language (so we always gather other-release
    #    candidates, e.g. Romanian alternates even when an exact .ro was found),
    #    but skip any language that already has alternates in the subfolder so we
    #    do not re-download the same files on every sweeper cycle.
    needed = set()
    for code, lang in lang_by_alpha2.items():
        if args.all_langs:
            if not _alts_present(dest_dir, stem, lang.alpha2):
                needed.add(lang)
        elif not _lang_present(video_dir, stem, lang.alpha2):
            needed.add(lang)
    if not needed:
        return 0

    pool = ProviderPool(providers=providers)
    try:
        all_subs = pool.list_subtitles(video, needed)
    except Exception as exc:
        print('[subs-alts] list failed: %s' % exc)
        _terminate(pool)
        return 0

    def _score(s):
        try:
            return len(s.get_matches(video))
        except Exception:
            return 0

    candidates = [s for s in all_subs if s.language in needed]
    candidates.sort(key=_score, reverse=True)
    if args.min_score:
        strong = [s for s in candidates if _score(s) >= args.min_score]
        candidates = strong or candidates
    if not candidates:
        _terminate(pool)
        return 0

    os.makedirs(dest_dir, exist_ok=True)

    counters = {}
    written = []
    for sub in candidates:
        try:
            if not pool.download_subtitle(sub):
                continue
        except Exception:
            continue
        if not sub.content:
            continue
        alpha2 = sub.language.alpha2
        counters[alpha2] = counters.get(alpha2, 0) + 1
        release = _sanitize(getattr(sub, 'release', '') or getattr(sub, 'provider_name', '') or '')
        ext = '.srt'
        try:
            fmt = sub.subtitle_format
            if fmt:
                ext = '.' + str(fmt).lstrip('.')
        except Exception:
            pass
        parts = [stem, alpha2, '%02d' % counters[alpha2]]
        if release:
            parts.append(release)
        fpath = os.path.join(dest_dir, '.'.join(parts) + ext)
        try:
            with open(fpath, 'wb') as fh:
                fh.write(sub.content)
            written.append(fpath)
            print('[subs-alts] %s' % fpath)
        except Exception:
            continue

    _terminate(pool)

    if not written:
        try:
            os.rmdir(dest_dir)
        except OSError:
            pass
    return 0


def _terminate(pool):
    try:
        pool.terminate()
    except Exception:
        pass


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
