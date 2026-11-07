#!/bin/bash
# Run synthetic checks without launching the app, reading logs, or accessing personal data.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/wasthat-notification-privacy.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
swiftc -module-cache-path "$OUT/module-cache" -swift-version 5 -warnings-as-errors -parse-as-library \
  "$HERE/../NotificationLogSanitizer.swift" "$HERE/NotificationLogSanitizerTests.swift" \
  -o "$OUT/tests"
"$OUT/tests"
