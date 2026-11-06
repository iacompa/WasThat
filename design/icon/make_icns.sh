#!/bin/bash
# make_icns.sh: build a macOS app icon from a single 1024x1024 PNG.
#
#   ./make_icns.sh <icon-1024.png> [output-dir]
#
# Produces, in output-dir (default: ./export next to this script):
#   AppIcon.iconset/      the 10 standard PNGs (16..512 @1x/@2x), made with sips
#   AppIcon.icns          built from the iconset with iconutil
#   AppIcon.appiconset/   same PNGs plus Contents.json, ready to drop into an
#                         Xcode asset catalog (Assets.xcassets/AppIcon.appiconset)
#
# The 1024 PNG should already contain the macOS icon grid (824 px body, 100 px
# margin, shadow, transparent corners). Only the AppIcon.* outputs inside
# output-dir are replaced; nothing else is touched.
set -euo pipefail

usage() { echo "usage: $0 <icon-1024.png> [output-dir]" >&2; exit 2; }
[[ $# -ge 1 && $# -le 2 ]] || usage

src="$1"
out="${2:-"$(cd "$(dirname "$0")" && pwd)/export"}"
[[ -f "$src" ]] || { echo "error: '$src' not found" >&2; exit 1; }
for tool in sips iconutil; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found (macOS only)" >&2; exit 1; }
done

# --- validate the master ---------------------------------------------------
w=$(sips -g pixelWidth  "$src" | awk '/pixelWidth/  {print $2}')
h=$(sips -g pixelHeight "$src" | awk '/pixelHeight/ {print $2}')
alpha=$(sips -g hasAlpha "$src" | awk '/hasAlpha/ {print $2}')
if ! [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]]; then
  echo "error: '$src' is not a readable image" >&2; exit 1
fi
if [[ "$w" != 1024 || "$h" != 1024 ]]; then
  echo "error: '$src' is ${w}x${h}; a 1024x1024 PNG is required" >&2; exit 1
fi
[[ "$alpha" == yes ]] || echo "warning: '$src' has no alpha channel; corners will not be transparent" >&2

iconset="$out/AppIcon.iconset"
appiconset="$out/AppIcon.appiconset"
icns="$out/AppIcon.icns"
mkdir -p "$out"
rm -rf "$iconset" "$appiconset" "$icns"
mkdir -p "$iconset" "$appiconset"

# --- render the 10 sizes ---------------------------------------------------
# point size, scale  ->  filename icon_<pt>x<pt>[@2x].png at pt*scale pixels
specs=(16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2)
json_entries=()
for spec in "${specs[@]}"; do
  pt=${spec%%:*}; scale=${spec##*:}
  px=$((pt * scale))
  suffix=""; [[ $scale == 2 ]] && suffix="@2x"
  name="icon_${pt}x${pt}${suffix}.png"
  if [[ $px == 1024 ]]; then
    cp "$src" "$iconset/$name"
  else
    sips -z "$px" "$px" "$src" --out "$iconset/$name" >/dev/null
  fi
  cp "$iconset/$name" "$appiconset/$name"
  json_entries+=("    {
      \"filename\" : \"$name\",
      \"idiom\" : \"mac\",
      \"scale\" : \"${scale}x\",
      \"size\" : \"${pt}x${pt}\"
    }")
  printf '  %-22s %4d px\n' "$name" "$px"
done

# --- Contents.json for the Xcode asset catalog -----------------------------
{
  echo "{"
  echo "  \"images\" : ["
  for i in "${!json_entries[@]}"; do
    sep=","; [[ $i -eq $((${#json_entries[@]} - 1)) ]] && sep=""
    echo "${json_entries[$i]}$sep"
  done
  echo "  ],"
  echo "  \"info\" : {"
  echo "    \"author\" : \"xcode\","
  echo "    \"version\" : 1"
  echo "  }"
  echo "}"
} > "$appiconset/Contents.json"

# --- .icns -------------------------------------------------------------------
iconutil -c icns "$iconset" -o "$icns"

echo "wrote $icns ($(stat -f%z "$icns") bytes)"
echo "wrote $iconset/ (10 PNGs)"
echo "wrote $appiconset/ (10 PNGs + Contents.json)"
