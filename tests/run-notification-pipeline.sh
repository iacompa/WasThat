#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build/test-cache"
OUT="$(mktemp -d "$ROOT/build/test-cache/notification-pipeline.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 6 -default-isolation MainActor -warnings-as-errors -parse-as-library \
  -module-cache-path "$OUT/module-cache" \
  "$ROOT/Shared/SoundEvent.swift" \
  "$ROOT/Shared/NotificationFact.swift" \
  "$ROOT/Shared/NotificationLogParser.swift" \
  "$ROOT/Shared/Sighting.swift" \
  "$ROOT/Shared/SoundCorrelator.swift" \
  "$ROOT/Agent/NotificationFeed.swift" \
  "$ROOT/tests/NotificationPipelineTests.swift" -o "$OUT/tests"
"$OUT/tests"
