#!/bin/bash
#
# Copy the built site into the musanim mirror, ready to upload.
#
# Everything the page needs is a plain file -- no server-side anything -- so
# publishing is a copy. The app lands in a subdirectory and the page embeds it,
# which keeps the prose and the instrument separate: the article scrolls, the
# instrument does not.
#
# Everything the mirror holds comes from this repository: the instrument in
# `app/`, the page around it from `page/`, and the release zip from the Mac
# app's `dist/`. Nothing there is edited by hand any more, and nothing there
# needs to be. What is left to do afterwards is the upload.
#
#   ./build.sh && ./publish.sh          # build.sh only when the engine changed
set -euo pipefail
cd "$(dirname "$0")"

MIRROR=~/Documents/Active/HTMirror/musanim/Cochleagram
DEST=$MIRROR/app

die() { echo "$@" >&2; exit 1; }

[ -f site/cochlea.wasm ] || die "no site/cochlea.wasm -- run ./build.sh first"

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
    die "site/cochlea.wasm is older than the engine source -- run ./build.sh first"
fi

# The version, from the Mac app's Info.plist.
#
# Read rather than written down, so there is one number for both apps and no
# second place to bump. Read here rather than in `build.sh` because build.sh
# writes into `site/`, which is the repository -- a build that edited tracked
# source would put a diff in the tree every time it ran. Everything below edits
# copies.
#
# Parsed out of the XML with sed rather than with PlistBuddy or plutil: it is
# two lines either way, and this one also works when the tree is looked at from
# somewhere that is not a Mac.
#
# Fatal now, where it used to be a warning that left the title saying "(dev)".
# The page around the instrument is generated from this number -- its title, its
# download link and its version line -- so publishing without it would not
# produce a slightly wrong page but a visibly broken one.
VERSION=$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' \
          ../xcode/Cochleagram/Info.plist)
[ -n "$VERSION" ] || die "no CFBundleShortVersionString in ../xcode/Cochleagram/Info.plist"

# And the release it names has to exist.
#
# This is the check that would have caught the state this script could
# previously reach on its own: a page announcing a version whose download is a
# 404, because the release build had not been run. The zip is named after the
# version, so asking for it by name asks the question exactly.
ZIP=../xcode/Cochleagram/dist/Cochleagram-$VERSION.zip
[ -f "$ZIP" ] || die "no $ZIP -- run 'Build Release to Share.command' first"

echo "version: $VERSION"

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

# The instrument's own title carries the version too, so a window popped out of
# the frame still says which release it is.
LC_ALL=C sed -i '' "s|<title>Cochleagram ([^<)]*)</title>|<title>Cochleagram ($VERSION)</title>|" \
    "$DEST/index.html" 2>/dev/null \
    || LC_ALL=C sed -i "s|<title>Cochleagram ([^<)]*)</title>|<title>Cochleagram ($VERSION)</title>|" \
        "$DEST/index.html"

# ---------------------------------------------------------------- the page
#
# `page/index.html` is the source and the mirror's copy is a build product.
# For three releases it was the other way round -- the page existed only on the
# mirror and its title, download link and version line were retyped by hand
# every time, against features that live in this repository.

# Rounded from the zip itself rather than written into the page, because the
# figure is there to set an expectation before a click and a stale one is worse
# than none. `wc -c` rather than `stat`, whose flags differ between the Mac this
# runs on and everything else.
BYTES=$(wc -c < "$ZIP")
SIZE=$(awk -v b="$BYTES" 'BEGIN { printf "%.1f MB", b / 1048576 }')

# The note at the top of the source is about the source, and is stripped before
# anything else happens -- it names the placeholders, so leaving it in would
# both substitute them inside it and publish a comment telling a visitor that
# the file they are looking at is not the one to edit. Stripped first rather
# than last, so the placeholder check below cannot be satisfied by text that was
# only ever going to be removed. The page's other comments ship, as they always
# have; they are about the page.
awk 'index($0, "<!-- SOURCE-NOTE") { s = 1 }
     !s { print }
     index($0, "SOURCE-NOTE -->") { s = 0 }' page/index.html \
| sed -e "s|@VERSION@|$VERSION|g" \
      -e "s|@ZIP@|Cochleagram-$VERSION.zip|g" \
      -e "s|@SIZE@|$SIZE|g" \
      > "$MIRROR/index.html"

# A placeholder that survived means a substitution silently did not happen, and
# the whole reason they are ugly is so that this can be checked. Refusing here
# is the difference between noticing now and finding "@VERSION@" on the live
# site. The generated file is removed, so a failed publish cannot leave a
# half-substituted page behind for the upload to pick up.
if grep -q '@[A-Z][A-Z_]*@' "$MIRROR/index.html"; then
    grep -n '@[A-Z][A-Z_]*@' "$MIRROR/index.html" >&2
    rm -f "$MIRROR/index.html"
    die "unsubstituted placeholders above -- publish.sh and page/index.html disagree"
fi

cp page/icon.png "$MIRROR/icon.png"

# ---------------------------------------------------------------- the release
#
# The old zip goes before the new one arrives. Two of them in the directory is
# the state where the page offers one and the upload carries both, and the
# stale one stays reachable at its old URL for anybody who linked to it.
# Narrow enough a pattern that it can only match a release of this app.
rm -f "$MIRROR"/Cochleagram-*.zip
cp "$ZIP" "$MIRROR/Cochleagram-$VERSION.zip"

echo "cache stamp: $STAMP"
echo "page:        $MIRROR/index.html"
echo "download:    Cochleagram-$VERSION.zip ($SIZE)"
echo "instrument:  $DEST"
du -sh "$MIRROR"
echo
echo "Nothing here is edited by hand. Upload the whole Cochleagram directory:"
echo "index.html, icon.png, the zip, and app/ -- the page is inert without it."
