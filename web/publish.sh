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

# And it has to be *current*, not merely present.
#
# The engine's C interface has changed under a checked-in build before. A
# JavaScript call into WebAssembly with more arguments than the export declares
# does not fail: the extras are dropped, so a later parameter arrives holding
# whatever the first dropped one was -- a heap address where a count belongs.
# Nothing raises, and the page misbehaves in a way that looks like a drawing
# bug. Cheap to prevent, expensive to find.
if [ site/cochlea.wasm -ot ../xcode/Cochleagram/Sources/CochleaDSP/cochlea.cpp ] ||
   [ site/cochlea.wasm -ot ../xcode/Cochleagram/Sources/CochleaDSP/include/cochlea.h ]; then
    echo "site/cochlea.wasm is older than the engine source -- run ./build.sh first"
    exit 1
fi

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

# The version in the page's title, from the Mac app's Info.plist.
#
# Read rather than written down, so there is one number for both apps and no
# second place to bump. Read here rather than in `build.sh` because build.sh
# writes into `site/`, which is the repository -- a build that edited tracked
# source would put a diff in the tree every time it ran. This edits the copy.
#
# Parsed out of the XML with sed rather than with PlistBuddy or plutil: it is
# two lines either way, and this one also works when the tree is looked at from
# somewhere that is not a Mac.
VERSION=$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' \
          ../xcode/Cochleagram/Info.plist)
if [ -n "$VERSION" ]; then
    LC_ALL=C sed -i '' "s|<title>Cochleagram ([^<)]*)</title>|<title>Cochleagram ($VERSION)</title>|" \
        "$DEST/index.html" 2>/dev/null \
        || LC_ALL=C sed -i "s|<title>Cochleagram ([^<)]*)</title>|<title>Cochleagram ($VERSION)</title>|" \
            "$DEST/index.html"
    echo "version: $VERSION"
else
    echo "WARNING: no CFBundleShortVersionString found -- the title still says (dev)"
fi

echo "copied to $DEST"
du -sh "$DEST"
echo
echo "Upload the whole Cochleagram directory: index.html, icon.png, the zip,"
echo "and app/ -- the page is inert without it."
