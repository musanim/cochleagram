#!/usr/bin/env python3
"""Build Cochleagram.icns from IconImage.PNG.

Run this only when the artwork changes; the .icns it writes is checked in and
`make_app.sh` just copies it into the bundle.

    python3 make_icon.py

Why this rather than iconutil: iconutil and sips are macOS-only, and an .icns
whose entries are PNG is a short enough format to write directly -- a header,
then one length-prefixed chunk per size. Doing it here means the icon can be
regenerated anywhere and does not depend on which tools happen to be installed.

The artwork is placed on the rounded square macOS has expected since Big Sur
rather than filling the tile edge to edge. A full-bleed icon looks wrong beside
every other icon in the Dock, and this one in particular is mostly white, so
without the shape and its hairline edge it would dissolve into a light
background entirely.
"""

import struct
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "IconImage.PNG"
OUT = HERE / "Cochleagram.icns"

# Big Sur proportions: the rounded square occupies about 80% of the tile, with
# a corner radius of about 22.5% of its own width.
CANVAS = 1024
TILE = 824
RADIUS = 185
INSET = 26                      # artwork inside the tile

# (OSType, pixel size). Both the plain and the @2x names for each logical size,
# because which one a given part of macOS asks for is not worth predicting.
#
# `icp4` and `icp5` -- the 16 and 32 pixel entries -- are deliberately absent.
# They are documented as PNG, but macOS also reads those two OSTypes as raw
# pixel data, and a PNG byte stream drawn as raw pixels is coloured noise. That
# is exactly what turned up in the Finder, at the one size the list view uses.
# Every type below is unambiguously PNG. macOS derives 16 from `ic11`.
ENTRIES = [
    (b"ic11", 32), (b"ic12", 64),
    (b"ic07", 128), (b"ic13", 256), (b"ic08", 256), (b"ic14", 512),
    (b"ic09", 512), (b"ic10", 1024),
]


def build_master() -> Image.Image:
    art = Image.open(SOURCE).convert("RGB")

    tile = Image.new("RGBA", (TILE, TILE), (255, 255, 255, 255))
    inner = TILE - 2 * INSET
    art = art.resize((inner, inner), Image.LANCZOS)
    tile.paste(art, (INSET, INSET))

    # A hairline edge, so a white icon still reads as an object on white.
    ImageDraw.Draw(tile).rounded_rectangle(
        [0, 0, TILE - 1, TILE - 1], radius=RADIUS,
        outline=(150, 150, 150, 255), width=3)

    mask = Image.new("L", (TILE, TILE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, TILE - 1, TILE - 1], radius=RADIUS, fill=255)
    tile.putalpha(mask)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(tile, ((CANVAS - TILE) // 2, (CANVAS - TILE) // 2), tile)
    return canvas


def main() -> None:
    master = build_master()
    chunks = []
    for ostype, size in ENTRIES:
        from io import BytesIO
        buf = BytesIO()
        master.resize((size, size), Image.LANCZOS).save(buf, format="PNG")
        data = buf.getvalue()
        chunks.append(ostype + struct.pack(">I", len(data) + 8) + data)

    body = b"".join(chunks)
    OUT.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    print(f"wrote {OUT.name}  ({len(body) + 8} bytes, {len(ENTRIES)} sizes)")


if __name__ == "__main__":
    main()
