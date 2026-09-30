from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024
SCALE = 4
W = SIZE * SCALE


def point(cx: float, cy: float, radius: float, angle: float) -> tuple[int, int]:
    return (
        round((cx + math.cos(angle) * radius) * SCALE),
        round((cy + math.sin(angle) * radius) * SCALE),
    )


def ellipse_box(cx: float, cy: float, rx: float, ry: float) -> tuple[int, int, int, int]:
    return (
        round((cx - rx) * SCALE),
        round((cy - ry) * SCALE),
        round((cx + rx) * SCALE),
        round((cy + ry) * SCALE),
    )


def draw_icon() -> Image.Image:
    yy, xx = np.mgrid[0:W, 0:W]
    x = xx / SCALE
    y = yy / SCALE

    # Deep blue glass-like background with a gentle teal light behind the lens.
    radial = np.sqrt(((x - 510) / 720) ** 2 + ((y - 430) / 720) ** 2)
    glow = np.clip(1.0 - radial, 0.0, 1.0)[..., None]
    diagonal = np.clip((x + y) / (SIZE * 2), 0.0, 1.0)[..., None]
    edge = np.array([5.0, 13.0, 25.0])
    center = np.array([20.0, 67.0, 82.0])
    tint = np.array([16.0, 27.0, 57.0])
    data = edge + (center - edge) * glow + tint * diagonal * 0.18
    data = np.clip(data, 0, 255).astype(np.uint8)
    image = Image.fromarray(data, mode="RGB")

    # Glow layer behind the hardware rings.
    glow_layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow_layer)
    glow_draw.ellipse(ellipse_box(512, 512, 336, 336), fill=(42, 231, 213, 70))
    glow_layer = glow_layer.filter(ImageFilter.GaussianBlur(42 * SCALE))
    image = Image.alpha_composite(image.convert("RGBA"), glow_layer)

    rings = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(rings)

    # Outer virtual-gimbal frame.
    d.ellipse(ellipse_box(512, 512, 337, 337), outline=(97, 245, 224, 235), width=15 * SCALE)
    d.ellipse(ellipse_box(512, 512, 310, 310), outline=(61, 173, 195, 150), width=4 * SCALE)
    d.arc(ellipse_box(512, 512, 366, 366), 205, 330, fill=(110, 119, 255, 210), width=12 * SCALE)
    d.arc(ellipse_box(512, 512, 366, 366), 25, 145, fill=(54, 222, 201, 170), width=8 * SCALE)

    # Three-axis gimbal arcs. They read as a stabilised camera without showing
    # a literal phone or a machine target.
    d.arc(ellipse_box(512, 512, 394, 230), 198, 342, fill=(101, 123, 246, 220), width=10 * SCALE)
    d.arc(ellipse_box(512, 512, 230, 394), 16, 164, fill=(50, 219, 206, 220), width=10 * SCALE)
    d.arc(ellipse_box(512, 512, 284, 352), 115, 248, fill=(80, 228, 215, 170), width=6 * SCALE)

    # A small alignment tick on each axis.
    for angle, color in ((-math.pi / 2, (179, 255, 240, 235)),
                         (0, (109, 177, 255, 220)),
                         (math.pi / 2, (179, 255, 240, 235)),
                         (math.pi, (109, 177, 255, 220))):
        a = point(512, 512, 346, angle)
        b = point(512, 512, 369, angle)
        d.line((a, b), fill=color, width=7 * SCALE)

    image = Image.alpha_composite(image, rings)

    # Lens body: layered radial glass with a crisp cyan rim.
    lens = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lens)
    for radius in range(255, 218, -3):
        t = (255 - radius) / 37.0
        color = (9 + round(8 * t), 27 + round(45 * t), 52 + round(70 * t), 255)
        ld.ellipse(ellipse_box(512, 512, radius, radius), fill=color)
    ld.ellipse(ellipse_box(248, 248, 248, 248), outline=(158, 255, 239, 230), width=9 * SCALE)
    ld.ellipse(ellipse_box(235, 235, 235, 235), outline=(64, 184, 225, 150), width=5 * SCALE)

    # Eight-blade iris. The alternating radii create a recognisable lens at
    # small icon sizes and keep the centre open for the stabilizer dot.
    iris: list[tuple[int, int]] = []
    for index in range(16):
        angle = -math.pi / 2 + index * math.pi / 8
        radius = 166 if index % 2 == 0 else 132
        iris.append(point(512, 512, radius, angle))
    ld.polygon(iris, fill=(18, 118, 143, 245), outline=(105, 245, 222, 235))
    ld.ellipse(ellipse_box(512, 512, 92, 92), fill=(4, 17, 31, 255), outline=(111, 230, 215, 225), width=7 * SCALE)
    ld.ellipse(ellipse_box(512, 512, 27, 27), fill=(147, 255, 226, 255))
    ld.ellipse(ellipse_box(500, 488, 32, 22), fill=(205, 255, 248, 135))

    # Glass highlight and a restrained violet reflection give the lens depth.
    ld.arc(ellipse_box(512, 512, 211, 211), 205, 320, fill=(224, 255, 251, 210), width=11 * SCALE)
    ld.arc(ellipse_box(512, 512, 197, 197), 28, 116, fill=(128, 116, 255, 180), width=9 * SCALE)
    image = Image.alpha_composite(image, lens)

    # Final soft highlight, kept away from the edges so iOS masking is safe.
    shine = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shine)
    sd.ellipse(ellipse_box(405, 350, 90, 48), fill=(186, 255, 244, 40))
    shine = shine.filter(ImageFilter.GaussianBlur(20 * SCALE))
    image = Image.alpha_composite(image, shine)

    return image.convert("RGB").resize((SIZE, SIZE), Image.Resampling.LANCZOS)


if __name__ == "__main__":
    icon = draw_icon()
    brand_path = ROOT / "Brand" / "MaiLens-AppIcon-1024.png"
    asset_path = ROOT / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"
    icon.save(brand_path, format="PNG", optimize=True)
    icon.save(asset_path, format="PNG", optimize=True)
    print(brand_path)
    print(asset_path)
