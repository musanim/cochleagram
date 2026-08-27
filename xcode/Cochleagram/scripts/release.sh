#!/bin/bash
#
# Build, sign, notarize and staple a Cochleagram.app that opens on someone
# else's Mac.
#
# Why each step is here, since skipping any one of them produces an app that
# looks fine locally and is refused on the recipient's machine:
#
#   build      make_app.sh, forced to a Developer ID identity. Its ordinary
#              behaviour is to take any code-signing certificate it can find,
#              which is right for working on the display and useless for
#              handing the app to anyone: notarization needs Developer ID and
#              the hardened runtime.
#   verify     Catches a bad signature here rather than after a round trip to
#              Apple.
#   zip        `ditto -c -k --keepParent` -- the only zip format notarytool
#              accepts. A Finder-compressed archive or `zip -r` is rejected,
#              sometimes obscurely.
#   notarize   Apple scans the binary and issues a ticket.
#   staple     Attaches the ticket TO THE APP, so it opens even if the
#              recipient is offline and with no instructions attached. The
#              ticket cannot be stapled to a zip, which is why the app is
#              zipped twice: once to submit, once to hand over.
#   assess     Asks Gatekeeper the same question the recipient's Mac will ask.
#
# The microphone is the part that makes this app different from most. It needs
# NSMicrophoneUsageDescription in Info.plist and com.apple.security.device.audio
# -input in the entitlements, and under the hardened runtime the entitlement is
# not optional -- without it the runtime vetoes the microphone even after the
# user has granted permission, which looks exactly like the permission failing
# to stick. Both are checked below rather than assumed.
#
# One-time setup before this will run:
#   1. A Developer ID Application certificate in the keychain.
#   2. An app-specific password from appleid.apple.com.
#   3. xcrun notarytool store-credentials "<profile>" \
#        --apple-id <your-apple-id> --team-id <your-team> --password <that>
#
# The profile is looked for by name; set NOTARY_PROFILE to override.
#
# Usage: scripts/release.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/Cochleagram.app"
DIST="$REPO/dist"

say() { printf '\n=== %s ===\n' "$1"; }
die() { printf '\nFAILED: %s\n' "$1" >&2; exit 1; }

# Every check below reads a command's output into a variable and matches with
# `case`, rather than piping to `grep -q`. That is not fastidiousness: `grep -q`
# exits at the first match, the upstream command dies of SIGPIPE, and `pipefail`
# then reports the whole pipeline as failed -- so the test fails exactly when it
# should pass.
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# Apple tools by absolute path. Stephen's PATH puts Humdrum ahead of /usr/bin
# and Humdrum ships its own `ditto` -- a text utility, not an archiver.

# ---------------------------------------------------------------- preflight
say "preflight"

IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
contains "$IDENTITIES" "Developer ID Application" \
  || die "No Developer ID Application certificate in the keychain.
       Create one at developer.apple.com. A free Apple Development
       certificate is enough to run the app yourself but cannot be
       notarized, so it cannot be given to anyone."

SIGN_ID="$(printf '%s\n' "$IDENTITIES" \
  | /usr/bin/grep 'Developer ID Application' | head -1 \
  | /usr/bin/sed -E 's/.*"(.*)".*/\1/')"
echo "signing identity: $SIGN_ID"

PROFILE="${NOTARY_PROFILE:-}"
if [ -z "$PROFILE" ]; then
    for candidate in cochleagram-notary eudora-notary notary; do
        if /usr/bin/xcrun notarytool history --keychain-profile "$candidate" \
             >/dev/null 2>&1; then PROFILE="$candidate"; break; fi
    done
fi
[ -n "$PROFILE" ] || die "No notarytool keychain profile found.
       Create one with:
         xcrun notarytool store-credentials \"cochleagram-notary\" \\
           --apple-id <your-apple-id> --team-id <your-team> --password <app-specific>
       or set NOTARY_PROFILE to one you already have."
echo "notary profile:   $PROFILE"

# -------------------------------------------------------------------- build
say "build (release)"
CODESIGN_ID="$SIGN_ID" "$REPO/make_app.sh" release

[ -d "$APP" ] || die "No app at $APP -- the build did not produce one."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
echo "built Cochleagram $VERSION"

# ------------------------------------------------------------------- verify
say "verify signature and entitlements"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | /usr/bin/sed 's/^/  /'

SIGINFO="$(/usr/bin/codesign -dvvv "$APP" 2>&1 || true)"
contains "$SIGINFO" "Authority=Developer ID Application" \
  || die "Not signed with a Developer ID Application certificate."
contains "$SIGINFO" "(runtime)" \
  || die "Hardened runtime is not enabled; notarization would reject this."

ENTS="$(/usr/bin/codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
contains "$ENTS" "com.apple.security.device.audio-input" \
  || die "The audio-input entitlement is missing. Under the hardened runtime
       the microphone is then vetoed however the user answers the prompt.
       Check Cochleagram.entitlements."

USAGE="$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' \
  "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$USAGE" ] \
  || die "NSMicrophoneUsageDescription is missing from Info.plist. macOS kills
       an app that asks for the microphone without one."

echo "  Developer ID, hardened runtime, microphone entitlement and usage string"

# ------------------------------------------------------------- resources
say "verify the coefficients are reachable"
# The app is useless without these and the failure is not visible here: it
# happens on first use, on the recipient's machine. Versions 0.2 and 0.3 both
# shipped unable to find them, because the only copy the app could see was an
# absolute path inside this machine's .build directory.
#
# Checked as a path rather than by running the app, since a freshly built and
# notarized app asking for the microphone is not something to do in a script.
RES="$APP/Contents/Resources"
SIDE="$RES/Cochleagram_CochleagramApp.bundle"
FOUND=""
for candidate in "$RES/cochlea_88200_erb100.coch" \
                 "$SIDE/cochlea_88200_erb100.coch" \
                 "$SIDE/Contents/Resources/cochlea_88200_erb100.coch"; do
    [ -f "$candidate" ] && { FOUND="$candidate"; break; }
done
[ -n "$FOUND" ] || die "No coefficient file anywhere the app will look:
         $RES/
         $SIDE/
       Without one it dies the first time anybody opens a file or a
       microphone. Check what make_app.sh copied."
echo "  found ${FOUND#$APP/}"

# All nine, not just the one the default tuning uses -- the ERB menu offers
# every scale and a missing bake is a dead menu entry.
#
# And every one of them version 2, meaning its de-skew curve is baked in. A
# version-1 file works, which is the problem: the engine quietly measures its
# own curve instead, costing 200 ms on every engine build and giving a
# different answer on different machines. Nothing downstream notices, so an
# export that never got through tools/bakeall.sh would ship unremarked. This
# is the one place that can say so.
MISSING=""
UNBAKED=""
for scale in 050 060 070 080 090 100 110 120 130; do
    base="cochlea_88200_erb$scale.coch"
    found=""
    for dir in "$RES" "$SIDE" "$SIDE/Contents/Resources"; do
        [ -f "$dir/$base" ] && { found="$dir/$base"; break; }
    done
    if [ -z "$found" ]; then
        MISSING="$MISSING $scale"
        continue
    fi
    # The version is an int32 at offset 4, after the 'COCH' magic. `od -tu4`
    # decodes in host order rather than the file's declared little-endian, so
    # this is right on the machines that run it and would need a byte swap on
    # a big-endian one, which macOS has not been since 2006.
    #
    # `|| true` because a failure here must reach the `die` below with a
    # legible message, not exit the script silently through `pipefail`.
    v=$(/bin/dd if="$found" bs=1 skip=4 count=4 2>/dev/null \
        | /usr/bin/od -An -tu4 | /usr/bin/tr -d ' ' || true)
    [ "$v" = "2" ] || UNBAKED="$UNBAKED $scale(v${v:-unreadable})"
done
[ -z "$MISSING" ] || die "ERB scales with no coefficient file:$MISSING"
[ -z "$UNBAKED" ] || die "ERB scales whose de-skew curve is not baked in:$UNBAKED
       Run xcode/Cochleagram/tools/bakeall.sh on this machine, rebuild, and
       start again. See OPEN-QUESTIONS.md."
echo "  all nine ERB scales present, all baked"

# ----------------------------------------------------------------- notarize
say "notarize"
mkdir -p "$DIST"
SUBMIT_ZIP="$DIST/Cochleagram-submit.zip"
rm -f "$SUBMIT_ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

LOG="$DIST/notarytool.log"
set +e
/usr/bin/xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$LOG"
set -e

if ! /usr/bin/grep -q "status: Accepted" "$LOG"; then
  ID="$(/usr/bin/awk '/^  *id: /{print $2; exit}' "$LOG")"
  echo
  echo "Notarization was not accepted. Apple's reasons:"
  [ -n "${ID:-}" ] && /usr/bin/xcrun notarytool log "$ID" --keychain-profile "$PROFILE" || true
  die "notarization rejected"
fi

# ------------------------------------------------------------------- staple
say "staple"
/usr/bin/xcrun stapler staple "$APP"
/usr/bin/xcrun stapler validate "$APP"

# ------------------------------------------------------------------- assess
say "Gatekeeper assessment"
# This is the question the recipient's Mac asks. "accepted / source=Notarized
# Developer ID" is the answer that means they can just double-click it.
ASSESS="$(/usr/sbin/spctl -a -vvv -t install "$APP" 2>&1 || true)"
echo "$ASSESS" | /usr/bin/sed 's/^/  /'
contains "$ASSESS" "accepted" \
  || die "Gatekeeper would refuse this app on the recipient's Mac."

# --------------------------------------------------------------- deliverable
say "package"
OUT="$DIST/Cochleagram-$VERSION.zip"
rm -f "$OUT"
/usr/bin/ditto -c -k --keepParent "$APP" "$OUT"
rm -f "$SUBMIT_ZIP"

say "done"
echo "Send this file:"
echo "  $OUT"
echo
echo "The recipient drags Cochleagram.app to /Applications and double-clicks."
echo "The first run asks for the microphone, which is the app's whole purpose;"
echo "declining leaves Play File working."
