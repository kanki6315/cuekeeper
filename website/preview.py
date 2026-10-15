#!/usr/bin/env python3
"""Serve built pages locally with Cloudflare-like clean HTML URLs. Never opens a browser."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
import argparse

ROOT = Path(__file__).resolve().parent / 'dist'

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        self.serve(head=False)

    def do_HEAD(self):
        self.serve(head=True)

    def serve(self, head):
        path = urlsplit(self.path).path
        if path in ('/support', '/support/', '/privacy', '/privacy/'):
            self.path = path.rstrip('/') + '.html'
        target = Path(self.translate_path(self.path))
        if not target.exists():
            body = (ROOT / '404.html').read_bytes()
            self.send_response(404)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            if not head: self.wfile.write(body)
            return
        if head: super().do_HEAD()
        else: super().do_GET()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', default=8080, type=int)
    args = parser.parse_args()
    if not (ROOT / 'index.html').exists():
        parser.error('Run python3 website/build.py first.')
    server = ThreadingHTTPServer(('127.0.0.1', args.port), partial(Handler, directory=str(ROOT)))
    print(f'Preview ready at http://127.0.0.1:{args.port} — open it yourself. Ctrl-C stops the server.', flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()
