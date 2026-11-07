#!/bin/bash
# GPL-3.0. Build local acceptance fixtures. Do not launch them from this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/qa-sources"
MODULE_CACHE="${WASTHAT_FIXTURE_MODULE_CACHE:-/private/tmp/wasthat-fixture-module-cache-$UID}"
SIGN_ID="${WASTHAT_FIXTURE_SIGN_IDENTITY:-Developer ID Application: IA COMPA LLC (L98358T6WZ)}"
mkdir -p "$OUT" "$MODULE_CACHE"
ATTEMPT="$(mktemp -d "$OUT/build-attempt.XXXXXX")"
BINARY="$ATTEMPT/WasThatTestSource"
cp "$ROOT/tests/fixtures/SoundSourceApp.swift" "$ATTEMPT/SoundSourceApp.swift"
cp "$ROOT/tests/build-sound-sources.sh" "$ATTEMPT/build-sound-sources.sh"
if [[ -f "$OUT/manifest.json" ]]; then
  cp "$OUT/manifest.json" "$ATTEMPT/previous-manifest.json"
fi

# Preserve the host's normal TMPDIR. Only the module cache is explicitly external.
xcrun swiftc -swift-version 6 -default-isolation MainActor -warnings-as-errors -parse-as-library \
  -target arm64-apple-macos14.2 -module-cache-path "$MODULE_CACHE" \
  "$ATTEMPT/SoundSourceApp.swift" \
  -framework AppKit -framework AVFoundation -framework UserNotifications -o "$BINARY" \
  >"$ATTEMPT/compile.log" 2>&1 || { cat "$ATTEMPT/compile.log" >&2; exit 1; }

if IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>"$ATTEMPT/identity-query.stderr")"; then
  if [[ "$IDENTITIES" == *"$SIGN_ID"* ]]; then
    SIGN_MODE="Developer ID"
  else
    SIGN_MODE="ad hoc fixture only"
  fi
else
  SIGN_MODE="ad hoc fixture only"
fi
if [[ "$SIGN_MODE" == "ad hoc fixture only" ]]; then
  printf '%s\n' "Configured Developer ID identity unavailable. Using ad hoc fixture-only signatures."
fi

for VARIANT in alpha beta; do
  case "$VARIANT" in
    alpha) NAME="WasThat Test Alpha" ;;
    beta) NAME="WasThat Test Beta" ;;
  esac
  APP="$OUT/$NAME.app"
  if [[ -d "$APP" ]]; then
    mkdir -p "$ATTEMPT/previous-bundles"
    /usr/bin/ditto "$APP" "$ATTEMPT/previous-bundles/$NAME.app"
  fi
  mkdir -p "$APP/Contents/MacOS"
  cp "$BINARY" "$APP/Contents/MacOS/WasThatTestSource"
  cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.iacompa.wasthat.test.$VARIANT</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>WasThatTestSource</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
  /usr/bin/plutil -lint "$APP/Contents/Info.plist"
  if [[ "$SIGN_MODE" == "Developer ID" ]]; then
    /usr/bin/codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$APP"
  else
    /usr/bin/codesign --force --sign - --options runtime --timestamp=none "$APP"
  fi
  /usr/bin/codesign --verify --strict --verbose=2 "$APP"
  /usr/bin/codesign --display --verbose=4 "$APP" >"$ATTEMPT/$VARIANT-signature.txt" 2>&1
  /usr/bin/lipo -archs "$APP/Contents/MacOS/WasThatTestSource"
  printf '%s\n' "$APP"
done

python3 - "$OUT" "$ATTEMPT" "$SIGN_MODE" "$ATTEMPT/SoundSourceApp.swift" <<'PY'
from pathlib import Path
import hashlib, json, plistlib, subprocess, sys
out, attempt, mode, source = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
bundles = []
for name in ("WasThat Test Alpha", "WasThat Test Beta"):
    app = out / (name + ".app")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    binary = app / "Contents/MacOS/WasThatTestSource"
    architecture = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).strip()
    assert architecture == "arm64", architecture
    bundles.append({"path": str(app), "bundle_id": info["CFBundleIdentifier"],
                    "name": info["CFBundleDisplayName"], "architecture": architecture,
                    "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()})
assert {b["bundle_id"] for b in bundles} == {
    "com.iacompa.wasthat.test.alpha", "com.iacompa.wasthat.test.beta"}
manifest = {"signing": mode, "launched": False, "compile_log": str(attempt / "compile.log"),
            "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "build_script_sha256": hashlib.sha256((attempt / "build-sound-sources.sh").read_bytes()).hexdigest(),
            "cli_examples": ["--play-once --quit-after-test", "--play --quit-after-test", "--notify --quit-after-test"],
            "completion": "JSON lines; event=complete, outcome=success/failure; exit 0/1, invalid arguments exit 2",
            "bundles": bundles}
(attempt / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
(out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest, indent=2))
PY
