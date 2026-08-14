#!/bin/bash
#
# Copy the built site into the musanim mirror, ready to upload.
#
# Everything the page needs is a plain file -- no server-side anything -- so
# publishing is a copy. The app lands in a subdirectory and the page embeds it,
# which keeps the prose and the instrument separate: the article scrolls, the
# instrument does not.
#
#   ./build.sh && ./publish.sh
set -euo pipefail
cd "$(dirname "$0")"

DEST=~/Documents/Active/HTMirror/musanim/Cochleagram/app

[ -f site/cochlea.wasm ] || { echo "no site/cochlea.wasm -- run ./build.sh first"; exit 1; }

mkdir -p "$DEST"
# selftest.html is a bench, not a page anyone visiting the site wants.
rsync -a --delete --exclude selftest.html site/ "$DEST/"

# Stamp every module fetch with the publish time.
#
# A browser will not reliably refetch an ES module on a plain reload, and the
# failure is silent and total: an index.html that imports a name its cached
# copy of closeup.js does not export fails to *link*, so not one line of the
# page runs and the controls simply come up empty. That has now cost two
# rounds of looking for a bug in the wrong file. A query string the server
# ignores but the cache does not makes each publish its own new URL.
STAMP=$(date +%Y%m%d%H%M%S)
find "$DEST" -name '*.html' -o -name '*.js' | while read -r f; do
    LC_ALL=C sed -i '' "s/?v=[A-Za-z0-9]*/?v=$STAMP/g" "$f" 2>/dev/null \
        || LC_ALL=C sed -i "s/?v=[A-Za-z0-9]*/?v=$STAMP/g" "$f"
done
echo "cache stamp: $STAMP"

echo "copied to $DEST"
du -sh "$DEST"
echo
echo "Upload the whole Cochleagram directory: index.html, icon.png, the zip,"
echo "and app/ -- the page is inert without it."
