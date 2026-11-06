#!/usr/bin/env python3
"""Generate the WasThat app-icon SVGs (master + layers) for variants A, B, C.

Pure stdlib. Writes into ../variant-X/ relative to this file.

Master SVG: 1024x1024 canvas, classic macOS grid: 824x824 body at (100,100),
corner radius 185, soft drop shadow, artwork clipped to the body.

Layer SVGs (Icon Composer convention): 1024x1024 canvas = the icon shape
itself, no margin, no mask, no shadow. Background is full-bleed; foreground
layers are scaled by 1024/824 about the centre so they keep the same
proportions relative to the icon shape as in the master.
"""

import math
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

CANVAS = 1024
BODY_X = BODY_Y = 100
BODY = 824
BODY_R = 185
LAYER_SCALE = CANVAS / BODY  # 1.2427...


def f(v):
    """Compact number formatting."""
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s == "-0" else s


# ---------------------------------------------------------------------------
# Question-mark glyph
# ---------------------------------------------------------------------------
# Drawn in a unit box ~104.5 tall, centred on (0,0). The hook is a single
# stroked path with round caps; the dot is a circle. Everything is built from
# these two primitives so we can outline / shade them easily.
Q_SW = 18.0           # stroke width in glyph units
Q_HOOK_R = 21.0       # hook radius
Q_HOOK_CY = -22.0     # hook centre y
Q_DOT_CY = 41.0
Q_DOT_R = 11.5
Q_TOP = Q_HOOK_CY - Q_HOOK_R - Q_SW / 2      # -52
Q_BOTTOM = Q_DOT_CY + Q_DOT_R                 # 52.5
Q_HEIGHT = Q_BOTTOM - Q_TOP                   # 104.5
Q_MID = (Q_TOP + Q_BOTTOM) / 2


# Hook centre-line: a near-circular arc over the top (cubic quarter circles,
# k = 0.5523 r), then one smooth S-curve into a short vertical stem. Tangents
# are continuous at every joint, so the stroked outline has no kinks.
_k = 0.5523 * Q_HOOK_R
_R, _C = Q_HOOK_R, Q_HOOK_CY
Q_HOOK_D = (
    f"M{f(-_R)},{f(_C + 3)} "
    f"C{f(-_R)},{f(_C - _k)} {f(-_k)},{f(_C - _R)} 0,{f(_C - _R)} "
    f"C{f(_k)},{f(_C - _R)} {f(_R)},{f(_C - _k)} {f(_R)},{f(_C)} "
    f"C{f(_R)},{f(_C + 11)} 13,{f(_C + 16)} 7,{f(_C + 20)} "
    f"C1.75,{f(_C + 23.5)} 0,{f(_C + 26)} 0,{f(_C + 31)} "
    f"L0,{f(_C + 36)}"
)


def q_transform(cx, cy, height, rotate=0.0):
    """Transform placing the glyph with its bbox centre at (cx,cy)."""
    s = height / Q_HEIGHT
    rot = f" rotate({f(rotate)})" if rotate else ""
    return f"translate({f(cx)} {f(cy)}){rot} scale({f(s)}) translate(0 {f(-Q_MID)})"


def q_shapes(color, dot_color=None, extra=0.0, dot_extra=None):
    """Hook + dot in glyph units. `extra` grows both (for outlines)."""
    dot_color = dot_color or color
    de = extra if dot_extra is None else dot_extra
    return (f'<path d="{Q_HOOK_D}" fill="none" stroke="{color}" stroke-width="{f(Q_SW + 2 * extra)}" '
            f'stroke-linecap="round" stroke-linejoin="round"/>'
            f'<circle cx="0" cy="{f(Q_DOT_CY)}" r="{f(Q_DOT_R + de)}" fill="{dot_color}"/>')


def qmark(cx, cy, height, color, dot_color=None, rotate=0.0, outline=None, outline_px=0.0,
          shade=None, shade_offset=(2.2, 2.6), uid="q"):
    """Full question mark group in canvas coords.

    outline: ink colour drawn behind (outline_px thick, in canvas px).
    shade:   cel-shade colour; drawn as a crescent on the lower-right edges.
    """
    s = height / Q_HEIGHT
    parts = []
    defs = ""
    if outline:
        o = outline_px / s
        parts.append(q_shapes(outline, extra=o))
    if shade:
        # base in shade colour, then the main colour shifted up-left, masked
        # to the glyph shape => a flat crescent of shade on the far side.
        dx, dy = shade_offset
        defs = (f'<mask id="{uid}-m" maskUnits="userSpaceOnUse" x="-80" y="-80" width="160" height="160">'
                f'{q_shapes("#fff")}</mask>')
        parts.append(q_shapes(shade))
        parts.append(f'<g mask="url(#{uid}-m)"><g transform="translate({f(-dx)} {f(-dy)})">'
                     f'{q_shapes(color, dot_color)}</g></g>')
    else:
        parts.append(q_shapes(color, dot_color))
    return defs, f'<g transform="{q_transform(cx, cy, height, rotate)}">{"".join(parts)}</g>'


def q_center_for_dot(dot_x, dot_y, height, rotate=0.0):
    """Glyph centre that puts the (rotated) dot centre at (dot_x, dot_y)."""
    s = height / Q_HEIGHT
    d = (Q_DOT_CY - Q_MID) * s
    a = math.radians(rotate)
    # rotate (0, d) by a  (SVG rotate is clockwise on screen)
    return dot_x + d * math.sin(a), dot_y - d * math.cos(a)


def q_dot_radius(height):
    return Q_DOT_R * height / Q_HEIGHT


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def speaker(cx, cy, scale, color):
    """Tiny speaker-with-sound-waves glyph (about 110 x 80 at scale 1)."""
    return (f'<g transform="translate({f(cx)} {f(cy)}) scale({f(scale)})" fill="none" stroke="{color}" '
            f'stroke-linecap="round" stroke-linejoin="round">'
            f'<path d="M-46,-14 H-30 L-6,-34 V34 L-30,14 H-46 Z" fill="{color}" stroke-width="8"/>'
            f'<path d="M12,-16 Q24,0 12,16" stroke-width="10"/>'
            f'<path d="M28,-30 Q50,0 28,30" stroke-width="10"/></g>')


def F(color):
    return f'fill="{color}"'


def rrect(x, y, w, h, r, extra=""):
    return f'<rect x="{f(x)}" y="{f(y)}" width="{f(w)}" height="{f(h)}" rx="{f(r)}" {extra}/>'


def shadow_filter(fid, dy, std, opacity, color="#000", pad=40):
    return (f'<filter id="{fid}" x="-{pad}%" y="-{pad}%" width="{100 + 2 * pad}%" height="{100 + 2 * pad}%" '
            f'color-interpolation-filters="sRGB">'
            f'<feDropShadow dx="0" dy="{f(dy)}" stdDeviation="{f(std)}" flood-color="{color}" '
            f'flood-opacity="{f(opacity)}"/></filter>')


BODY_SHADOW = (
    '<filter id="body-shadow" x="-15%" y="-15%" width="130%" height="135%" color-interpolation-filters="sRGB">'
    '<feGaussianBlur in="SourceAlpha" stdDeviation="22" result="b1"/>'
    '<feOffset in="b1" dy="16" result="o1"/>'
    '<feComponentTransfer in="o1" result="s1"><feFuncA type="linear" slope="0.22"/></feComponentTransfer>'
    '<feGaussianBlur in="SourceAlpha" stdDeviation="5" result="b2"/>'
    '<feOffset in="b2" dy="5" result="o2"/>'
    '<feComponentTransfer in="o2" result="s2"><feFuncA type="linear" slope="0.18"/></feComponentTransfer>'
    '<feMerge><feMergeNode in="s1"/><feMergeNode in="s2"/><feMergeNode in="SourceGraphic"/></feMerge>'
    '</filter>'
)


# ---------------------------------------------------------------------------
# Variant A: "Badge"  (native, glossy, blue)
# A white notification banner; a big coral badge overlapping its top-right
# corner carries the question mark.
# ---------------------------------------------------------------------------
def variant_a():
    bx, by, bw, bh, br = 138, 556, 590, 250, 64
    bcx, bcy, brad = 664, 442, 198           # badge
    ring = 22                                 # knock-out ring width

    defs = f"""
<linearGradient id="a-bg" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#6AD6FF"/><stop offset="1" stop-color="#2E6CF6"/>
</linearGradient>
<linearGradient id="a-bg-user" gradientUnits="userSpaceOnUse" x1="0" y1="{BODY_Y}" x2="0" y2="{BODY_Y + BODY}">
  <stop offset="0" stop-color="#6AD6FF"/><stop offset="1" stop-color="#2E6CF6"/>
</linearGradient>
<radialGradient id="a-glow" cx="0.3" cy="0.12" r="0.75">
  <stop offset="0" stop-color="#fff" stop-opacity="0.35"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>
</radialGradient>
<linearGradient id="a-card" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E9F0FB"/>
</linearGradient>
<linearGradient id="a-app" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#8FDCFF"/><stop offset="1" stop-color="#4C8DF8"/>
</linearGradient>
<linearGradient id="a-badge" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#FF7A66"/><stop offset="1" stop-color="#F0323C"/>
</linearGradient>
{shadow_filter("a-sh", 10, 14, 0.22)}
{shadow_filter("a-qsh", 4, 5, 0.18, "#8A0E16")}
"""
    bg_paint = "url(#a-bg)"
    bg_extra = rrect(BODY_X, BODY_Y, BODY, BODY, BODY_R, 'fill="url(#a-glow)"')
    bg_full_extra = '<rect x="0" y="0" width="1024" height="1024" fill="url(#a-glow)"/>'

    # banner card + its content (app tile + two text lines)
    pad = 46
    tile = 128
    tx, ty = bx + pad, by + (bh - tile) / 2
    lx = tx + tile + 40
    main = (
        f'<g filter="url(#a-sh)">{rrect(bx, by, bw, bh, br, F("url(#a-card)"))}</g>'
        f'{rrect(tx, ty, tile, tile, 34, F("url(#a-app)"))}'
        f'{speaker(tx + tile / 2, ty + tile / 2, 0.84, "#FFFFFF")}'
        f'{rrect(lx, by + 78, 190, 34, 17, F("#B9C6D8"))}'
        f'{rrect(lx, by + 138, 300, 34, 17, F("#D5DEEA"))}'
    )

    qdefs, q = qmark(bcx, bcy + 4, 284, "#FFFFFF")
    qlayer = (
        f'<circle cx="{bcx}" cy="{bcy}" r="{brad + ring}" fill="url(#a-bg-user)"/>'
        f'<g filter="url(#a-sh)"><circle cx="{bcx}" cy="{bcy}" r="{brad}" fill="url(#a-badge)"/></g>'
        f'<g filter="url(#a-qsh)">{q}</g>'
    )
    return dict(defs=defs + qdefs, bg_paint=bg_paint, bg_extra=bg_extra, bg_full_extra=bg_full_extra,
                main=main, q=qlayer, over="")


# ---------------------------------------------------------------------------
# Variant B: "Perch"  (cute, soft, sunny)
# A friendly banner with a little surprised face; a chubby red question mark
# perches on its corner with a curious head-tilt, and its dot IS the banner's
# notification badge.
# ---------------------------------------------------------------------------
def variant_b():
    bx, by, bw, bh, br = 178, 598, 596, 232, 74
    qh, qrot = 486, -9
    dot_x, dot_y = bx + bw - 34, by + 18
    qcx, qcy = q_center_for_dot(dot_x, dot_y, qh, qrot)

    defs = f"""
<linearGradient id="b-bg" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#FFE98A"/><stop offset="1" stop-color="#FFB443"/>
</linearGradient>
<radialGradient id="b-glow" cx="0.28" cy="0.1" r="0.8">
  <stop offset="0" stop-color="#fff" stop-opacity="0.45"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>
</radialGradient>
<linearGradient id="b-card" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#FFF1DE"/>
</linearGradient>
<linearGradient id="b-q" gradientUnits="userSpaceOnUse" x1="0" y1="-52" x2="0" y2="52">
  <stop offset="0" stop-color="#FF7466"/><stop offset="1" stop-color="#EC3A48"/>
</linearGradient>
{shadow_filter("b-sh", 12, 16, 0.20, "#B35A00")}
{shadow_filter("b-qsh", 10, 12, 0.22, "#B33A00")}
"""
    bg_paint = "url(#b-bg)"
    bg_extra = rrect(BODY_X, BODY_Y, BODY, BODY, BODY_R, 'fill="url(#b-glow)"')
    bg_full_extra = '<rect x="0" y="0" width="1024" height="1024" fill="url(#b-glow)"/>'

    # face: centred in the left part of the banner; glints up-right so the
    # eyes seem to glance at the question mark
    fx = bx + bw * 0.43
    fy = by + bh * 0.47
    ink = "#3B2F4A"
    eye = lambda x: (f'<ellipse cx="{f(x)}" cy="{f(fy - 8)}" rx="25" ry="31" fill="{ink}"/>'
                     f'<circle cx="{f(x + 8)}" cy="{f(fy - 19)}" r="9.5" fill="#fff"/>'
                     f'<circle cx="{f(x - 8)}" cy="{f(fy + 5)}" r="4.5" fill="#fff" opacity="0.85"/>')
    face = (
        eye(fx - 76) + eye(fx + 76)
        + f'<ellipse cx="{f(fx - 134)}" cy="{f(fy + 42)}" rx="32" ry="18" fill="#FFAEA4" opacity="0.85"/>'
        + f'<ellipse cx="{f(fx + 134)}" cy="{f(fy + 42)}" rx="32" ry="18" fill="#FFAEA4" opacity="0.85"/>'
        + f'<ellipse cx="{f(fx)}" cy="{f(fy + 46)}" rx="15" ry="18" fill="{ink}"/>'
    )
    main = (f'<g filter="url(#b-sh)">{rrect(bx, by, bw, bh, br, F("url(#b-card)"))}</g>'
            + face)

    qdefs, q = qmark(qcx, qcy, qh, "url(#b-q)", rotate=qrot)
    qlayer = f'<g filter="url(#b-qsh)">{q}</g>'
    return dict(defs=defs + qdefs, bg_paint=bg_paint, bg_extra=bg_extra, bg_full_extra=bg_full_extra,
                main=main, q=qlayer, over="")


# ---------------------------------------------------------------------------
# Variant C: "Comic"  (thick ink outlines, flat cel-shaded colours)
# The notification is drawn as a comic speech balloon that just went "ding!":
# a yellow badge-light on its corner with action lines, and a big red question
# mark as its only content.
# ---------------------------------------------------------------------------
def balloon_path(x0, y0, x1, y1, r, xa, xb, tx, ty):
    """Rounded rect with a speech tail on the bottom edge (xa < xb), tip (tx,ty)."""
    return (f"M{f(x0 + r)},{f(y0)} H{f(x1 - r)} A{f(r)},{f(r)} 0 0 1 {f(x1)},{f(y0 + r)} "
            f"V{f(y1 - r)} A{f(r)},{f(r)} 0 0 1 {f(x1 - r)},{f(y1)} H{f(xb)} "
            f"C{f(xb - 34)},{f(y1 + 58)} {f(tx + 70)},{f(ty - 10)} {f(tx)},{f(ty)} "
            f"C{f(tx + 40)},{f(ty - 40)} {f(xa + 8)},{f(y1 + 50)} {f(xa)},{f(y1)} "
            f"H{f(x0 + r)} A{f(r)},{f(r)} 0 0 1 {f(x0)},{f(y1 - r)} V{f(y0 + r)} "
            f"A{f(r)},{f(r)} 0 0 1 {f(x0 + r)},{f(y0)} Z")


def variant_c():
    ink = "#241B35"
    inkw = 22
    dx, dy = -14, 30          # optical centring of the whole group
    x0, y0, x1, y1, R = 172 + dx, 228 + dy, 758 + dx, 708 + dy, 126
    bal = balloon_path(x0, y0, x1, y1, R, 312 + dx, 430 + dx, 214 + dx, 834 + dy)

    defs = f"""
<pattern id="c-dots" patternUnits="userSpaceOnUse" width="36" height="36" patternTransform="rotate(45)">
  <circle cx="18" cy="18" r="7" fill="#FFFFFF" fill-opacity="0.15"/>
</pattern>
<radialGradient id="c-dotfade" cx="0.12" cy="0.08" r="0.75">
  <stop offset="0" stop-color="#fff" stop-opacity="1"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>
</radialGradient>
<mask id="c-dotmask" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
  <rect x="0" y="0" width="1024" height="1024" fill="url(#c-dotfade)"/>
</mask>
<clipPath id="c-balclip"><path d="{bal}"/></clipPath>
"""
    bg_paint = "#7C5CFA"
    shade_band = '<path d="M100,705 C320,800 660,800 924,650 L924,924 L100,924 Z" fill="#6544E8"/>'
    dots = '<rect x="0" y="0" width="1024" height="1024" fill="url(#c-dots)" mask="url(#c-dotmask)"/>'
    bg_extra = shade_band + dots
    bg_full_extra = (f'<g transform="translate(512 512) scale({f(LAYER_SCALE)}) translate(-512 -512)">'
                     f'{shade_band}</g>{dots}')

    # balloon: flat offset shadow, cel-shaded fill, ink outline
    balloon = (
        f'<path d="{bal}" fill="{ink}" opacity="0.32" transform="translate(16 20)"/>'
        f'<path d="{bal}" fill="#F3D9AE"/>'
        f'<g clip-path="url(#c-balclip)"><path d="{bal}" fill="#FFF8EA" transform="translate(-16 -20)"/></g>'
        f'<path d="{bal}" fill="none" stroke="{ink}" stroke-width="{inkw}" stroke-linejoin="round"/>'
    )
    # badge on the balloon's top-right corner + "ding!" action lines
    bcx, bcy, brad = x1 - 30, y0 + 32, 78
    badge = (
        f'<circle cx="{f(bcx)}" cy="{f(bcy)}" r="{f(brad)}" fill="#F2A11D" stroke="{ink}" stroke-width="{inkw}"/>'
        f'<clipPath id="c-bclip"><circle cx="{f(bcx)}" cy="{f(bcy)}" r="{f(brad)}"/></clipPath>'
        f'<circle cx="{f(bcx - 10)}" cy="{f(bcy - 12)}" r="{f(brad)}" fill="#FFD23F" clip-path="url(#c-bclip)"/>'
        f'<circle cx="{f(bcx)}" cy="{f(bcy)}" r="{f(brad)}" fill="none" stroke="{ink}" stroke-width="{inkw}"/>'
        f'<ellipse cx="{f(bcx - 26)}" cy="{f(bcy - 30)}" rx="17" ry="12" fill="#fff" opacity="0.9" '
        f'transform="rotate(-35 {f(bcx - 26)} {f(bcy - 30)})"/>'
    )
    lines = ""
    for ang in (-80, -40, 0):
        a = math.radians(ang)
        r1, r2 = brad + 36, brad + 74
        lines += (f'<path d="M{f(bcx + r1 * math.cos(a))},{f(bcy + r1 * math.sin(a))} '
                  f'L{f(bcx + r2 * math.cos(a))},{f(bcy + r2 * math.sin(a))}" stroke="{ink}" '
                  f'stroke-width="22" stroke-linecap="round"/>')
    main = balloon + badge + lines

    qh, qrot = 388, 8
    qcx, qcy = (x0 + x1) / 2 - 6, (y0 + y1) / 2 + 6
    qdefs, q = qmark(qcx, qcy, qh, "#FF5A4E", rotate=qrot, outline=ink, outline_px=17,
                     shade="#D93A40", shade_offset=(-2.6, 3.0), uid="cq")
    _, qsh = qmark(qcx + 12, qcy + 15, qh, "#EBCF9F", rotate=qrot, outline="#EBCF9F", outline_px=17, uid="cqs")
    qlayer = qsh + q
    return dict(defs=defs + qdefs, bg_paint=bg_paint, bg_extra=bg_extra, bg_full_extra=bg_full_extra,
                main=main, q=qlayer, over="")


VARIANTS = {"A": ("badge", variant_a), "B": ("perch", variant_b), "C": ("comic", variant_c)}


# ---------------------------------------------------------------------------
# Writers
# ---------------------------------------------------------------------------
def svg_doc(defs, body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
            f'<title>{title}</title>\n<defs>{defs}</defs>\n{body}\n</svg>\n')


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def build(key):
    name, fn = VARIANTS[key]
    v = fn()
    out = os.path.join(ROOT, f"variant-{key}")
    clip = (f'<clipPath id="body-clip">{rrect(BODY_X, BODY_Y, BODY, BODY, BODY_R)}</clipPath>')
    master_body = (
        f'<g filter="url(#body-shadow)">{rrect(BODY_X, BODY_Y, BODY, BODY, BODY_R, F(v["bg_paint"]))}</g>\n'
        f'<g clip-path="url(#body-clip)">\n{v["bg_extra"]}\n{v["main"]}\n{v["q"]}\n</g>\n{v["over"]}'
    )
    write(os.path.join(out, f"WasThat-{key}.svg"),
          svg_doc(v["defs"] + BODY_SHADOW + clip, master_body, f"WasThat icon, variant {key} ({name})"))

    scale = f'transform="translate(512 512) scale({f(LAYER_SCALE)}) translate(-512 -512)"'
    layers = {
        "1-background": (f'<rect x="0" y="0" width="1024" height="1024" fill="{v["bg_paint"]}"/>'
                         f'{v["bg_full_extra"]}'),
        "2-notification": f'<g {scale}>{v["main"]}</g>',
        "3-question": f'<g {scale}>{v["q"]}</g>',
    }
    for lname, content in layers.items():
        # Icon Composer adds its own depth/shadow, so blur shadows are not baked
        # into layers (flat comic offset shadows are artwork and stay).
        content = re.sub(r' filter="url\(#[^)]*\)"', "", content)
        write(os.path.join(out, "layers", f"WasThat-{key}-{lname}.svg"),
              svg_doc(v["defs"], content, f"WasThat {key} layer {lname}"))
    return out


if __name__ == "__main__":
    import sys
    keys = sys.argv[1:] or list(VARIANTS)
    for k in keys:
        print("generated", build(k))
