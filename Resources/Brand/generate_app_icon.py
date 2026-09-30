from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024
SCALE = 4
CANVAS = SIZE * SCALE

# A restrained charcoal palette with one industrial signal-yellow accent.
BACKGROUND = (26, 27, 29)
LENS = (31, 32, 34)
RING = (82, 82, 82)
RING_INNER = (58, 58, 58)
MARK = (232, 232, 233)
ACCENT = (255, 214, 10)


def px(value: float) -> int:
    return round(value * SCALE)


def draw_icon() -> Image.Image:
    image = Image.new("RGB", (CANVAS, CANVAS), BACKGROUND)
    draw = ImageDraw.Draw(image)

    center = (px(512), px(492))

    # One clean lens body and two quiet rings keep the mark recognizable at
    # home-screen size without decorative hardware or gradients.
    draw.ellipse(
        (px(184), px(164), px(840), px(820)),
        fill=LENS,
        outline=RING,
        width=px(18),
    )
    draw.ellipse(
        (px(222), px(202), px(802), px(782)),
        outline=RING_INNER,
        width=px(8),
    )

    # The M is a compact monogram for MaiLens. Its open, angular strokes hint
    # at a wide-angle lens while staying crisp in the iOS icon mask.
    m_points = [
        (px(326), px(646)),
        (px(414), px(360)),
        (px(512), px(532)),
        (px(610), px(360)),
        (px(698), px(646)),
    ]
    draw.line(
        m_points,
        fill=MARK,
        width=px(42),
        joint="curve",
    )
    radius = px(21)
    for x, y in (m_points[0], m_points[-1]):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=MARK)

    # A level line with a centered bubble represents horizon stabilization.
    # The short gap around the bubble avoids turning it into a targeting reticle.
    line_y = px(704)
    draw.line((px(324), line_y, px(468), line_y), fill=ACCENT, width=px(14))
    draw.line((px(556), line_y, px(700), line_y), fill=ACCENT, width=px(14))
    endpoint_radius = px(7)
    for x in (px(324), px(468), px(556), px(700)):
        draw.ellipse(
            (x - endpoint_radius, line_y - endpoint_radius,
             x + endpoint_radius, line_y + endpoint_radius),
            fill=ACCENT,
        )
    bubble_radius = px(19)
    draw.ellipse(
        (px(512) - bubble_radius, line_y - bubble_radius,
         px(512) + bubble_radius, line_y + bubble_radius),
        fill=ACCENT,
    )

    return image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


if __name__ == "__main__":
    icon = draw_icon()
    brand_path = ROOT / "Brand" / "MaiLens-AppIcon-1024.png"
    asset_path = ROOT / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"
    icon.save(brand_path, format="PNG", optimize=True)
    icon.save(asset_path, format="PNG", optimize=True)
    print(brand_path)
    print(asset_path)
