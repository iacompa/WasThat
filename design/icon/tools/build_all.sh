#!/bin/bash
# Regenerate all WasThat icon SVGs, render the 1024 px PNGs and the contact sheet.
# Usage: tools/build_all.sh [A B C]   (default: all variants)
set -euo pipefail

TOOLS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$TOOLS")"
BUILD="$TOOLS/.build"
mkdir -p "$BUILD"

# Compile helpers only when their source is newer than the binary.
compile() {
  local src="$TOOLS/$1.swift" bin="$BUILD/$1"
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    echo "compiling $1 ..."
    swiftc -O "$src" -o "$bin"
  fi
}
compile render_svg
compile contact_sheet

VARIANTS=("$@")
[[ ${#VARIANTS[@]} -eq 0 ]] && VARIANTS=(A B C)

python3 "$TOOLS/gen_icons.py" "${VARIANTS[@]}"

jobs=()
for v in "${VARIANTS[@]}"; do
  d="$ROOT/variant-$v"
  jobs+=("$d/WasThat-$v.svg" "$d/WasThat-$v-1024.png" 1024)
  for layer in "$d"/layers/*.svg; do
    jobs+=("$layer" "$BUILD/preview-$(basename "${layer%.svg}").png" 512)
  done
done
"$BUILD/render_svg" "${jobs[@]}"

"$BUILD/contact_sheet" "$ROOT/contact-sheet.png" \
  "$ROOT/variant-A/WasThat-A-1024.png" "$ROOT/variant-B/WasThat-B-1024.png" "$ROOT/variant-C/WasThat-C-1024.png"
