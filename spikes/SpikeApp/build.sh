#!/bin/bash
# Builds "WasThat Spike.app" with swiftc (no Xcode project needed) and signs it with
# Developer ID + hardened runtime, so permission prompts behave like the real app.
#   SIGN_ID       signing identity (default: the team's Developer ID Application cert)
#   ENTITLEMENTS  optional path to an entitlements plist
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/build"
APP="$OUT/WasThat Spike.app"
SIGN_ID="${SIGN_ID:-Developer ID Application: IA COMPA LLC (L98358T6WZ)}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos14.2 \
  "$HERE"/*.swift "$ROOT/App/DesignSystem/Comic.swift" -o "$APP/Contents/MacOS/WasThatSpike"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
ICNS="$ROOT/design/icon/export/AppIcon.icns"
[ -f "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

SIGN_ARGS=(--force --options runtime -s "$SIGN_ID")
[ -n "${ENTITLEMENTS:-}" ] && SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP" && echo "Built and signed: $APP"
