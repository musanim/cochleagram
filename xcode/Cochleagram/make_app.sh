#!/bin/bash
# Build Cochleagram.app.
#
# SwiftPM produces a bare executable, and macOS will not grant microphone
# access to one -- it needs a bundle with NSMicrophoneUsageDescription in its
# Info.plist. So we build, then wrap.
#
#   ./make_app.sh                 release build
#   ./make_app.sh debug           debug build
#   CODESIGN_ID="..." ./make_app.sh   force a particular signing identity
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
APP="Cochleagram.app"

if [ ! -f Sources/CochleagramApp/Resources/cochlea_88200_erb100.coch ]; then
  echo "Coefficient file missing. Generating it..."
  # Every scale Package.swift declares, or the build fails on the missing
  # resources rather than on the missing coefficients.
  ( cd ../../prototype && python3 export_coeffs.py --fs 88200 \
      --erb-scale 0.5 --erb-scale 0.6 --erb-scale 0.7 --erb-scale 0.8 \
      --erb-scale 0.9 --erb-scale 1.0 --erb-scale 1.1 --erb-scale 1.2 \
      --erb-scale 1.3 \
      --out ../xcode/Cochleagram/Sources/CochleagramApp/Resources )
fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CochleagramApp" "$APP/Contents/MacOS/Cochleagram"
cp Info.plist "$APP/Contents/Info.plist"

# The icon. Built by make_icon.py from IconImage.PNG and checked in, so this is
# a copy rather than a step that needs iconutil to be present.
if [ -f Cochleagram.icns ]; then
  cp Cochleagram.icns "$APP/Contents/Resources/Cochleagram.icns"
else
  echo "NOTE: Cochleagram.icns is missing -- run: python3 make_icon.py"
fi

# SwiftPM puts declared resources in a side bundle; carry it along.
if [ -d "$BIN/Cochleagram_CochleagramApp.bundle" ]; then
  cp -R "$BIN/Cochleagram_CochleagramApp.bundle" "$APP/Contents/Resources/"
fi

# ---------------------------------------------------------------------------
# Signing.
#
# macOS grants microphone access to a code signature, not to a path. An ad-hoc
# signature has no stable identity: its cdhash changes with every build, so TCC
# sees a brand new application each time and asks again. Signing with a real
# certificate gives the bundle a stable designated requirement and the grant
# sticks across rebuilds.
#
# Any Apple certificate will do -- a free Apple Development one from Xcode's
# Settings > Accounts is enough. We look for one and fall back to ad-hoc.
# ---------------------------------------------------------------------------
if [ -z "${CODESIGN_ID:-}" ]; then
  # Prefer an Apple identity, but accept ANY code-signing identity -- a
  # self-signed certificate made in Keychain Access works perfectly well for
  # this and needs no Apple ID.
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  CODESIGN_ID="$(printf '%s\n' "$IDENTITIES" \
    | grep -E 'Developer ID Application|Apple Development|Mac Developer' \
    | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
  if [ -z "$CODESIGN_ID" ]; then
    CODESIGN_ID="$(printf '%s\n' "$IDENTITIES" \
      | grep -E '^ *[0-9]+\)' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
  fi
fi

if [ -n "${CODESIGN_ID:-}" ]; then
  echo "Signing with: $CODESIGN_ID"
  # The audio-input entitlement is mandatory under the hardened runtime.
  # Without it the runtime vetoes the microphone even when the user has
  # granted it in System Settings -- which looks exactly like the permission
  # not sticking.
  #
  # Note: AMFI parses the entitlements plist with its own reader, which does
  # NOT accept XML comments. Keep Cochleagram.entitlements bare.
  codesign --force --options runtime \
           --entitlements Cochleagram.entitlements \
           --sign "$CODESIGN_ID" "$APP"
else
  codesign --force --sign - "$APP" 2>/dev/null || true
  cat <<'EOF'

  NOTE: no code-signing identity found, so this is an ad-hoc signature.
  macOS ties microphone permission to a signature, and an ad-hoc one changes
  on every build -- so the Cochleagram switch in System Settings stays on
  while the new build is treated as a stranger and asks again.

  Either fix works, and neither costs anything:

    A. Xcode > Settings > Accounts > add Apple ID > Manage Certificates >
       "+" > Apple Development.

    B. No Apple ID needed: Keychain Access > Certificate Assistant >
       Create a Certificate... Name it anything, Identity Type "Self Signed
       Root", Certificate Type "Code Signing", and let it create.

  Re-run this script afterwards; it now picks up ANY code-signing identity.
  Then remove Cochleagram from Privacy & Security > Microphone and grant once.

EOF
fi

echo
echo "--- signature as macOS sees it -------------------------------------"
codesign -dvv "$APP" 2>&1 | grep -E 'Identifier|Authority|Signature|TeamIdentifier' || true
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null || true
echo "--------------------------------------------------------------------"
echo

echo "Built $APP"
echo "Run it with:  open $APP"
