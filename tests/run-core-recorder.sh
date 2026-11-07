#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/tests/core-recorder"
mkdir -p "$OUT/tmp" "$OUT/module-cache"
swiftc -swift-version 6 -default-isolation MainActor -warnings-as-errors -parse-as-library \
  -module-cache-path "$OUT/module-cache" \
  "$ROOT/Shared/AppInfo.swift" "$ROOT/Shared/SoundEvent.swift" "$ROOT/Shared/EventStore.swift" \
  "$ROOT/Shared/NotificationFact.swift" "$ROOT/Shared/RecorderHealth.swift" "$ROOT/App/AgentManager.swift" "$ROOT/tests/CoreRecorderTests.swift" \
  -framework AppKit -framework ServiceManagement -lsqlite3 -o "$OUT/tests"
"$OUT/tests"
