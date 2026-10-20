#!/usr/bin/env python3
"""Check the Hugo output, including project-relative assets and anchor links."""

from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit


ROOT = Path(__file__).resolve().parents[1] / 'website' / 'public'
BASE = 'https://iuxt.github.io/TaskTick/'


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.links = []
        self.ids = set()
        self.h1s = 0
        self.feed(source.read_text())

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'id' in attrs:
            self.ids.add(attrs['id'])
        self.h1s += tag == 'h1'
        for attr in ('href', 'src'):
            if attrs.get(attr):
                self.links.append(attrs[attr])


def check():
    errors = []
    for name in ('index.html', 'en/index.html', '404.html', 'guide/index.html', 'icon.png', 'sitemap.xml', 'robots.txt'):
        if not (ROOT / name).is_file():
            errors.append(f'Missing output: {name}')
    # The retained multilingual guide is checked for local links as well.
    pages = {p: Page(p) for p in ROOT.rglob('*.html')}
    for source, page in pages.items():
        if source.relative_to(ROOT).as_posix() in ('index.html', 'en/index.html') and page.h1s != 1:
            errors.append(f'{source}: expected exactly one h1')
        source_url = urljoin(BASE, source.relative_to(ROOT).as_posix())
        for link in page.links:
            target = urlsplit(urljoin(source_url, link))
            if target.netloc != 'iuxt.github.io':
                continue
            if not target.path.startswith('/TaskTick/'):
                errors.append(f'{source.name}: link escapes project path: {link}')
                continue
            local = ROOT / unquote(target.path.removeprefix('/TaskTick/'))
            if local.is_dir():
                local /= 'index.html'
            if not local.is_file():
                errors.append(f'{source.name}: broken local link: {link}')
            elif target.fragment and local in pages and unquote(target.fragment) not in pages[local].ids:
                errors.append(f'{source.name}: missing anchor: {link}')
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'Website checks passed: {len(pages)} HTML files, local assets, and anchors.')


if __name__ == '__main__':
    check()
