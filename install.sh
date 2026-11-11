#!/bin/bash
# Builds Polka in Release and installs it as /Applications/Polka.app, the copy
# that the Desktop alias and Open at Login launch. Xcode builds never touch it,
# so run this whenever the daily copy should catch up:
#
#   ./install.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
app="/Applications/Polka.app"
built="$repo/Polka/build/Build/Products/Release/Polka.app"

# Build first, so a failed build leaves the running copy alone.
echo "Building Release..."
xcodebuild -project "$repo/Polka/Polka.xcodeproj" -scheme Polka -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$repo/Polka/build" build -quiet

# Quit every running Polka, installed or a Debug build. The shelf is saved after
# every change, so nothing is lost.
if pgrep -x Polka >/dev/null; then
    echo "Quitting Polka..."
    pkill -x Polka
    for _ in {1..50}; do
        pgrep -x Polka >/dev/null || break
        sleep 0.1
    done
    pkill -9 -x Polka 2>/dev/null || true
fi

echo "Installing to $app..."
rm -rf "$app"
ditto "$built" "$app"

open "$app"
echo "Installed $(git -C "$repo" describe --tags --always --dirty) and launched it."
