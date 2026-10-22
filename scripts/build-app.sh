#!/bin/bash
# Builds build/Klavko.app (universal: Apple Silicon + Intel) and signs it.
# Signing with a stable certificate keeps the Accessibility permission across rebuilds;
# without one the app is signed ad hoc and the permission must be re-granted after each build.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
# Universal needs Xcode's build system; with Command Line Tools only, build for this Mac's architecture.
if [ -x /Library/Developer/SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild ] || xcodebuild -version >/dev/null 2>&1; then
    ARCHS=(--arch arm64 --arch x86_64)
else
    ARCHS=(--arch "$(uname -m)")
    echo "No Xcode: building for $(uname -m) only"
fi

swift build -c "$CONFIG" "${ARCHS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)"

APP="build/Klavko.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Klavko" "$APP/Contents/MacOS/Klavko"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Klavko's own sounds, offered after the macOS ones.
[ -d Resources/Sounds ] && cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"
# Resource bundles of dependencies (FluidAudio's), found by Bundle.module in Contents/Resources.
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

IDENTITY="${KLAVKO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application|Apple Development/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"
REQUIREMENTS=()
if [ "$IDENTITY" = "-" ]; then
    # Ad hoc signatures change with every build, and macOS ties the Accessibility permission to the
    # signature's requirement: name the app by its identifier, so an update keeps the permission.
    REQUIREMENTS=(--requirements '=designated => identifier "app.klavko.Klavko"')
fi
if ! codesign --force --options runtime --entitlements Resources/Klavko.entitlements ${REQUIREMENTS[@]+"${REQUIREMENTS[@]}"} \
    --sign "$IDENTITY" "$APP"; then
    [ "$IDENTITY" = "-" ] && exit 1
    # The certificate's key is out of reach (a locked keychain over SSH): sign ad hoc instead.
    echo "Signing with $IDENTITY failed; signing ad hoc"
    IDENTITY="-"
    codesign --force --options runtime --entitlements Resources/Klavko.entitlements \
        --requirements '=designated => identifier "app.klavko.Klavko"' --sign - "$APP"
fi

echo "Built $APP (signed with: $IDENTITY)"
