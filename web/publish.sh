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

echo "copied to $DEST"
du -sh "$DEST"
echo
echo "Upload the whole Cochleagram directory: index.html, icon.png, the zip,"
echo "and app/ -- the page is inert without it."
