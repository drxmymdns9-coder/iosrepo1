"""Generate the accent-coloured alternate app icons from the default art.

The iOS port of the Android repo's script of the same name, with its recolouring unchanged: the
default icon is a single flat colour on black, and each pixel's brightness relative to that colour
becomes the strength of the accent there, which keeps anti-aliased edges and the black ground as
drawn. Keys and colours mirror ThemeAccent.

iOS finds alternate icons as loose PNGs at the app bundle's root, named in Info.plist's
CFBundleIcons. xtool copies whatever `resources:` in xtool.yml lists to that root, so this script
writes the files and prints the lines both of those need:

    python scripts/generate_icon_variants.py
"""

from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Resources" / "AppIcon.png"
OUT = ROOT / "Resources" / "AppIcons"

ACCENTS = {
    "monochrome": 0xFFFFFF,
    "purple": 0x8B5CF6,
    "neon_green": 0x39FF14,
    "blood_red": 0xD1102B,
    "ocean_blue": 0x3B82F6,
    "cyan": 0x22D3EE,
    "sakura_pink": 0xF472B6,
    "sunset_orange": 0xF97316,
    "gold": 0xFACC15,
    "emerald": 0x10B981,
}

# iPhone 60pt at @2x and @3x; iPad Pro's 83.5pt at @2x, which the smaller iPads scale down from.
SIZES = {"@2x.png": 120, "@3x.png": 180, "@2x~ipad.png": 167}


def recolor(image: Image.Image, accent: int) -> Image.Image:
    rgba = np.asarray(image.convert("RGBA")).astype(np.float32) / 255.0
    rgb, alpha = rgba[..., :3], rgba[..., 3:]
    value = rgb.max(axis=-1, keepdims=True)
    mark = np.percentile(value[(value > 0.5) & (alpha > 0.5)], 90)
    strength = np.clip(value / mark, 0.0, 1.0)
    color = np.array([(accent >> 16) & 0xFF, (accent >> 8) & 0xFF, accent & 0xFF], np.float32) / 255.0
    out = np.concatenate([strength * color, alpha], axis=-1)
    return Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), "RGBA")


def main() -> None:
    source = Image.open(SOURCE)
    OUT.mkdir(parents=True, exist_ok=True)
    names = []
    for key, accent in ACCENTS.items():
        # Opaque RGB: iOS draws an icon's transparency as black anyway, and refuses alpha in some places.
        art = recolor(source, accent).convert("RGB")
        for suffix, px in SIZES.items():
            name = f"AppIcon-{key}{suffix}"
            art.resize((px, px), Image.LANCZOS).save(OUT / name, optimize=True)
            names.append(name)
    print("xtool.yml resources:")
    for name in names:
        print(f"  - Resources/AppIcons/{name}")


if __name__ == "__main__":
    main()
