#!/usr/bin/env python3
"""Normalize the supplied app-icon artwork into the asset catalog.

The source of truth is Design/app-icon-source.png, the artwork the owner
supplied. This script produces the exact file App Store Connect accepts, so the
conversion is reproducible and reviewable rather than a one-off image edit:

  - exactly 1024x1024 (the source is resampled if it is not)
  - opaque RGB with no alpha channel — an icon with transparency is rejected
  - square corners, because iOS applies the superellipse mask itself

    python3 Scripts/install-appicon.py [source.png]
"""
from __future__ import annotations

import json
import pathlib
import sys

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Design" / "app-icon-source.png"
ICONSET = ROOT / "App/Courseleaf/Resources/Assets.xcassets/AppIcon.appiconset"
FILENAME = "AppIcon-1024.png"
SIZE = 1024


def main() -> int:
    src = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else SOURCE
    if not src.is_file():
        print(f"no artwork at {src}")
        return 2

    img = Image.open(src)
    print(f"source: {src.name} {img.size[0]}x{img.size[1]} {img.mode}")
    if img.mode in ("RGBA", "LA", "P"):
        # Flatten onto the artwork's own corner colour rather than white, so a
        # transparent margin cannot show up as a bright ring on the home screen.
        rgba = img.convert("RGBA")
        ground = rgba.convert("RGB").getpixel((0, 0))
        flat = Image.new("RGB", rgba.size, ground)
        flat.paste(rgba, mask=rgba.getchannel("A"))
        img = flat
    else:
        img = img.convert("RGB")

    if img.size != (SIZE, SIZE):
        if img.size[0] != img.size[1]:
            print(f"WARNING: source is not square ({img.size}); it will be squashed to {SIZE}x{SIZE}")
        img = img.resize((SIZE, SIZE), Image.LANCZOS)

    assert img.mode == "RGB" and img.size == (SIZE, SIZE), (img.mode, img.size)
    out = ICONSET / FILENAME
    ICONSET.mkdir(parents=True, exist_ok=True)
    img.save(out, "PNG", optimize=True)

    contents = ICONSET / "Contents.json"
    data = json.loads(contents.read_text()) if contents.is_file() else {
        "images": [{"idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }
    data["images"][0]["filename"] = FILENAME
    contents.write_text(json.dumps(data, indent=2) + "\n")

    print(f"wrote {out.relative_to(ROOT)} {SIZE}x{SIZE} RGB, {out.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
