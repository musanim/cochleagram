#!/bin/bash
# ES modules and .wasm cannot be loaded from file:// -- the browser refuses on
# origin grounds -- so the site needs an HTTP server even to look at it.
#
# And it needs one that forbids caching. A plain reload does not reliably
# refetch an imported ES module, so an edit to display.js or engine-worker.js
# can appear to have done nothing at all, which is indistinguishable from
# having written it wrong. This is a development server; correctness beats
# speed.
cd "$(dirname "$0")/site"
echo "http://localhost:8000/"
exec python3 - "$@" <<'PY'
import http.server, socketserver

class NoCache(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        super().end_headers()

    def send_head(self):
        # Never answer "not modified": the browser would then reuse what it
        # already has, which is the thing being avoided. Dropping the
        # conditional header is enough -- the handler only checks it if it is
        # there.
        if 'If-Modified-Since' in self.headers:
            del self.headers['If-Modified-Since']
        return super().send_head()

class Server(socketserver.TCPServer):
    allow_reuse_address = True

with Server(('', 8000), NoCache) as httpd:
    httpd.serve_forever()
PY
