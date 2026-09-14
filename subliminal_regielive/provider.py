"""Subliminal provider for subtitrari.regielive.ro (Romanian subtitles).

Registered via the ``subliminal.providers`` entry point as ``regielive``.
Offers only Romanian (``ron``) subtitles. Scrapes the public HTML site:

* search:  ``/cauta.html?s=<query>``          -> media pages ``/<slug>-<id>/``
* series:  ``/<slug>-<id>/sezonul-<N>/``       -> per-episode subtitle rows
* movie:   ``/<slug>-<id>/``                    -> subtitle rows
* download ``/descarca-<mediaId>-<subId>.zip``  -> ZIP containing the .srt
"""

from __future__ import annotations

import io
import logging
import re
import zipfile
from typing import ClassVar

from babelfish import Language  # type: ignore[import-untyped]
from requests import Session

from subliminal.exceptions import NotInitializedProviderError
from subliminal.matches import guess_matches
from subliminal.subtitle import Subtitle, fix_line_ending
from subliminal.utils import safely_guessit, sanitize
from subliminal.video import Episode, Movie, Video

from subliminal.providers import ParserBeautifulSoup, Provider

logger = logging.getLogger(__name__)

#: base site url
SERVER_URL = 'https://subtitrari.regielive.ro'

#: matches a media page link, absolute or relative, e.g.
#: https://subtitrari.regielive.ro/reacher-40817/  or  /reacher-40817/
media_link_re = re.compile(
    r'^(?:https?://[^/]+)?/(?P<slug>[a-z0-9-]+)-(?P<id>\d+)/$'
)
#: matches a download link, e.g. /descarca-40817-515630.zip
download_re = re.compile(r'/descarca-(?P<media>\d+)-(?P<sub>\d+)\.zip')


class RegieLiveSubtitle(Subtitle):
    """RegieLive subtitle."""

    provider_name: ClassVar[str] = 'regielive'

    def __init__(
        self,
        language: Language,
        subtitle_id: str,
        *,
        page_link: str | None = None,
        download_link: str | None = None,
        release: str | None = None,
        title: str | None = None,
        year: int | None = None,
        season: int | None = None,
        episode: int | None = None,
    ) -> None:
        super().__init__(language, subtitle_id, page_link=page_link)
        self.download_link = download_link
        self.release = release
        self.title = title
        self.year = year
        self.season = season
        self.episode = episode

    @property
    def info(self) -> str:
        """Information about the subtitle."""
        return self.release or self.subtitle_id

    def get_matches(self, video: Video) -> set[str]:
        """Get the matches against the ``video`` using the release name."""
        matches: set[str] = set()
        if self.release:
            if isinstance(video, Episode):
                matches |= guess_matches(video, {'title': self.title, 'season': self.season, 'episode': self.episode})
                matches |= guess_matches(video, safely_guessit(self.release, {'type': 'episode'}), partial=True)
            elif isinstance(video, Movie):
                matches |= guess_matches(video, {'title': self.title, 'year': self.year})
                matches |= guess_matches(video, safely_guessit(self.release, {'type': 'movie'}), partial=True)
        return matches



class RegieLiveProvider(Provider):
    """RegieLive provider."""

    languages: ClassVar = {Language('ron')}
    video_types: ClassVar = (Episode, Movie)
    server_url: ClassVar[str] = SERVER_URL
    subtitle_class: ClassVar = RegieLiveSubtitle

    def __init__(self) -> None:
        self.session: Session | None = None

    def initialize(self) -> None:
        """Initialize the provider (open a browser-like session)."""
        self.session = Session()
        self.session.headers['User-Agent'] = (
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0 Safari/537.36'
        )
        self.session.headers['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        self.session.headers['Accept-Language'] = 'ro,en;q=0.9'
        self.session.headers['Referer'] = self.server_url + '/'

    def terminate(self) -> None:
        """Terminate the provider."""
        if not self.session:
            raise NotInitializedProviderError
        self.session.close()
        self.session = None

    def _get(self, url: str) -> ParserBeautifulSoup | None:
        if not self.session:
            raise NotInitializedProviderError
        r = self.session.get(url, timeout=20)
        if r.status_code != 200:
            logger.debug('regielive: %s -> HTTP %d', url, r.status_code)
            return None
        return ParserBeautifulSoup(r.content, ['html.parser'])

    def _find_media_url(self, title: str, year: int | None) -> str | None:
        """Search the site and return the best-matching media page url."""
        soup = self._get(self.server_url + '/cauta.html?s=' + title.replace(' ', '+'))
        if soup is None:
            return None
        wanted = sanitize(title)
        candidates = []
        for a in soup.find_all('a', href=media_link_re):
            m = media_link_re.match(a['href'])
            href = a['href']
            if not href.startswith('http'):
                href = self.server_url + href
            slug_words = sanitize(m.group('slug').replace('-', ' '))
            candidates.append((href, slug_words))
        # 1) exact slug == title
        for href, slug_words in candidates:
            if slug_words == wanted:
                return href
        # 2) slug that contains all wanted words (year suffix, punctuation, etc.)
        for href, slug_words in candidates:
            if wanted and all(w in slug_words.split() for w in wanted.split()):
                return href
        return None

    def _parse_rows(self, soup: ParserBeautifulSoup) -> list[tuple[int, str, str]]:
        """Return list of (episode_or_-1, release_name, download_url) from a page.

        Rows are attributed to the episode number parsed from the nearest
        preceding ``Episodul N`` header (``-1`` for movies / unscoped rows).
        """
        results: list[tuple[int, str, str]] = []
        current_ep = -1
        for el in soup.find_all(['h3', 'li']):
            if el.name == 'h3':
                m = re.search(r'Episod(?:ul)?\s*(\d+)', el.get_text(), re.I)
                if m:
                    current_ep = int(m.group(1))
                continue
            span = el.find('span', id=re.compile(r'^sub_\d+'))
            a = el.find('a', href=download_re)
            if not span or not a:
                continue
            release = span.get_text().strip()
            dl = a['href']
            if not dl.startswith('http'):
                dl = self.server_url + dl
            results.append((current_ep, release, dl))
        return results

    def query(self, video: Video, title: str, year: int | None) -> list[RegieLiveSubtitle]:
        """Query subtitles for a video given a resolved title."""
        media_url = self._find_media_url(title, year)
        if not media_url:
            logger.info('regielive: no media page for %r', title)
            return []

        subtitles: list[RegieLiveSubtitle] = []
        if isinstance(video, Episode):
            season_url = media_url + 'sezonul-' + str(video.season) + '/'
            soup = self._get(season_url)
            if soup is None:
                return []
            for ep, release, dl in self._parse_rows(soup):
                if video.episode is not None and ep not in (video.episode, -1):
                    continue
                sub_id = download_re.search(dl).group('sub')
                subtitles.append(
                    self.subtitle_class(
                        Language('ron'),
                        sub_id,
                        page_link=season_url,
                        download_link=dl,
                        release=release,
                        title=title,
                        year=year,
                        season=video.season,
                        episode=video.episode,
                    )
                )
        else:  # Movie
            soup = self._get(media_url)
            if soup is None:
                return []
            for _ep, release, dl in self._parse_rows(soup):
                sub_id = download_re.search(dl).group('sub')
                subtitles.append(
                    self.subtitle_class(
                        Language('ron'),
                        sub_id,
                        page_link=media_url,
                        download_link=dl,
                        release=release,
                        title=title,
                        year=year,
                    )
                )
        return subtitles

    def list_subtitles(self, video: Video, languages) -> list[RegieLiveSubtitle]:
        """List subtitles for the video (only Romanian is offered)."""
        if Language('ron') not in languages:
            return []
        if isinstance(video, Episode):
            titles = [video.series, *getattr(video, 'alternative_series', [])]
        elif isinstance(video, Movie):
            titles = [video.title, *getattr(video, 'alternative_titles', [])]
        else:
            return []
        for title in titles:
            if not title:
                continue
            subs = self.query(video, title, video.year)
            if subs:
                return subs
        return []

    def download_subtitle(self, subtitle: RegieLiveSubtitle) -> None:
        """Download the subtitle: fetch the ZIP and extract the first subtitle file."""
        if not self.session:
            raise NotInitializedProviderError
        if not subtitle.download_link:
            return
        r = self.session.get(
            subtitle.download_link,
            timeout=30,
            headers={'Referer': subtitle.page_link or self.server_url},
        )
        r.raise_for_status()
        try:
            zf = zipfile.ZipFile(io.BytesIO(r.content))
        except zipfile.BadZipFile:
            logger.error('regielive: not a zip for %r', subtitle)
            return
        names = [n for n in zf.namelist() if n.lower().endswith(('.srt', '.ass', '.ssa', '.sub'))]
        if not names:
            logger.error('regielive: no subtitle inside zip for %r', subtitle)
            return
        subtitle.set_content(fix_line_ending(zf.read(names[0])))

