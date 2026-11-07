#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/tests/source-actions"
mkdir -p "$OUT/module-cache"
xcrun swiftc -swift-version 6 -default-isolation MainActor -warnings-as-errors -parse-as-library \
  -module-cache-path "$OUT/module-cache" \
  "$ROOT/Shared/AppInfo.swift" "$ROOT/Shared/NotificationFact.swift" "$ROOT/Shared/Sighting.swift" \
  "$ROOT/Shared/RecorderHealth.swift" "$ROOT/App/SourceActions.swift" "$ROOT/tests/SourceActionTests.swift" \
  -framework AppKit -o "$OUT/tests"
"$OUT/tests"
