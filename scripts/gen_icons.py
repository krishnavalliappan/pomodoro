#!/usr/bin/env python3
"""Regenerates the app icon and the menu bar template glyph in App/Resources/Assets.xcassets.

Stdlib only and deterministic: every shape is a signed distance field, and each pixel's
coverage comes from its distance to the edge, so each size is drawn from the geometry instead
of being downscaled. Geometry is in a 1024-unit space following the macOS (Big Sur+) icon
grid: an 824-unit rounded square centred on the canvas, with room for the drop shadow.

    python3 scripts/gen_icons.py
"""

import json
import math
import os
import struct
import zlib

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CATALOG = os.path.join(ROOT, "App", "Resources", "Assets.xcassets")

# --- PNG -------------------------------------------------------------------------------------


def write_png(path, size, pixels):
    """pixels: flat list of (r, g, b, a) floats in 0...1, straight alpha, row-major."""
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        for x in range(size):
            r, g, b, a = pixels[y * size + x]
            raw += bytes(max(0, min(255, round(c * 255))) for c in (r, g, b, a))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


# --- Signed distance fields (negative inside) ------------------------------------------------


def rounded_rect(px, py, cx, cy, half, radius):
    qx = abs(px - cx) - half + radius
    qy = abs(py - cy) - half + radius
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    return outside + min(max(qx, qy), 0.0) - radius


def ellipse(px, py, cx, cy, rx, ry):
    # First-order approximation; exact enough at the edge for anti-aliasing mild ellipses.
    dx, dy = (px - cx) / rx, (py - cy) / ry
    k = math.hypot(dx, dy)
    if k == 0:
        return -min(rx, ry)
    k1 = math.hypot(dx / rx, dy / ry)
    return k * (k - 1.0) / k1


def rotated(px, py, cx, cy, angle):
    s, c = math.sin(angle), math.cos(angle)
    dx, dy = px - cx, py - cy
    return cx + dx * c + dy * s, cy - dx * s + dy * c


def capsule(px, py, ax, ay, bx, by, r):
    vx, vy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy)))
    return math.hypot(px - ax - vx * t, py - ay - vy * t) - r


def arc(px, py, cx, cy, radius, width, start, sweep):
    """Ring segment with round caps; angles in radians, clockwise from 12 o'clock."""
    dx, dy = px - cx, py - cy
    angle = math.atan2(dx, -dy) % (2 * math.pi)
    if (angle - start) % (2 * math.pi) <= sweep:
        return abs(math.hypot(dx, dy) - radius) - width
    ends = []
    for a in (start, start + sweep):
        ex, ey = cx + radius * math.sin(a), cy - radius * math.cos(a)
        ends.append(math.hypot(px - ex, py - ey) - width)
    return min(ends)


def leaf(px, py, bx, by, angle, length, width):
    """A pointed leaf rooted at (bx, by), pointing along `angle` (0 = up, clockwise)."""
    lx, ly = rotated(px, py, bx, by, angle)
    # Intersection of two offset circles gives a lens with sharp tips at both ends.
    half = length / 2
    r = (half * half + width * width) / (2 * width)
    cy = by - half
    d1 = math.hypot(lx - (bx + r - width), ly - cy) - r
    d2 = math.hypot(lx - (bx - r + width), ly - cy) - r
    return max(d1, d2)


def coverage(d, px_size):
    return max(0.0, min(1.0, 0.5 - d / px_size))


def smoothstep(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def mix(a, b, t):
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def over(dst, rgb, alpha):
    """Composites straight-alpha `rgb` at `alpha` over a straight-alpha dst."""
    r, g, b, a = dst
    out_a = alpha + a * (1 - alpha)
    if out_a == 0:
        return (0.0, 0.0, 0.0, 0.0)
    k = a * (1 - alpha)
    return (
        (rgb[0] * alpha + r * k) / out_a,
        (rgb[1] * alpha + g * k) / out_a,
        (rgb[2] * alpha + b * k) / out_a,
        out_a,
    )


def hex_rgb(value):
    return tuple(int(value[i : i + 2], 16) / 255 for i in (1, 3, 5))


# --- App icon --------------------------------------------------------------------------------

BG_TOP, BG_BOTTOM = hex_rgb("#FFF4E8"), hex_rgb("#F6D9C4")
TOMATO_LIGHT, TOMATO, TOMATO_DARK = hex_rgb("#FF7A5C"), hex_rgb("#F2442E"), hex_rgb("#B8231A")
LEAF_LIGHT, LEAF_DARK = hex_rgb("#5FBF4A"), hex_rgb("#2F8A35")
TRACK = hex_rgb("#FFFFFF")

TILE_HALF, TILE_RADIUS = 412.0, 185.0
BODY = (512.0, 560.0, 268.0, 248.0)  # cx, cy, rx, ry
CALYX = (512.0, 330.0)
ARC_R, ARC_W = 196.0, 22.0
LEAVES = [(0.0, 120, 30), (1.2, 150, 34), (-1.2, 150, 34), (2.35, 120, 30), (-2.35, 120, 30)]


def icon_pixel(x, y, px):
    out = (0.0, 0.0, 0.0, 0.0)

    # Drop shadow per the macOS grid: soft, offset down, inside the 1024 canvas.
    d_shadow = rounded_rect(x, y - 12, 512, 512, TILE_HALF, TILE_RADIUS)
    shadow = 0.28 * (1 - smoothstep(-8, 28, d_shadow))
    if shadow > 0:
        out = over(out, (0.25, 0.1, 0.05), shadow)

    d_tile = rounded_rect(x, y, 512, 512, TILE_HALF, TILE_RADIUS)
    a = coverage(d_tile, px)
    if a <= 0:
        return out
    tile = mix(BG_TOP, BG_BOTTOM, smoothstep(100, 924, y))
    out = over(out, tile, a)

    cx, cy, rx, ry = BODY
    # Contact shadow under the tomato.
    d_floor = ellipse(x, y, cx, cy + 236, 210, 34)
    out = over(out, (0.55, 0.25, 0.15), 0.22 * (1 - smoothstep(-30, 30, d_floor)) * a)

    d_body = ellipse(x, y, cx, cy, rx, ry)
    body_a = coverage(d_body, px) * a
    if body_a > 0:
        # Light from the upper left: radial ramp from a highlight point, darkened at the rim.
        t = math.hypot(x - (cx - 110), y - (cy - 120)) / 420
        colour = mix(TOMATO_LIGHT, TOMATO, smoothstep(0.0, 0.55, t))
        colour = mix(colour, TOMATO_DARK, smoothstep(0.55, 1.15, t))
        out = over(out, colour, body_a)

        # Timer arc: a faint full track, then three quarters remaining.
        d_track = arc(x, y, cx, cy + 4, ARC_R, ARC_W, 0, 2 * math.pi - 1e-6)
        out = over(out, TRACK, 0.18 * coverage(d_track, px) * body_a)
        d_arc = arc(x, y, cx, cy + 4, ARC_R, ARC_W, 0, 1.5 * math.pi)
        out = over(out, TRACK, 0.95 * coverage(d_arc, px) * body_a)

        # Specular highlight.
        d_spec = ellipse(*rotated(x, y, cx - 150, cy - 120, 0.65), cx - 150, cy - 120, 46, 24)
        out = over(out, (1, 1, 1), 0.55 * coverage(d_spec, px) * body_a)

    # Calyx and stem.
    bx, by = CALYX
    d_leaves = min(leaf(x, y, bx, by + 6, ang, ln, w) for ang, ln, w in LEAVES)
    d_stem = capsule(x, y, bx, by - 10, bx + 26, by - 118, 16)
    d_green = min(d_leaves, d_stem)
    green_a = coverage(d_green, px) * a
    if green_a > 0:
        colour = mix(LEAF_LIGHT, LEAF_DARK, smoothstep(by - 100, by + 110, y))
        out = over(out, colour, green_a)
    return out


# --- Menu bar template glyph -----------------------------------------------------------------
# Drawn black on transparent; AppKit tints template images to match the menu bar.


def glyph_pixel(x, y, px):
    # 1024 units == 18 pt. Tomato body plus a calyx, separated by a transparent gap so the
    # silhouette still reads as a tomato at 18 px.
    d_body = ellipse(x, y, 512, 600, 400, 370)
    d_leaves = min(
        leaf(x, y, 512, 250, 0.0, 250, 82),
        leaf(x, y, 512, 250, 1.25, 250, 76),
        leaf(x, y, 512, 250, -1.25, 250, 76),
    )
    d_stem = capsule(x, y, 512, 230, 560, 70, 44)
    d_green = min(d_leaves, d_stem)
    d_gap = d_green - 56
    # Timer hand cut-outs from the centre: twelve o'clock and three o'clock.
    d_hands = min(capsule(x, y, 512, 610, 512, 420, 46), capsule(x, y, 512, 610, 690, 610, 46))
    d = min(max(d_body, -d_gap, -d_hands), d_green)
    return (0.0, 0.0, 0.0, coverage(d, px))


def render(fn, size):
    px = 1024 / size
    return [fn((i % size + 0.5) * px, (i // size + 0.5) * px, px) for i in range(size * size)]


def write_json(path, payload):
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")


def main():
    appicon = os.path.join(CATALOG, "AppIcon.appiconset")
    glyph = os.path.join(CATALOG, "MenuBarIcon.imageset")
    os.makedirs(appicon, exist_ok=True)
    os.makedirs(glyph, exist_ok=True)
    write_json(os.path.join(CATALOG, "Contents.json"), {"info": {"author": "xcode", "version": 1}})

    rendered = {}
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            size = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            if size not in rendered:
                rendered[size] = render(icon_pixel, size)
            write_png(os.path.join(appicon, name), size, rendered[size])
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    write_json(os.path.join(appicon, "Contents.json"), {"images": images, "info": {"author": "xcode", "version": 1}})

    glyph_images = []
    for scale in (1, 2):
        size = 18 * scale
        name = f"menubar_18pt{'@2x' if scale == 2 else ''}.png"
        write_png(os.path.join(glyph, name), size, render(glyph_pixel, size))
        glyph_images.append({"filename": name, "idiom": "universal", "scale": f"{scale}x"})
    write_json(
        os.path.join(glyph, "Contents.json"),
        {
            "images": glyph_images,
            "info": {"author": "xcode", "version": 1},
            "properties": {"template-rendering-intent": "template"},
        },
    )


if __name__ == "__main__":
    main()
