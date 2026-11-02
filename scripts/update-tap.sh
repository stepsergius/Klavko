#!/bin/bash
# After a release is published: points the Homebrew cask (github.com/stepsergius/homebrew-klavko)
# at it — the version and the checksum of the zip GitHub serves — and pushes the change.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/Klavko.zip" "https://github.com/stepsergius/Klavko/releases/download/v$VERSION/Klavko-$VERSION.zip"
SHA="$(shasum -a 256 "$WORK/Klavko.zip" | cut -d' ' -f1)"

gh repo clone stepsergius/homebrew-klavko "$WORK/tap" -- -q
CASK="$WORK/tap/Casks/klavko.rb"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
ruby -c "$CASK" > /dev/null

cd "$WORK/tap"
if git diff --quiet; then
    echo "The cask already points at $VERSION"
    exit 0
fi
git -c user.name=stepsergius -c user.email=248878916+stepsergius@users.noreply.github.com \
    commit -qam "Klavko $VERSION" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -q
echo "The cask points at Klavko $VERSION ($SHA)"
