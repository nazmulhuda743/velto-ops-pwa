#!/usr/bin/env python3
"""Generate Velto launcher icons into the (CI-generated) Android project.

Run AFTER `npx cap add android`, from anywhere — paths are resolved relative
to this file. Reads the repo-root icon-512.png and writes adaptive + legacy
launcher icons at every density, plus the dark adaptive-icon background.
Requires Pillow.
"""
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(REPO, "icon-512.png")
RES = os.path.join(REPO, "apk", "android", "app", "src", "main", "res")

BG = (11, 15, 26, 255)  # #0b0f1a — Velto dark theme
DENS = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def rounded(img, size, radius_frac=0.22):
    img = img.resize((size, size), Image.LANCZOS)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=int(size * radius_frac), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def circle(img, size):
    img = img.resize((size, size), Image.LANCZOS)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, size - 1, size - 1], fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def main():
    src = Image.open(SRC).convert("RGBA")
    for d, px in DENS.items():
        folder = os.path.join(RES, "mipmap-%s" % d)
        os.makedirs(folder, exist_ok=True)
        base = Image.new("RGBA", (px, px), BG)
        base.alpha_composite(src.resize((px, px), Image.LANCZOS))
        rounded(base, px).save(os.path.join(folder, "ic_launcher.png"))
        circle(base, px).save(os.path.join(folder, "ic_launcher_round.png"))
        # adaptive foreground: 108dp canvas, logo in the ~60% safe zone
        fg_px = int(px * 108 / 48)
        fg = Image.new("RGBA", (fg_px, fg_px), (0, 0, 0, 0))
        inner = int(fg_px * 0.60)
        off = (fg_px - inner) // 2
        fg.alpha_composite(src.resize((inner, inner), Image.LANCZOS), (off, off))
        fg.save(os.path.join(folder, "ic_launcher_foreground.png"))
        print("icons: %s (%dpx)" % (d, px))

    with open(os.path.join(RES, "values", "ic_launcher_background.xml"), "w") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<resources>\n'
                '    <color name="ic_launcher_background">#0b0f1a</color>\n'
                '</resources>\n')
    print("adaptive background set to #0b0f1a")


if __name__ == "__main__":
    main()
