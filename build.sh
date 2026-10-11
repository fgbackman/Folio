#!/bin/bash
# Builds Folio.app with the Xcode command line tools — no Xcode project needed.
#
#   ./build.sh            build build/Folio.app (and build/rdtool)
#   ./build.sh --run      build, then launch
#   ./build.sh --install  build, then copy to /Applications
#
# Signing: ad-hoc by default. To sign with your Developer ID:
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"
APP="build/Folio.app"
OBJ="build/obj"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the command line tools with:  xcode-select --install" >&2
  exit 1
fi

rm -rf "$APP" "$OBJ"
mkdir -p "$OBJ" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "› Compiling C engine"
ENGINE=(util zip markup epub text book search sky skydata skydata2)
for f in "${ENGINE[@]}"; do
  xcrun clang -c -O2 -std=gnu11 -Wall -Wextra -Wno-unused-parameter -target "$TARGET" \
    -o "$OBJ/$f.o" "core/$f.c"
done

echo "› Building rdtool (command-line reader for testing)"
xcrun clang -O2 -std=gnu11 -target "$TARGET" -o build/rdtool core/rdtool.c "$OBJ"/*.o -lz

echo "› Compiling SwiftUI app"
xcrun swiftc -O -swift-version 5 -target "$TARGET" -parse-as-library \
  -import-objc-header App/Folio-Bridging-Header.h \
  App/*.swift "$OBJ"/*.o -lz \
  -o "$APP/Contents/MacOS/Folio"

echo "› Assembling bundle"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "› Signing"
codesign --force --deep --options runtime --sign "${SIGN_ID:--}" "$APP" >/dev/null

echo "✓ Built $APP"

case "${1:-}" in
  --run) open "$APP" ;;
  --install)
    rm -rf /Applications/Folio.app
    cp -R "$APP" /Applications/
    echo "✓ Installed to /Applications/Folio.app"
    open /Applications/Folio.app ;;
esac
