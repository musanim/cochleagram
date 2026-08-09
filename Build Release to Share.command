#!/bin/bash
#
# Double-click this to build a Cochleagram anyone can run, and reveal the zip.
#
# It bumps the version in Info.plist and runs xcode/Cochleagram/scripts/release.sh
# (build, sign, notarize, staple, package). Nothing to remember and nothing to
# type; the only thing it needs from you is patience while Apple notarizes,
# which is usually a couple of minutes.
#
# A `.command` file is run by Finder with an unpredictable working directory and
# a login shell, so this cds to its own folder, and release.sh calls every Apple
# tool by absolute path for the same reason (Humdrum shadows `ditto` on this
# machine).
#
# Version: bumps the last component -- 0.1 becomes 0.2, 1.2.3 becomes 1.2.4.
# For a bigger jump, edit CFBundleShortVersionString in
# xcode/Cochleagram/Info.plist by hand first and this carries on from there.
# CFBundleVersion, which the user never sees but macOS compares, is bumped as
# a plain integer alongside it.
#
# If anything fails, Info.plist is put back the way it was, so a failed release
# doesn't quietly leave the version bumped and the next attempt skipping a
# number.

set -euo pipefail
cd "$(dirname "$0")"

APPDIR="xcode/Cochleagram"
PLIST="$APPDIR/Info.plist"

say() { printf '\n=== %s ===\n' "$1"; }

pause_and_exit() {
    printf '\nPress Return to close this window.\n'
    read -r _ || true
    exit "$1"
}

[ -f "$PLIST" ] || {
    printf 'Cannot find %s -- is this script still beside the project?\n' "$PLIST" >&2
    pause_and_exit 1
}

BACKUP="$(/usr/bin/mktemp -t cochleagram-info-plist)"
/bin/cp "$PLIST" "$BACKUP"

restore_and_fail() {
    /bin/cp "$BACKUP" "$PLIST"
    /bin/rm -f "$BACKUP"
    printf '\nSomething failed above, so nothing was released.\n'
    printf 'Info.plist has been put back the way it was (version NOT bumped).\n'
    pause_and_exit 1
}
trap restore_and_fail ERR

# -------------------------------------------------------------- bump version
say "version"

PB=/usr/libexec/PlistBuddy
CURRENT="$($PB -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
[ -n "$CURRENT" ] || { printf 'No CFBundleShortVersionString in %s\n' "$PLIST" >&2
                       restore_and_fail; }

# Bump whatever the last dot-separated component is, so this works for "0.1"
# and for "1.2.3" without caring which scheme is in use.
HEAD="${CURRENT%.*}"
TAIL="${CURRENT##*.}"
case "$TAIL" in
    ''|*[!0-9]*) printf 'Version "%s" does not end in a number\n' "$CURRENT" >&2
                 restore_and_fail ;;
esac
if [ "$HEAD" = "$CURRENT" ]; then NEXT="$((TAIL + 1))"       # no dot at all
else NEXT="$HEAD.$((TAIL + 1))"; fi

BUILD="$($PB -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || echo 0)"
case "$BUILD" in ''|*[!0-9]*) BUILD=0 ;; esac

$PB -c "Set :CFBundleShortVersionString $NEXT" "$PLIST"
$PB -c "Set :CFBundleVersion $((BUILD + 1))" "$PLIST"

WROTE="$($PB -c 'Print :CFBundleShortVersionString' "$PLIST")"
[ "$WROTE" = "$NEXT" ] || { printf 'Version bump did not take (wanted %s, got %s)\n' \
                                   "$NEXT" "$WROTE" >&2; restore_and_fail; }
printf '%s  ->  %s   (build %s -> %s)\n' "$CURRENT" "$NEXT" "$BUILD" "$((BUILD + 1))"

# ------------------------------------------------------------------- release
"$APPDIR/scripts/release.sh"

# ------------------------------------------------------------------- deliver
trap - ERR
/bin/rm -f "$BACKUP"

ZIP="$APPDIR/dist/Cochleagram-$NEXT.zip"
say "ready"
if [ -f "$ZIP" ]; then
    printf 'Send this file:\n  %s\n' "$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")"
    /usr/bin/open -R "$ZIP"          # reveal it in Finder, selected
    printf '\nIt is now selected in a Finder window. Attach it to a mail, or drag\n'
    printf 'it wherever you like. The recipient unzips it, drags Cochleagram.app\n'
    printf 'to Applications, and double-clicks. No warnings, no instructions.\n'
    printf '\nThe first run asks for the microphone. Declining is survivable --\n'
    printf 'Play File still works -- but live input is the point of it.\n'
else
    printf 'The release finished but %s is not there -- look at the output above.\n' "$ZIP"
fi

pause_and_exit 0
