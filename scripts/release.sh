#!/bin/bash
# Build, sign (Developer ID), notarize and staple WasThat, then package a notarized DMG.
#
# Usage:
#   scripts/release.sh                  full run: archive → export → verify → notarize app → DMG → notarize DMG
#   scripts/release.sh --skip-notarize  dry run: archive → export → verify only (no Apple upload)
#
# Requires: Xcode, xcodegen, the "Developer ID Application" certificate in the login keychain,
# and (for notarizing) a notarytool keychain profile. Default name: WasThat-notary
# (override with NOTARY_PROFILE). Create the profile once, interactively:
#   xcrun notarytool store-credentials WasThat-notary --apple-id <apple-id> --team-id L98358T6WZ
# Never put credentials in this repo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEAM_ID="L98358T6WZ"
SIGN_ID="Developer ID Application: IA COMPA LLC ($TEAM_ID)"
PROFILE="${NOTARY_PROFILE:-WasThat-notary}"
PUBLIC_VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\([^"*]*\)"/\1/p' project.yml | head -1)"
[[ "$PUBLIC_VERSION" =~ ^[1-9][0-9]*(\.[1-9])?$ ]] || { echo "Invalid public app version" >&2; exit 1; }
OUT="${RELEASE_OUTPUT_DIR:-$ROOT/build/releases/$PUBLIC_VERSION/$(date -u +%Y%m%dT%H%M%SZ)}"
ARCHIVE="$OUT/WasThat.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/WasThat.app"
AGENT="$APP/Contents/Library/LoginItems/WasThatAgent.app"
SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  step "Checking notary profile '$PROFILE'"
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || fail "No notarytool profile '$PROFILE'. The owner must run: xcrun notarytool store-credentials $PROFILE --apple-id <apple-id> --team-id $TEAM_ID"
fi

step "Generating project and archiving (Release, arm64 + x86_64)"
[[ ! -e "$OUT" ]] || fail "Output already exists; choose a new RELEASE_OUTPUT_DIR to preserve prior evidence"
mkdir -p "$OUT"
xcodegen generate --quiet
xcodebuild -project WasThat.xcodeproj -scheme WasThat -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" archive \
  > "$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; fail "archive failed (see $OUT/archive.log)"; }

step "Exporting with Developer ID"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" > "$OUT/export.log" 2>&1 \
  || { tail -30 "$OUT/export.log"; fail "export failed (see $OUT/export.log)"; }

step "Verifying signatures (both bundles)"
codesign --verify --deep --strict "$APP" || fail "codesign verify failed"
for b in "$APP" "$AGENT"; do
  info="$(codesign -dvv "$b" 2>&1)"
  grep -q "Authority=Developer ID Application" <<<"$info" || fail "$b not signed with Developer ID"
  grep -q "TeamIdentifier=$TEAM_ID" <<<"$info"             || fail "$b wrong team"
  grep -q "Timestamp="              <<<"$info"             || fail "$b has no secure timestamp"
  grep -Eq "flags=.*runtime"        <<<"$info"             || fail "$b missing hardened runtime"
  if codesign -d --entitlements - --xml "$b" 2>/dev/null | grep -q "get-task-allow"; then
    fail "$b has get-task-allow (debug entitlement) — notarization would reject it"
  fi
  echo "ok: $(basename "$b")"
done
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" == "$PUBLIC_VERSION" ]] || fail "Archived version differs from the requested public version"
echo "version $VERSION · archs: $(lipo -archs "$APP/Contents/MacOS/WasThat") · size: $(du -sh "$APP" | cut -f1)"

if [[ $SKIP_NOTARIZE -eq 1 ]]; then
  step "Dry run complete (notarization skipped)"; echo "$APP"; exit 0
fi

step "Notarizing the app"
ZIP="$OUT/WasThat-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait | tee "$OUT/notarize-app.log"
grep -q "status: Accepted" "$OUT/notarize-app.log" \
  || fail "app notarization not accepted. Details: xcrun notarytool log <submission-id> --keychain-profile $PROFILE"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -t exec -vv "$APP" 2>&1 | tee "$OUT/spctl-app.log"
grep -q "source=Notarized Developer ID" "$OUT/spctl-app.log" || fail "Gatekeeper did not accept the app"

step "Building DMG"
DMG="$OUT/WasThat-$VERSION.dmg"
STAGE="$OUT/dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/WasThat.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "WasThat" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"

step "Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait | tee "$OUT/notarize-dmg.log"
grep -q "status: Accepted" "$OUT/notarize-dmg.log" || fail "DMG notarization not accepted"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | tee "$OUT/spctl-dmg.log"
grep -q "accepted" "$OUT/spctl-dmg.log" || fail "Gatekeeper did not accept the DMG"

step "Done"
echo "App: $APP"
echo "DMG: $DMG  ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
