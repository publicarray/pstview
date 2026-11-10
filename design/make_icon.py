"""Render the pstview mark ("Sealed Signal"): envelope + amber inspection lens on an ink-navy seal.

Outputs (next to this script):
  pstview.ico            multi-resolution Windows icon (16, 20, 24, 32, 40, 48, 64, 128, 256), PNG-compressed
  icon-<n>.png           each size
  pstview-sheet.png      specimen sheet (mark at all sizes, wordmark, palette)
"""
import io, os, struct, sys
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = sys.argv[1] if len(sys.argv) > 1 else ""

INK = (19, 35, 63)        # #13233F ground
PAPER = (246, 244, 238)   # #F6F4EE kept thing
AMBER = (245, 183, 0)     # #F5B700 signal
INK_SOFT = (96, 108, 128)

SS = 8  # supersampling factor


def rounded_bg(d, s, r):
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=r, fill=INK)


def mark_large(size):
    """Detailed mark on a 256 grid, for 48 px and up."""
    S = 256 * SS
    k = SS * size / 256 * (256 / size)  # = SS (grid unit in supersampled px)
    u = lambda v: int(round(v * SS))
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rounded_bg(d, S, u(52))
    sw = 15  # one stroke width (grid units) - the system's single measure
    # envelope body
    d.rounded_rectangle([u(38), u(72), u(194), u(176)], radius=u(12), outline=PAPER, width=u(sw))
    # flap: two strokes meeting at the centre, round joint
    pts = [(u(46), u(80)), (u(116), u(130)), (u(186), u(80))]
    d.line(pts, fill=PAPER, width=u(sw), joint="curve")
    for p in pts[1:2]:
        r = u(sw) / 2
        d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=PAPER)
    # lens: clear a one-stroke margin of ground around it, then the ring and handle
    cx, cy, R = 182, 178, 40
    gap = R + sw / 2 + sw
    d.ellipse([u(cx - gap), u(cy - gap), u(cx + gap), u(cy + gap)], fill=INK)
    d.ellipse([u(cx - R - sw / 2), u(cy - R - sw / 2), u(cx + R + sw / 2), u(cy + R + sw / 2)], fill=AMBER)
    d.ellipse([u(cx - R + sw / 2), u(cy - R + sw / 2), u(cx + R - sw / 2), u(cy + R - sw / 2)], fill=INK)
    # handle (45 degrees), round caps
    hx0, hy0, hx1, hy1 = cx + 31, cy + 31, 228, 224
    d.line([(u(hx0), u(hy0)), (u(hx1), u(hy1))], fill=AMBER, width=u(sw + 2))
    for (x, y) in ((hx1, hy1),):
        r = u(sw + 2) / 2
        d.ellipse([u(x) - r, u(y) - r, u(x) + r, u(y) + r], fill=AMBER)
    # a small paper "seal" dot at the lens centre: the thing under inspection
    sr = 7
    d.ellipse([u(cx - sr), u(cy - sr), u(cx + sr), u(cy + sr)], fill=PAPER)
    return img.resize((size, size), Image.LANCZOS)


def mark_small(size):
    """Pixel-snapped mark on a 16-unit grid for 16..40 px (strokes = whole pixels)."""
    g = size / 16.0
    S = size * SS
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    u = lambda v: int(round(v * g)) * SS          # snapped to whole device pixels
    uf = lambda v: int(round(v * g * SS))         # free (for curves)
    sw = max(1, round(1.0 * g))  # stroke in device px
    W = sw * SS
    rounded_bg(d, S, uf(3.2))
    # envelope outline: x 2..12, y 4..11
    d.rectangle([u(2), u(4), u(12) + W - 1, u(4) + W - 1], fill=PAPER)        # top
    d.rectangle([u(2), u(11), u(12) + W - 1, u(11) + W - 1], fill=PAPER)       # bottom
    d.rectangle([u(2), u(4), u(2) + W - 1, u(11) + W - 1], fill=PAPER)         # left
    d.rectangle([u(12), u(4), u(12) + W - 1, u(11) + W - 1], fill=PAPER)       # right
    # flap V (stroke centred on the pixel grid)
    h = W / 2
    x0, x1, y0 = u(2) + h, u(12) + h, u(4) + h
    d.line([(x0, y0), ((x0 + x1) / 2, uf(8.2)), (x1, y0)], fill=PAPER, width=W, joint="curve")
    # lens: cleared margin of ground, then the signal
    cx, cy = 12.0, 12.0
    if size < 24:
        # solid amber seal - a ring is too small to read at this size
        R = 2.5
        gap = R + 1.0
        d.ellipse([uf(cx - gap), uf(cy - gap), uf(cx + gap), uf(cy + gap)], fill=INK)
        d.ellipse([uf(cx - R), uf(cy - R), uf(cx + R), uf(cy + R)], fill=AMBER)
    else:
        R = 2.7
        gap = R + 1.2
        d.ellipse([uf(cx - gap), uf(cy - gap), uf(cx + gap), uf(cy + gap)], fill=INK)
        d.ellipse([uf(cx - R), uf(cy - R), uf(cx + R), uf(cy + R)], fill=AMBER)
        ri = R - 1.0 * sw / g
        d.ellipse([uf(cx - ri), uf(cy - ri), uf(cx + ri), uf(cy + ri)], fill=INK)
        d.line([(uf(cx + 1.9), uf(cy + 1.9)), (uf(14.6), uf(14.6))], fill=AMBER, width=W)
    return img.resize((size, size), Image.BOX)


def make(size):
    return mark_small(size) if size <= 40 else mark_large(size)


def write_ico(path, images):
    """ICO with PNG-compressed entries (Windows Vista+), one hand-tuned image per size."""
    entries = []
    for im in images:
        b = io.BytesIO()
        im.save(b, format="PNG")
        entries.append((im.size[0], b.getvalue()))
    header = struct.pack("<HHH", 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    dir_bytes = b""
    data = b""
    for sz, png in entries:
        dim = 0 if sz >= 256 else sz
        dir_bytes += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(png), offset + len(data))
        data += png
    with open(path, "wb") as f:
        f.write(header + dir_bytes + data)


def font(name, px):
    try:
        return ImageFont.truetype(os.path.join(FONTS, name), px)
    except Exception:
        return ImageFont.load_default()


def sheet(icons):
    W, H = 1800, 1000
    img = Image.new("RGB", (W, H), PAPER)
    d = ImageDraw.Draw(img)
    m = 96
    # specimen row: mark at each size, baseline-aligned, equal gutters
    sizes = [256, 128, 64, 48, 32, 24, 16]
    gutter = 72
    x = m
    base = 160 + 256
    lab = font("JetBrainsMono-Regular.ttf", 15)
    for i, s in enumerate(sizes):
        im = icons[s]
        img.paste(im, (x, base - s), im)
        d.text((x, base + 22), f"{i + 1:02d}", fill=INK_SOFT, font=lab)
        d.text((x, base + 44), f"{s}px", fill=INK_SOFT, font=lab)
        x += s + gutter
    # hairline rule
    d.line([(m, base + 104), (W - m, base + 104)], fill=(214, 210, 200), width=1)
    # wordmark lock-up
    big = make(256).resize((112, 112), Image.LANCZOS)
    wy = base + 168
    img.paste(big, (m, wy), big)
    wm = font("Jura-Light.ttf", 96)
    tx = m + 112 + 44
    # place the wordmark so its x-height is centred on the mark, descenders clear of the tagline
    bb = d.textbbox((0, 0), "pstview", font=wm, anchor="ls")
    base_y = wy + 74
    d.text((tx, base_y), "pstview", fill=INK, font=wm, anchor="ls")
    sub = font("InstrumentSans-Regular.ttf", 21)
    desc = bb[3]  # descender depth below baseline
    d.text((tx + 4, base_y + desc + 22), "read-only evidence viewer for outlook data", fill=INK_SOFT, font=sub, anchor="lt")
    # palette chips, right aligned
    chips = [(INK, "INK  #13233F"), (PAPER, "PAPER  #F6F4EE"), (AMBER, "SIGNAL  #F5B700")]
    cx = W - m - 3 * 220 + 20
    cy = wy + 8
    for col, name in chips:
        d.rectangle([cx, cy, cx + 56, cy + 56], fill=col, outline=(200, 196, 186))
        d.text((cx, cy + 70), name, fill=INK_SOFT, font=lab)
        cx += 220
    # catalogue marks
    d.text((m, 72), "SEALED SIGNAL  /  MARK 01", fill=INK_SOFT, font=lab)
    d.text((W - m - 260, 72), "pstview", fill=INK_SOFT, font=lab)
    d.text((m, H - 72), "one ground . one kept thing . one point of attention", fill=INK_SOFT, font=lab)
    img.save(os.path.join(HERE, "pstview-sheet.png"))


if __name__ == "__main__":
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    icons = {s: make(s) for s in sizes}
    for s, im in icons.items():
        im.save(os.path.join(HERE, f"icon-{s}.png"))
    write_ico(os.path.join(HERE, "pstview.ico"), [icons[s] for s in sizes])
    sheet(icons)
    print("ok")
