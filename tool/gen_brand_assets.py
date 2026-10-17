#!/usr/bin/env python3
"""Generate Inkbound's brand artwork for every platform target.

The app icon used to be three different things in three different places: the
in-app mark was an open book, the iOS and tvOS icons were still the upstream
project's crescent and katana, and the Android TV banner was the upstream
wordmark. Everything here is generated from one description of the mark so the
launcher icon, the splash, the About screen and the TV banner cannot drift apart
again.

Two marks ship, matching the two slots in the in-app icon picker
(Settings -> Interface):

  plain  the brand mark — an open book with the bookmark ribbon in its gutter.
         This is what a fresh install shows and what the splash, the About
         screen, the TV banner and every Apple asset wear.
  cat    the alternate — the same book and ribbon with a cat reading it, for
         readers who want the less serious one.

The persisted icon ids ("crescent" for plain, "default" for cat) predate this
artwork and are baked into users' prefs, so they cannot be renamed and do not
follow the artwork. Which mark each id carries HAS changed once already; see
[SLOTS] and AppIconService.options, which have to agree with the manifest.

Both are drawn from primitives rather than traced from anything, and they are
not derived from the upstream Zangetsu artwork, so NOTICE.md needs no entry for
them. See AI_POLICY.md section 3 on third-party-derived assets.

Run from the repository root:

    python tool/gen_brand_assets.py

Requires Pillow. Deterministic: the same input always produces the same bytes,
so re-running it on an unchanged tree is a no-op in git.
"""

from __future__ import annotations

import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Supersample factor. Everything is drawn at size * SS and box-filtered down, so
# the 20px iOS icon and the 1024px App Store master come off the same geometry
# with clean edges instead of a chunky 20px version of the same drawing.
SS = 4
LANCZOS = Image.Resampling.LANCZOS

# ── palette ──────────────────────────────────────────────────────────────────
# Cream and coral-red come from the app's own theme (lib/core/theme/
# app_colors.dart); the plate is the ink navy the adaptive icon's background
# layer uses (android/.../res/values/colors.xml, ic_launcher_bg). Anything that
# changes the icon has to change these two files too, or the plate stops
# matching the artwork and the adaptive icon shows a ring.
CREAM = (237, 231, 214, 255)
CREAM_MID = (205, 197, 174, 255)
GUTTER = (150, 143, 126, 255)
ACCENT = (255, 77, 87, 255)
ACCENT_DEEP = (203, 41, 52, 255)
PLATE_TOP = (27, 27, 44, 255)
PLATE_BOT = (9, 9, 15, 255)
PLATE_EDGE = (255, 255, 255, 22)

# Launcher icon geometry. The corner radius is the continuous-corner
# approximation of the iOS squircle; Android's pre-26 launchers do not mask, so
# the plate carries its own corners.
CORNER_R = 0.2237

# How much of an adaptive-icon canvas the artwork is allowed to fill. Android
# gives a 108dp canvas, crops to the central 72dp, and only guarantees the
# central 66dp survives every mask. Fitting the art's own bounding box into 66%
# keeps the ears clear of a circular mask on the smallest launcher icon.
ADAPTIVE_FILL = 0.66


# ── geometry helpers ────────────────────────────────────────────────────────
def bezier(p0, p1, p2, steps):
    out = []
    for i in range(steps + 1):
        t = i / steps
        k = 1 - t
        out.append(
            (
                k * k * p0[0] + 2 * k * t * p1[0] + t * t * p2[0],
                k * k * p0[1] + 2 * k * t * p1[1] + t * t * p2[1],
            )
        )
    return out


def brush_stroke(d, pts, widths, fill):
    """A centreline with a varying half-width, filled as one polygon.

    A constant-width line with a symmetric taper reads as an arrowhead, so the
    width profile does the work instead of the shape of the ends.
    """
    top, bot = [], []
    n = len(pts)
    for i, (x, y) in enumerate(pts):
        if i == 0:
            nx, ny = pts[1][0] - x, pts[1][1] - y
        elif i == n - 1:
            nx, ny = x - pts[-2][0], y - pts[-2][1]
        else:
            nx, ny = pts[i + 1][0] - pts[i - 1][0], pts[i + 1][1] - pts[i - 1][1]
        m = math.hypot(nx, ny) or 1.0
        ox, oy = -ny / m * widths[i], nx / m * widths[i]
        top.append((x + ox, y + oy))
        bot.append((x - ox, y - oy))
    d.polygon(top + bot[::-1], fill=fill)


def drop_shadow(art, u, blur=0.030, drop=0.034, alpha=0.55):
    """Soft shadow derived from the artwork's own silhouette, clipped to the plate.

    Taken from the artwork rather than a hand-placed shape so it stays correct
    when the mark changes.
    """
    n = art.size[0]
    moved_mask = art.split()[3].filter(ImageFilter.GaussianBlur(u(blur)))
    shifted = Image.new("L", (n, n), 0)
    shifted.paste(moved_mask, (0, int(u(drop))))
    shifted = shifted.point(lambda v: int(v * alpha))

    plate_mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(plate_mask).rounded_rectangle(
        [0, 0, n - 1, n - 1], radius=int(n * CORNER_R), fill=255
    )
    shifted = Image.composite(shifted, Image.new("L", (n, n), 0), plate_mask)

    shade = Image.new("RGBA", (n, n), (0, 0, 0, 255))
    shade.putalpha(shifted)
    return shade


# ── the mark ────────────────────────────────────────────────────────────────
def book_pages(d, u, inset=0.0, drop=0.0):
    """The open book, drawn as two leaves with a visible gutter.

    The gap between the leaves is load-bearing: closed up, they merge into one
    blob at 48px and the mark stops reading as an open book.

    `drop` lowers the book to make room above it; `inset` narrows it.
    """
    lx, rx = u(0.206 + inset), u(0.794 - inset)
    top, bot = u(0.294 + drop), u(0.660 + drop)
    it, ib = u(0.348 + drop), u(0.714 + drop)
    d.polygon([(lx, top), (u(0.482), it), (u(0.482), ib), (lx, bot)], fill=CREAM)
    d.polygon([(rx, top), (u(0.518), it), (u(0.518), ib), (rx, bot)], fill=CREAM)
    d.line([(u(0.482), it), (u(0.482), ib)], fill=GUTTER, width=max(1, int(u(0.006))))
    d.line([(u(0.518), it), (u(0.518), ib)], fill=GUTTER, width=max(1, int(u(0.006))))


def ribbon(d, u, top=0.344, tip=0.780):
    """The bookmark hanging out of the gutter. The accent-red thread that ties
    the icon to the wordmark's accent and the app's accent colour."""
    wl, wr = u(0.478), u(0.522)
    d.polygon(
        [(wl, u(top)), (wr, u(top)), (wr, u(tip)), (u(0.5), u(tip) - u(0.060)), (wl, u(tip))],
        fill=ACCENT,
    )
    # a shaded sliver down the trailing edge so the ribbon is not a flat slab
    d.polygon(
        [
            (wr - u(0.012), u(top)),
            (wr, u(top)),
            (wr, u(tip)),
            (wr - u(0.012), u(tip) - u(0.018)),
        ],
        fill=ACCENT_DEEP,
    )


def cat_head(d, u, cx, top, w, h, eyes=True):
    """A cat's head: rounded skull plus two ears.

    The eyes have to sit in the band above the book's top edge. Any lower and
    the pages cover them, which leaves two red triangles and reads as a crown
    rather than a cat. Everything is positioned off `top`/`h` for that reason.
    """
    hl, hr = cx - w / 2.0, cx + w / 2.0
    d.rounded_rectangle([u(hl), u(top), u(hr), u(top + h)], radius=u(h * 0.48), fill=ACCENT)

    ew = w * 0.54
    for outer, inner, apex in (
        (hl + w * 0.02, hl + ew, hl + ew * 0.46),
        (hr - w * 0.02, hr - ew, hr - ew * 0.46),
    ):
        d.polygon(
            [
                (u(outer), u(top + h * 0.34)),
                (u(apex), u(top - h * 0.44)),
                (u(inner), u(top + h * 0.04)),
            ],
            fill=ACCENT,
        )
    # inner ears: inset far enough to read at 136px and vanish harmlessly below
    d.polygon(
        [
            (u(hl + w * 0.15), u(top + h * 0.30)),
            (u(hl + ew * 0.52), u(top - h * 0.10)),
            (u(hl + ew * 0.82), u(top + h * 0.12)),
        ],
        fill=ACCENT_DEEP,
    )
    d.polygon(
        [
            (u(hr - w * 0.15), u(top + h * 0.30)),
            (u(hr - ew * 0.52), u(top - h * 0.10)),
            (u(hr - ew * 0.82), u(top + h * 0.12)),
        ],
        fill=ACCENT_DEEP,
    )

    if eyes:
        er = w * 0.072
        ey = top + h * 0.52
        for ex in (cx - w * 0.21, cx + w * 0.21):
            d.ellipse(
                [u(ex - er), u(ey - er * 1.25), u(ex + er), u(ey + er * 1.25)], fill=CREAM
            )


def art_cat(d, u):
    """Icon slot 1 — a cat reading, ribbon in the gutter."""
    cat_head(d, u, 0.5, 0.222, 0.248, 0.220)
    book_pages(d, u, inset=0.012, drop=0.096)
    ribbon(d, u, top=0.478, tip=0.800)


def art_plain(d, u):
    """Icon slot 2 — the same book and ribbon, no cat."""
    book_pages(d, u)
    ribbon(d, u)


MARKS = {"cat": art_cat, "plain": art_plain}


def _supersample(size):
    """Supersample factor for a target of `size` px.

    Backs off on large outputs: the 4640px tvOS Top Shelf image would otherwise
    allocate a 18560px intermediate, which is gigabytes of RGBA for no visible
    gain — at that size there is nothing left to anti-alias.
    """
    return max(1, min(SS, 2400 // max(1, size)))


def artwork(mark, size):
    """The mark alone on transparency — no plate. The splash and About screen
    composite this over their own backgrounds."""
    n = size * _supersample(size)
    layer = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    MARKS[mark](ImageDraw.Draw(layer), lambda v: v * n)
    return layer.resize((size, size), LANCZOS)


def plate(width, height=None, rounded=True):
    """The ink-navy gradient plate. `rounded=False` fills the corners for
    Apple, which masks the icon itself and rejects a pre-rounded or transparent
    one. `height` defaults to the width so icon callers can stay square."""
    if height is None:
        height = width

    col = Image.new("RGBA", (1, height))
    for y in range(height):
        t = y / max(1, height - 1)
        col.putpixel(
            (0, y),
            tuple(int(PLATE_TOP[i] + (PLATE_BOT[i] - PLATE_TOP[i]) * t) for i in range(4)),
        )
    grad = col.resize((width, height), Image.BILINEAR)

    if not rounded:
        return grad

    mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, width - 1, height - 1], radius=int(min(width, height) * CORNER_R), fill=255
    )
    out = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    ring = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(ring).rounded_rectangle(
        [0, 0, width - 1, height - 1],
        radius=int(min(width, height) * CORNER_R),
        outline=PLATE_EDGE,
        width=max(1, int(min(width, height) * 0.005)),
    )
    return Image.alpha_composite(out, ring)


def legacy_icon(mark, size):
    """A complete launcher icon: plate, shadow, mark. For Android's pre-26
    mipmaps and the in-app previews, neither of which masks anything."""
    n = size * _supersample(size)
    art = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    MARKS[mark](ImageDraw.Draw(art), lambda v: v * n)
    out = Image.alpha_composite(plate(n), drop_shadow(art, lambda v: v * n))
    return Image.alpha_composite(out, art).resize((size, size), LANCZOS)


def apple_icon(mark, size):
    """An iOS/tvOS app icon: full square, opaque, corners left to the OS.

    Apple masks the icon itself, so baking in corners or leaving the corners
    transparent gets the build rejected at upload rather than merely looking
    wrong.
    """
    img = legacy_icon(mark, size)
    flat = Image.new("RGB", img.size, PLATE_BOT[:3])
    flat.paste(img, (0, 0), img)
    return flat


def _fit_into(img, box):
    """Scale `img` to fit `box` and centre it, preserving aspect."""
    scale = min(box[0] / img.size[0], box[1] / img.size[1])
    w = max(1, int(round(img.size[0] * scale)))
    h = max(1, int(round(img.size[1] * scale)))
    scaled = img.resize((w, h), LANCZOS)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(scaled, ((img.size[0] - w) // 2, (img.size[1] - h) // 2), scaled)
    return out


def adaptive_layers(mark, size):
    """The foreground and monochrome layers for an Android adaptive icon.

    Sized off the artwork's alpha bounding box rather than the canvas, so
    changing the mark does not silently push the ears into the crop.

    Monochrome is a flat silhouette: Android 13+ tints that layer to match the
    user's wallpaper, and it is single-colour by definition, so the red reads
    white there.
    """
    art = artwork(mark, size * 2)
    bbox = art.split()[3].getbbox()
    if bbox:
        art = art.crop(bbox)
    box = int(size * ADAPTIVE_FILL)
    art = _fit_into(art, (box, box))

    mono = Image.new("RGBA", art.size, (255, 255, 255, 255))
    mono.putalpha(art.split()[3])
    return art, mono


# ── wordmark ────────────────────────────────────────────────────────────────
WORDMARK_TEXT = "INKBOUND"
TRACKING = 0.30  # extra space between glyphs, in ems


def _wordmark_font():
    """Inter, which the app already bundles as its UI face, so the wordmark is
    set in the same typeface the interface is. Falls back to a system face if
    the bundled font is missing so the script still runs on a partial checkout."""
    for rel in ("assets/fonts/Inter.ttf", "assets/fonts/Nunito-Regular.ttf"):
        path = os.path.join(ROOT, rel)
        if os.path.exists(path):
            return path
    return "C:/Windows/Fonts/segoeui.ttf"


def wordmark(width, height, colour=CREAM, pad=0.04):
    """INKBOUND, letterspaced, on transparency.

    Sized to fit `width` x `height` rather than cropped to the ink, so every
    caller gets the same optical size regardless of the box it asked for.
    """
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    box_w, box_h = int(width * (1 - 2 * pad)), int(height * (1 - 2 * pad))

    size = box_h
    font = ImageFont.truetype(_wordmark_font(), size)
    advance = font.getlength("A")
    track = advance * TRACKING
    natural = sum(font.getlength(c) for c in WORDMARK_TEXT) + track * (
        len(WORDMARK_TEXT) - 1
    )
    scale = min(box_w / natural, 1.0) if natural else 1.0
    if scale < 1.0:
        size = max(8, int(size * scale))
        font = ImageFont.truetype(_wordmark_font(), size)
        advance = font.getlength("A")
        track = advance * TRACKING
        natural = sum(font.getlength(c) for c in WORDMARK_TEXT) + track * (
            len(WORDMARK_TEXT) - 1
        )

    ascent, descent = font.getmetrics()
    x = (width - natural) / 2
    y = (height - (ascent + descent)) / 2
    d = ImageDraw.Draw(img)
    for ch in WORDMARK_TEXT:
        d.text((x, y), ch, font=font, fill=colour)
        x += font.getlength(ch) + track
    return img


# ── wide banners ────────────────────────────────────────────────────────────
def banner(mark, width, height, pad=0.06):
    """Mark on the left, wordmark on the right, on the plate.

    Used for the Android TV banner and the two tvOS Top Shelf images, which
    were all carrying the upstream wordmark.
    """
    img = plate(width, height, rounded=False).convert("RGBA")
    side = int(height * 0.74)
    art = artwork(mark, side)
    img.alpha_composite(art, (int(height * pad), (height - side) // 2))

    left = int(height * pad) + side + int(height * 0.16)
    right = int(width * (1 - pad))
    word_h = int(height * 0.34)
    word = wordmark(max(1, right - left), word_h)
    img.alpha_composite(word, (left, (height - word_h) // 2))
    return img.convert("RGB")


def tv_plate(width, height):
    """The opaque background layer of a tvOS brand-asset stack."""
    return plate(width, height, rounded=False).convert("RGBA")


def tv_art(mark, width, height, fill=0.66):
    """The artwork layer of a tvOS brand-asset stack.

    The returned image is always the full stack size with the mark centred —
    tvOS requires every layer to match, so it cannot just be the square art.

    tvOS insets the icon inside its own rounded card, so the mark sits well
    inside the frame rather than bleeding to the edges the way a launcher icon
    has to.
    """
    side = int(min(width, height) * fill)
    art = artwork(mark, side)
    out = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    out.paste(art, ((width - side) // 2, (height - side) // 2), art)
    return out


# ── emit ────────────────────────────────────────────────────────────────────
DENSITIES = ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi")
LEGACY_PX = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
# 108dp foreground canvas, the size Android expects per density.
FG_PX = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}

# (filename, pixels) — matches AppIcon.appiconset/Contents.json exactly.
IOS_ICONS = [
    ("Icon-App-20x20@1x.png", 20), ("Icon-App-20x20@2x.png", 40),
    ("Icon-App-20x20@3x.png", 60), ("Icon-App-29x29@1x.png", 29),
    ("Icon-App-29x29@2x.png", 58), ("Icon-App-29x29@3x.png", 87),
    ("Icon-App-40x40@2x.png", 80), ("Icon-App-40x40@3x.png", 120),
    ("Icon-App-50x50@1x.png", 50), ("Icon-App-50x50@2x.png", 100),
    ("Icon-App-57x57@1x.png", 57), ("Icon-App-57x57@2x.png", 114),
    ("Icon-App-60x60@2x.png", 120), ("Icon-App-60x60@3x.png", 180),
    ("Icon-App-72x72@1x.png", 72), ("Icon-App-72x72@2x.png", 144),
    ("Icon-App-76x76@1x.png", 76), ("Icon-App-76x76@2x.png", 152),
    ("Icon-App-83.5x83.5@2x.png", 167), ("Icon-App-1024x1024@1x.png", 1024),
]

TVOS = [
    ("App Icon - Large.imagestack/Front.imagestacklayer/Content.imageset/large_front.png", 1280, 768),
    ("App Icon - Large.imagestack/Front.imagestacklayer/Content.imageset/large_front@2x.png", 2560, 1536),
    ("App Icon - Large.imagestack/Middle.imagestacklayer/Content.imageset/large_middle.png", 1280, 768),
    ("App Icon - Large.imagestack/Middle.imagestacklayer/Content.imageset/large_middle@2x.png", 2560, 1536),
    ("App Icon - Large.imagestack/Back.imagestacklayer/Content.imageset/large_back.png", 1280, 768),
    ("App Icon - Large.imagestack/Back.imagestacklayer/Content.imageset/large_back@2x.png", 2560, 1536),
    ("App Icon - Small.imagestack/Front.imagestacklayer/Content.imageset/small_front.png", 400, 240),
    ("App Icon - Small.imagestack/Front.imagestacklayer/Content.imageset/small_front@2x.png", 800, 480),
    ("App Icon - Small.imagestack/Middle.imagestacklayer/Content.imageset/small_middle.png", 400, 240),
    ("App Icon - Small.imagestack/Middle.imagestacklayer/Content.imageset/small_middle@2x.png", 800, 480),
    ("App Icon - Small.imagestack/Back.imagestacklayer/Content.imageset/small_back.png", 400, 240),
    ("App Icon - Small.imagestack/Back.imagestacklayer/Content.imageset/small_back@2x.png", 800, 480),
]

ANDROID_RES = "android/app/src/main/res"
ANDROID_BRAND = "assets/brand/icons/android"
IOS_SETS = (
    "ios/Runner/Assets.xcassets/AppIcon.appiconset",
    "assets/brand/icons/ios/AppIcon.appiconset",
)
TVOS_ROOT = "tvos/Runner/Assets.xcassets/AppIcon.brandassets"

# The brand mark: what a fresh install shows, what the splash, the About screen,
# the TV banner and every Apple asset wear. The other mark is an alternative a
# reader can pick from Settings -> Interface.
PRIMARY = "plain"
ALTERNATE = "cat"

# Persisted icon id -> artwork -> mipmap resource, in the order the picker
# lists them.
#
# The ids are frozen: they are written into prefs on users' phones, so they
# outlive whatever artwork they once pointed at. Which mark each id carries is
# NOT frozen and has already swapped once. Only this table, the manifest's
# android:icon on each alias, and AppIconService.options have to agree.
SLOTS = (
    ("crescent", PRIMARY, "ic_launcher_plain"),
    ("default", ALTERNATE, "ic_launcher_cat"),
)

written = 0


def save(img, rel):
    global written
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)
    written += 1


def emit_android():
    # Legacy square icons, one per icon slot per density. Pre-26 launchers do
    # not mask, so the plate supplies its own corners.
    for _, mark, base in SLOTS:
        for dens, px in LEGACY_PX.items():
            save(legacy_icon(mark, px), f"{ANDROID_RES}/mipmap-{dens}/{base}.png")

    # Adaptive foreground + monochrome. The foreground is what the launcher
    # masks; the plate is @color/ic_launcher_bg behind it.
    for _, mark, base in SLOTS:
        for dens, px in FG_PX.items():
            fg, mono = adaptive_layers(mark, px)
            save(fg, f"{ANDROID_RES}/mipmap-{dens}/{base}_fg.png")
            save(mono, f"{ANDROID_RES}/mipmap-{dens}/{base}_mono.png")

    # The brand mirror under assets/ is what a release reads from. Both slots,
    # so the mirror stays a complete copy rather than only the default one.
    for _, mark, base in SLOTS:
        for dens, px in LEGACY_PX.items():
            save(
                legacy_icon(mark, px),
                f"{ANDROID_BRAND}/mipmap-{dens}/{base}.png",
            )
        for dens, px in FG_PX.items():
            fg, mono = adaptive_layers(mark, px)
            save(fg, f"{ANDROID_BRAND}/mipmap-{dens}/{base}_fg.png")
            save(mono, f"{ANDROID_BRAND}/mipmap-{dens}/{base}_mono.png")

    # Android TV banner — was the upstream wordmark.
    save(banner(PRIMARY, 320, 180), f"{ANDROID_RES}/drawable-xhdpi/tv_banner.png")


def emit_apple():
    for d in IOS_SETS:
        for name, px in IOS_ICONS:
            save(apple_icon(PRIMARY, px), f"{d}/{name}")

    # tvOS brand assets are a stack, not a single image: middle carries the
    # opaque plate, front carries the mark, back stays empty. Every layer has
    # to be the stack's full size or tvOS rejects the asset.
    for rel, w, h in TVOS:
        if "/Front.imagestacklayer/" in "/" + rel:
            img = tv_art(PRIMARY, w, h)
        elif "/Middle.imagestacklayer/" in "/" + rel:
            img = tv_plate(w, h)
        else:
            img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        save(img, f"{TVOS_ROOT}/{rel}")

    for rel, w, h in (
        ("Top Shelf Image.imageset/top_shelf.png", 1920, 720),
        ("Top Shelf Image.imageset/top_shelf@2x.png", 3840, 1440),
        ("Top Shelf Image Wide.imageset/top_shelf_wide.png", 2320, 720),
        ("Top Shelf Image Wide.imageset/top_shelf_wide@2x.png", 4640, 1440),
    ):
        save(banner(PRIMARY, w, h), f"{TVOS_ROOT}/{rel}")


def emit_in_app():
    # Bundled assets. app_icon.png doubles as the Discord CDN URL and as the
    # image_path in the pubspec's flutter_launcher_icons block, so it is the
    # plain square plate version at a size both can use.
    save(legacy_icon(PRIMARY, 512), "assets/icon/app_icon.png")
    # logo_mark.png is the mark alone — the splash, About screen and the
    # mode-switch transition draw it over their own backgrounds.
    save(artwork(PRIMARY, 512), "assets/icon/logo_mark.png")
    save(wordmark(900, 200), "assets/icon/wordmark.png")
    # Launcher-icon previews for the in-app picker, one per slot, in SLOTS order.
    # Mipmaps are not reachable from Dart, so each ships as a normal asset.
    for _, mark, _ in SLOTS:
        save(legacy_icon(mark, 360), f"assets/icon/preview_{mark}.png")


def main():
    if not os.path.isdir(ROOT):
        sys.exit("run this from the repository root")
    emit_android()
    emit_apple()
    emit_in_app()
    print(f"wrote {written} files")


if __name__ == "__main__":
    main()
