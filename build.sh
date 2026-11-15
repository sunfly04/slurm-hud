#!/bin/zsh
# Build SlurmHUD.app and install it to ~/Applications.
#   ./build.sh            build for this Mac's architecture
#   ./build.sh run        build, install and launch
#   ./build.sh universal  build an arm64 + x86_64 binary (also writes build/SlurmHUD.zip)
# The bundle is assembled and signed in $TMPDIR: folders synced by iCloud/File Provider
# add Finder xattrs that make codesign refuse the bundle.
set -euo pipefail
cd "${0:A:h}"

MODE="${1:-}"
STAGE="${TMPDIR:-/tmp}/slurmhud-build"
APP="$STAGE/SlurmHUD.app"
DEST="$HOME/Applications/SlurmHUD.app"
ARCHS=("$(uname -m)")
[[ "$MODE" == "universal" ]] && ARCHS=(arm64 x86_64)

rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
bins=()
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos13.0" \
    Sources/main.swift -o "$STAGE/SlurmHUD-$arch"
  bins+=("$STAGE/SlurmHUD-$arch")
done
lipo -create $bins -output "$APP/Contents/MacOS/SlurmHUD"
xattr -cr "$APP"
codesign --force --sign - "$APP"

pkill -x SlurmHUD 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "installed $DEST ($(lipo -archs "$DEST/Contents/MacOS/SlurmHUD"))"

if [[ "$MODE" == "universal" ]]; then
  mkdir -p build
  ditto -c -k --keepParent "$APP" build/SlurmHUD.zip
  echo "wrote build/SlurmHUD.zip"
fi
[[ "$MODE" == "run" ]] && open "$DEST"
exit 0
