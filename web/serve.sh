#!/bin/bash
# ES modules and .wasm cannot be loaded from file:// -- the browser refuses on
# origin grounds -- so the site needs an HTTP server even to look at it.
#
# And it needs one that forbids caching. A plain reload does not reliably
# refetch an imported ES module, so an edit to display.js or engine-worker.js
# can appear to have done nothing at all, which is indistinguishable from
# having written it wrong. This is a development server; correctness beats
# speed.
# A directory may be given, so that the whole published page can be looked at
# the way a visitor will see it -- index.html with the app in a frame -- and
# not only the app on its own:
#
#   ./serve.sh ~/Documents/Active/HTMirror/musanim/Cochleagram
DIR="${1:-$(cd "$(dirname "$0")/site" && pwd)}"
cd "$DIR"
echo "serving $DIR"
echo "http://localhost:8000/"
exec python3 - <<'PY'
import http.server, socketserver, os, re, time

class NoCache(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        super().end_headers()

    def do_GET(self):
        # Rewrite the cache-busting stamp on the way out, so every load of a
        # page asks for module URLs no browser has ever seen.
        #
        # The no-store headers below ought to be enough and are not: an ES
        # module graph is held in a module map that a plain reload does not
        # necessarily rebuild, and the failure is silent -- an edit appears to
        # have done nothing, which is indistinguishable from having written it
        # wrong. The alternative is remembering a hard reload every single
        # time, and a development server that punishes you for forgetting is
        # not doing its job. `publish.sh` stamps the same pattern once, at
        # publish time; this stamps it on every request.
        path = self.translate_path(self.path.split('?', 1)[0])
        if os.path.isfile(path) and path.endswith(('.html', '.js')):
            with open(path, 'rb') as f:
                body = f.read()
            body = re.sub(rb'\?v=[A-Za-z0-9]*',
                          b'?v=' + str(time.time_ns()).encode(), body)
            self.send_response(200)
            self.send_header('Content-Type', self.guess_type(path))
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

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
