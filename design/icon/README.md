# WasThat app icon

Three original variants. Each has a notification card (banner or balloon) plus a badge dot, and a friendly question mark nearby. All artwork is drawn from scratch: shapes and the question-mark glyph are hand-built paths, with no fonts, Apple artwork or game assets. `contact-sheet.png` shows all three at 1024, 128, 32 and 16 px on light and dark desktops, plus pixel-magnified 32/16 px views.

| | Variant | One line |
|---|---|---|
| A | **Badge** | Native macOS look: a white notification banner (speaker app tile, two text lines) on a sky-blue gradient, with a big coral badge holding a white "?" over its corner. |
| B | **Perch** | Cute and soft: a marshmallow-white banner with a little surprised face on a sunny yellow gradient. A chubby red "?" perches on its corner with a head-tilt, and its dot is the notification badge. |
| C | **Comic** | Nods to the app's cel-shaded comic UI: thick ink outlines, flat colours, halftone dots. The notification is a speech balloon on violet with a yellow "ding!" badge-light and action lines, and a big red "?" inside. |

## Recommendation: B (Perch)

- It matches the brief best: notification banner, badge dot and question mark, kept simple and cute. Making the "?" dot double as the notification badge is one idea, not two stacked elements, so the icon stays uncluttered.
- It is the most legible small: the "?" is the largest of the three (about 47% of the canvas height), red on yellow, with no outline noise. It reads clearly at 32 px, and at 16 px it is still a distinctive red mark on a yellow tile.
- It stands out in the Dock on both light and dark desktops, and doesn't look like a system utility or a chat app.

Choose **A** if you want the app to feel like a built-in system utility. It is the most "macOS", and its white "?" on a red disc is the crispest mark at 32 px. Choose **C** if you want the icon to match the comic UI. It is the boldest at 128 px and up, but the busiest at 16 px, and the speech balloon leans slightly toward "chat app".

`export/` holds a ready-made `AppIcon.icns`, `AppIcon.iconset/` and Xcode `AppIcon.appiconset/` built from **B**.

## Files

```
variant-X/WasThat-X.svg          master: 1024 canvas, 824 body at (100,100), r=185, soft drop shadow
variant-X/WasThat-X-1024.png     master rendered at 1024 px (sRGB, transparent corners)
variant-X/layers/*.svg           1-background, 2-notification, 3-question (see Icon Composer note)
contact-sheet.png                all variants, 1024/128/32/16 px, light + dark
make_icns.sh                     1024 PNG -> AppIcon.iconset, AppIcon.icns, AppIcon.appiconset
export/                          output of make_icns.sh for variant B
tools/gen_icons.py               generates every SVG (stdlib python3; all geometry and colours live here)
tools/render_svg.swift           SVG -> PNG via WebKit (full filter/mask support)
tools/contact_sheet.swift        builds contact-sheet.png
tools/build_all.sh               regenerate SVGs + PNGs + contact sheet (compiles the Swift tools into tools/.build/)
```

Rebuild everything after editing `gen_icons.py`:

```sh
tools/build_all.sh            # or: tools/build_all.sh B
./make_icns.sh variant-B/WasThat-B-1024.png        # -> export/
./make_icns.sh variant-A/WasThat-A-1024.png /some/other/dir
```

## Caveats

- **Renderer.** No rsvg-convert, ImageMagick or Inkscape is installed. NSImage's SVG loader silently drops filters (no drop shadow), so PNGs are rendered with WebKit (`WKWebView` snapshot at 2x, downsampled to the target size). Expect Safari-identical output; other renderers may differ slightly in blur softness.
- **Layer SVGs follow Icon Composer's convention, not the master grid.** The canvas is the icon shape: no 100 px margin, no mask, no shadow. The background is full-bleed, and the foreground layers are scaled by 1024/824 about the centre, so proportions relative to the shape match the master. Blur shadows are stripped because Icon Composer adds its own depth. C's flat offset shadows are artwork and stay. In A, the coloured ring around the badge (a "knock-out" gap) lives in the question layer and is painted with the background gradient. If you build a `.icon`, you may prefer to drop it and let Icon Composer's glass separate the layers. C's halftone uses an SVG pattern and mask; if Icon Composer won't import it, use a flat `#7C5CFA` fill.
- **Small sizes** are straight `sips` downscales of the 1024 master (checked: equivalent to progressive halving). At 16 px no variant shows a literal "?", only colour and silhouette. If that matters, hand-tune 16/32 px PNGs (bigger "?", no face or text lines) and drop them into the iconset before running `iconutil`.
- **Badge semantics.** Each icon contains a badge-like dot *inside* the artwork, not on the icon edge, so it shouldn't be mistaken for a real Dock badge. A real red Dock badge in the top-right corner will still sit near A's and B's red elements. That's worth a glance once it's in the Dock.
- The body is a plain rounded rect (r=185), not Apple's continuous-corner squircle. At icon sizes the difference is negligible, and macOS 26+ applies its own mask for `.icon` files anyway.
