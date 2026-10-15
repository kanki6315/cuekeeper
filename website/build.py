#!/usr/bin/env python3
"""Build Cuekeeper's static website using only Python's standard library."""
from pathlib import Path
import html
import json
import shutil

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'dist'
DOMAIN = 'https://cuekeeper.arjunakankipati.com'
EMAIL = 'cuekeeper@arjunakankipati.com'

def text(value):
    value = html.escape(value)
    value = value.replace(EMAIL, f'<a href="mailto:{EMAIL}">{EMAIL}</a>')
    value = value.replace(DOMAIN + '/privacy', '<a href="/privacy">Cuekeeper privacy policy</a>')
    return value

def mark():
    source = (ROOT / 'assets/mark.svg').read_text()
    source = source.replace('<svg ', '<svg aria-hidden="true" focusable="false" ')
    return source.replace('fill="#073E27"', 'fill="currentColor"')

def shell(title, description, route, body, *, noindex=False):
    nav = ''.join(f'<a href="{href}"' + (' aria-current="page"' if href == route else '') + f'>{label}</a>'
                  for href, label in [('/', 'Home'), ('/support', 'Help & Support'), ('/privacy', 'Privacy')])
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)} — Cuekeeper</title>
<meta name="description" content="{html.escape(description, quote=True)}">
<meta name="color-scheme" content="light dark">
{('<meta name="robots" content="noindex">' if noindex else '')}
<link rel="canonical" href="{DOMAIN}{route}">
<meta property="og:title" content="{html.escape(title, quote=True)} — Cuekeeper">
<meta property="og:description" content="{html.escape(description, quote=True)}">
<meta property="og:type" content="website">
<meta property="og:url" content="{DOMAIN}{route}">
<meta property="og:site_name" content="Cuekeeper">
<link rel="icon" href="/assets/mark.svg" type="image/svg+xml">
<link rel="stylesheet" href="/assets/site.css">
</head>
<body id="top">
<a class="skip" href="#main">Skip to content</a>
<header class="site-header wrap">
<a class="brand" href="/" aria-label="Cuekeeper home">{mark()}<span>Cuekeeper</span></a>
<nav class="nav" aria-label="Main navigation">{nav}</nav>
</header>
{body}
<footer class="site-footer wrap">
<p>© 2026 Arjuna Kankipati · Cuekeeper</p>
<nav class="footer-links" aria-label="Footer"><a href="/support">Help & Support</a><a href="/privacy">Privacy policy</a><a href="mailto:{EMAIL}">Email support</a></nav>
</footer>
</body>
</html>
'''

def guide(data, route):
    index = ''.join(f'<li><a href="#{s["id"]}">{html.escape(s.get("nav", s["title"]))}</a></li>' for s in data['sections'])
    sections = []
    for section in data['sections']:
        paragraphs = ''.join(f'<p>{text(p)}</p>' for p in section.get('paragraphs', []))
        steps = '<ol>' + ''.join(f'<li>{text(p)}</li>' for p in section['steps']) + '</ol>' if section.get('steps') else ''
        after = ''.join(f'<p>{text(p)}</p>' for p in section.get('after', []))
        note = f'<p class="note">{text(section["note"])}</p>' if section.get('note') else ''
        if section['id'] == 'data':
            after += '<p><a href="/privacy">Read the full privacy policy</a></p>'
        if section['id'] == 'this-website':
            after += '<p><a href="https://www.cloudflare.com/privacypolicy/">Cloudflare privacy policy</a></p>'
        if section['id'] == 'icloud-sync-and-backups':
            after += '<p><a href="https://www.apple.com/legal/privacy/">Apple privacy policy</a></p>'
        sections.append(f'<section id="{section["id"]}" aria-labelledby="{section["id"]}-heading"><h2 id="{section["id"]}-heading">{html.escape(section["title"])}</h2>{paragraphs}{steps}{after}{note}<a class="back-top" href="#top">Back to top</a></section>')
    updated = f'<p class="updated">Last updated {html.escape(data["updated"])}</p>' if data.get('updated') else ''
    contact = f'<div class="contact-line"><a class="button" href="mailto:{EMAIL}">Email support</a><a class="email" href="mailto:{EMAIL}">{EMAIL}</a></div>' if route == '/support' else ''
    body = f'''<main id="main" class="wrap">
<div class="page-intro"><h1>{html.escape(data['title'])}</h1>{updated}<p class="lede">{text(data['introduction'])}</p>{contact}</div>
<div class="guide-layout"><aside class="topic-index"><nav aria-labelledby="topics-heading"><h2 id="topics-heading">On this page</h2><ul>{index}</ul></nav></aside>
<article class="article" aria-label="{html.escape(data['title'], quote=True)}">{''.join(sections)}</article></div>
</main>'''
    return shell(data['title'], data['description'], route, body)

def build():
    OUT.mkdir(exist_ok=True)
    shutil.copytree(ROOT / 'assets', OUT / 'assets', dirs_exist_ok=True)
    for slug in ['support', 'privacy']:
        data = json.loads((ROOT / 'content' / f'{slug}.json').read_text())
        # Root-level HTML gives Cloudflare Pages extensionless /support and /privacy routes.
        (OUT / f'{slug}.html').write_text(guide(data, '/' + slug))
    home = '''<main id="main" class="wrap">
<section class="home-hero" aria-labelledby="home-title">
<h1 id="home-title">Your work,<br>kept together.</h1>
<div><p class="lede">A daybook for broadcast freelancers. Keep bookings, sessions, fees and payments in one place, from the first enquiry to the final payment.</p><p class="platforms">Built for iPhone and iPad.</p></div>
</section>
<section class="home-band" aria-labelledby="home-support"><div><h2 id="home-support">A little help.<br>Right on cue.</h2><p>Setting up your calendar? Looking for a receipt? Find clear steps for the things you do in Cuekeeper.</p></div><div><p>Get started, troubleshoot iCloud, review expenses and understand your backups.</p><a class="button" href="/support">Open the support guide</a></div></section>
<div class="home-note"><p>Your daybook stays on your device and syncs through your private iCloud database when available.</p><a href="/privacy">How Cuekeeper handles your data</a></div>
</main>'''
    (OUT / 'index.html').write_text(shell('Your work, kept together', 'The daybook for broadcast freelancers. Events, sessions, fees, payments and receipt expenses for iPhone and iPad.', '/', home))
    error = '<main id="main" class="wrap"><div class="error-page"><h1>This page isn’t here.</h1><p>The link may have changed. The support guide is a good place to start.</p><a class="button" href="/support">Go to Help & Support</a></div></main>'
    (OUT / '404.html').write_text(shell('Page not found', 'Find help with Cuekeeper.', '/404', error, noindex=True))
    (OUT / '_headers').write_text("""/*
  Content-Security-Policy: default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests
  Referrer-Policy: strict-origin-when-cross-origin
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()
/assets/*
  Cache-Control: public, max-age=3600
""")
    (OUT / 'robots.txt').write_text(f'User-agent: *\nAllow: /\nSitemap: {DOMAIN}/sitemap.xml\n')
    urls = ''.join(f'<url><loc>{DOMAIN}{route}</loc></url>' for route in ['/', '/support', '/privacy'])
    (OUT / 'sitemap.xml').write_text(f'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">{urls}</urlset>\n')
    print(f'Built static site: {OUT}')

if __name__ == '__main__':
    build()
