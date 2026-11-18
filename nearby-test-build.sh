#!/bin/bash
# Nearby Sharing test build, for trying a step between two Macs before it's merged.
# Ad-hoc signed like a release, as "Polka Nearby Test" with its own bundle ID, so its
# shelf, settings and Keychain key are kept apart from the daily Polka's (Polka names
# its Application Support folder after the bundle ID). Quit the daily Polka while it
# runs, since both draw at the notch. Output: Polka/build/nearby-test/.
# Delete this script before the feature branch is merged into dev.
set -euo pipefail
cd "$(dirname "$0")/Polka"

OUT="$PWD/build/nearby-test"
DERIVED="$PWD/build/nearby-test-derived"
APP="Polka Nearby Test.app"
rm -rf "$OUT"
mkdir -p "$OUT"

xcodebuild -project Polka.xcodeproj -scheme Polka -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.maksimds.Polka.NearbyTest \
  INFOPLIST_KEY_CFBundleDisplayName="Polka Nearby Test" \
  build -quiet

ditto "$DERIVED/Build/Products/Release/Polka.app" "$OUT/$APP"
codesign -dv "$OUT/$APP" 2>&1 | grep -E "^Identifier|^Signature|^TeamIdentifier"
if codesign -d --entitlements - "$OUT/$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "get-task-allow is set; don't send this build" >&2
  exit 1
fi
plutil -extract NSBonjourServices raw -o - "$OUT/$APP/Contents/Info.plist" >/dev/null
lipo -archs "$OUT/$APP/Contents/MacOS/Polka"
(cd "$OUT" && ditto -c -k --keepParent "$APP" "Polka Nearby Test.zip")
echo "Built $OUT/Polka Nearby Test.zip"
