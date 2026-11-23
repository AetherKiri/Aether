#!/usr/bin/env python3
"""Regenerate app icons from the Aether-Branding checkout (requires Pillow)."""
import argparse
from pathlib import Path
import shutil

from PIL import Image, PngImagePlugin

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "apps/godot_app/assets"
COMPOSER = ROOT / "tools/branding/AetherAppIcon.icon"
ASTRYX_SIZES = (40, 58, 60, 76, 80, 87, 114, 120, 128, 136, 152, 167, 180, 192)
CLASSIC_SIZES = (*ASTRYX_SIZES, 20, 29, 1024)
DARK_BACKGROUND = (41, 44, 53)


def save_png(image, path):
    metadata = PngImagePlugin.PngInfo()
    metadata.add(b"sRGB", b"\x00")
    image.save(path, pnginfo=metadata, optimize=True)


def package(output, sizes, square, rounded, mark, background, *, launcher=None):
    save_png(rounded, launcher or output / "icon.png")
    save_png(square, output / "app_store_1024x1024.png")
    for size in sizes:
        image = square.resize((size, size), Image.Resampling.LANCZOS)
        save_png(image, output / f"icon_{size}x{size}.png")

    # The artwork (including its orbits) fits in Android's central 66 dp
    # circle on the 108 dp adaptive canvas at 4 px/dp.
    foreground = Image.new("RGBA", (432, 432))
    foreground.paste(mark.resize((280, 280), Image.Resampling.LANCZOS), (76, 76))
    save_png(foreground, output / "icon_adaptive_fg.png")
    save_png(Image.new("RGB", foreground.size, background), output / "icon_adaptive_bg.png")


def generate(branding):
    source = branding / "Aether-Icon"

    def load(variant):
        with Image.open(source / f"png/{variant}/aether-icon-{variant}-1024.png") as image:
            return image.copy()

    square = load("app-square").convert("RGB")
    rounded = load("app-rounded").convert("RGBA")
    mark_dark = load("mark-dark").convert("RGBA")
    mark_light = load("mark-light").convert("RGBA")
    light_background = square.getpixel((0, 0))
    dark_square = Image.new("RGB", square.size, DARK_BACKGROUND)
    dark_square.paste(mark_light, mask=mark_light.getchannel("A"))
    dark_rounded = dark_square.copy()
    dark_rounded.putalpha(rounded.getchannel("A"))

    icons = ASSETS / "icons"
    package(icons, CLASSIC_SIZES, square, rounded, mark_dark, light_background,
            launcher=ASSETS / "icon.png")
    package(icons / "astryx", ASTRYX_SIZES, square, rounded, mark_dark, light_background)
    package(icons / "astryx/dark", ASTRYX_SIZES, dark_square, dark_rounded, mark_light, DARK_BACKGROUND)

    shutil.copyfile(source / "svg/aether-icon-app-rounded.svg", ASSETS / "icon.svg")
    shutil.copytree(source / "iOS/AetherAppIcon.icon", COMPOSER, dirs_exist_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("branding", type=Path, help="path to the Aether-Branding checkout")
    generate(parser.parse_args().branding)
