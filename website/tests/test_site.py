"""Validate deployable output without a browser or third-party dependencies."""
from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote
import importlib.util
import json
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('site_build', ROOT / 'build.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

class Document(HTMLParser):
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.ids = []; self.links = []; self.headings = []; self.tags = []
        self.feed(source)
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs); self.tags.append((tag, attrs))
        if 'id' in attrs: self.ids.append(attrs['id'])
        if tag in ('a', 'link'): self.links.append(attrs.get('href', ''))
        if tag == 'img': self.links.append(attrs.get('src', ''))
        if tag in ('h1', 'h2', 'h3'): self.headings.append(tag)

class StaticSiteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        builder.build()
        cls.output = ROOT / 'dist'
        cls.documents = {p.name: Document(p.read_text()) for p in cls.output.glob('*.html')}

    def test_internal_links_and_fragments_resolve(self):
        for name, doc in self.documents.items():
            for href in doc.links:
                with self.subTest(page=name, href=href):
                    url = urlsplit(href)
                    if url.scheme or url.netloc: continue
                    path = unquote(url.path)
                    target = self.output / (path.lstrip('/') or name)
                    if path == '/': target = self.output / 'index.html'
                    if not target.suffix: target = target.with_suffix('.html')
                    self.assertTrue(target.is_file())
                    if url.fragment:
                        self.assertIn(unquote(url.fragment), Document(target.read_text()).ids)

    def test_accessible_structure_and_no_runtime_tracking(self):
        for name, doc in self.documents.items():
            with self.subTest(page=name):
                self.assertEqual(len(doc.ids), len(set(doc.ids)))
                self.assertEqual(doc.headings.count('h1'), 1)
                self.assertEqual(sum(t == 'main' for t, a in doc.tags), 1)
                self.assertIn('#main', doc.links)
                self.assertTrue(any(t == 'html' and a.get('lang') == 'en' for t, a in doc.tags))
                self.assertFalse(any(t in ('script', 'iframe', 'form') for t, a in doc.tags))
                self.assertFalse(any(t == 'img' and 'alt' not in a for t, a in doc.tags))
                self.assertTrue(all(a.get('aria-label') or a.get('aria-labelledby') for t, a in doc.tags if t == 'nav'))
                self.assertFalse(any('mailto:' in h and '?' in h for h in doc.links))
                self.assertTrue(any(t == 'link' and a.get('rel') == 'canonical' for t, a in doc.tags))

    def test_all_guide_sections_have_index_links(self):
        for slug in ('support', 'privacy'):
            data = json.loads((ROOT / 'content' / f'{slug}.json').read_text())
            doc = self.documents[f'{slug}.html']
            for section in data['sections']:
                self.assertIn(section['id'], doc.ids)
                self.assertIn('#' + section['id'], doc.links)

    def test_sitemap_and_deployment_security(self):
        tree = ET.parse(self.output / 'sitemap.xml')
        urls = [el.text for el in tree.iter() if el.tag.endswith('loc')]
        self.assertEqual(urls, [builder.DOMAIN + p for p in ('/', '/support', '/privacy')])
        headers = (self.output / '_headers').read_text()
        self.assertIn("default-src 'none'", headers)
        self.assertIn("frame-ancestors 'none'", headers)
        self.assertTrue((self.output / '404.html').is_file())
        self.assertLess(sum(p.stat().st_size for p in self.output.rglob('*') if p.is_file()), 250_000)

    def test_primary_color_pairs_meet_contrast(self):
        def luminance(hex):
            channels = [int(hex[i:i+2], 16)/255 for i in (0,2,4)]
            return sum(c*w for c,w in zip([v/12.92 if v <= .04045 else ((v+.055)/1.055)**2.4 for v in channels], [.2126,.7152,.0722]))
        pairs = [('171e19','faf8f2'),('626860','faf8f2'),('073e27','faf8f2'),('ffffff','073e27'),('faf8f2','171e19'),('b7bfb8','171e19'),('a7dcb4','171e19'),('073e27','a7dcb4'),('d6e5d7','073e27')]
        for foreground, background in pairs:
            values = sorted([luminance(foreground), luminance(background)])
            self.assertGreaterEqual((values[1]+.05)/(values[0]+.05), 4.5)

if __name__ == '__main__':
    unittest.main()
