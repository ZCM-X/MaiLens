"""Build a two-class dataset for machine-frame geometry.

The classes are independent of the game chart:

* ``outer_frame`` is the cabinet's physical outer ring/body.
* ``inner_screen`` is the playable screen boundary.

Their four side gaps are later used to estimate centring and anisotropic
fisheye correction.  The generated labels are reviewable starting labels;
they do not use the eight variable gameplay judgement markers.
"""

from __future__ import annotations

import argparse
import math
import random
import shutil
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw

from build_screen_dataset import circle_candidates, read_bgr


def box_from_ellipse(cx: float, cy: float, rx: float, ry: float, padding: float = 0.02) -> tuple[float, float, float, float]:
    return (
        min(max(cx, 0.001), 0.999),
        min(max(cy, 0.001), 0.999),
        min(max(2 * rx * (1 + padding), 0.01), 0.999),
        min(max(2 * ry * (1 + padding), 0.01), 0.999),
    )


def choose_inner(image: np.ndarray) -> tuple[float, float, float, float]:
    height, width = image.shape[:2]
    candidates = circle_candidates(image)
    if not candidates:
        raise ValueError("no inner screen contour found")
    expected = 0.305
    plausible = [candidate for candidate in candidates if 0.22 <= candidate[3] / min(width, height) <= 0.36]
    _, cx, cy, radius = min(
        plausible or candidates,
        key=lambda candidate: abs(candidate[3] / min(width, height) - expected) + (1 - candidate[0]) * 0.1,
    )
    return cx / width, cy / height, radius / width, radius / height


def geometry_for(path: Path, image: np.ndarray) -> tuple[tuple[float, float, float, float], tuple[float, float, float, float]]:
    if path.name.lower() == "img_8695.jpg":
        # Explicitly separate the playable ellipse from the white cabinet;
        # the outer fisheye/lens rim is outside this box and is not a target.
        inner = (0.502, 0.508, 0.258, 0.196)
        outer = (0.505, 0.454, 0.302, 0.292)
        return box_from_ellipse(*outer), box_from_ellipse(*inner)

    height, width = image.shape[:2]
    cx, cy, rx, ry = choose_inner(image)
    outer_radius = min(width, height) * 0.47
    outer = (cx, cy, outer_radius / width, outer_radius / height)
    inner = (cx, cy, rx, ry)
    return box_from_ellipse(*outer), box_from_ellipse(*inner)


def yolo_line(outer: tuple[float, float, float, float], inner: tuple[float, float, float, float]) -> str:
    return (
        f"0 {outer[0]:.6f} {outer[1]:.6f} {outer[2]:.6f} {outer[3]:.6f}\n"
        f"1 {inner[0]:.6f} {inner[1]:.6f} {inner[2]:.6f} {inner[3]:.6f}\n"
    )


def draw_review(image: np.ndarray, outer: tuple[float, float, float, float], inner: tuple[float, float, float, float], output: Path) -> None:
    preview = Image.fromarray(cv2.cvtColor(image, cv2.COLOR_BGR2RGB))
    preview.thumbnail((300, 230))
    draw = ImageDraw.Draw(preview)
    for box, colour, label in ((outer, (255, 120, 60), "OUTER"), (inner, (70, 240, 120), "INNER")):
        cx, cy, width, height = box
        x1 = (cx - width / 2) * preview.width
        y1 = (cy - height / 2) * preview.height
        x2 = (cx + width / 2) * preview.width
        y2 = (cy + height / 2) * preview.height
        draw.rectangle((x1, y1, x2, y2), outline=colour, width=max(2, preview.width // 130))
        draw.text((x1 + 4, y1 + 4), label, fill=colour)
    output.parent.mkdir(parents=True, exist_ok=True)
    preview.save(output, quality=90)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--screenshots", type=Path, required=True)
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("work/frame-geometry-yolo-v2"))
    parser.add_argument("--val-ratio", type=float, default=0.2)
    parser.add_argument("--seed", type=int, default=20261001)
    args = parser.parse_args()

    if args.output.exists():
        shutil.rmtree(args.output)
    paths = sorted(args.screenshots.rglob("*.png")) + sorted(args.screenshots.rglob("*.jpg")) + [args.raw]
    randomizer = random.Random(args.seed)
    screenshot_paths = paths[:-1]
    randomizer.shuffle(screenshot_paths)
    val_names = {path.name for path in screenshot_paths[: max(1, round(len(screenshot_paths) * args.val_ratio))]}
    rows: list[tuple[str, Image.Image]] = []

    for path in screenshot_paths + [args.raw]:
        image = read_bgr(path)
        outer, inner = geometry_for(path, image)
        split = "val" if path.name in val_names else "train"
        image_path = args.output / "images" / split / path.name
        label_path = args.output / "labels" / split / f"{path.stem}.txt"
        image_path.parent.mkdir(parents=True, exist_ok=True)
        label_path.parent.mkdir(parents=True, exist_ok=True)
        cv2.imwrite(str(image_path), image)
        label_path.write_text(yolo_line(outer, inner), encoding="utf-8")
        if len(rows) < 60:
            review_path = args.output / "review" / f"{len(rows):03d}-{path.stem}.jpg"
            draw_review(image, outer, inner, review_path)
            rows.append((path.name, Image.open(review_path).convert("RGB")))

    # Make one contact sheet for a quick human check of both classes.
    columns, cell_w, cell_h = 4, 300, 245
    sheet = Image.new("RGB", (columns * cell_w, math.ceil(len(rows) / columns) * cell_h), (28, 31, 34))
    draw = ImageDraw.Draw(sheet)
    for index, (name, image) in enumerate(rows):
        x, y = (index % columns) * cell_w, (index // columns) * cell_h
        sheet.paste(image, (x, y + 2))
        draw.text((x + 5, y + 232), f"{index + 1:02d} {name}", fill="white")
    sheet.save(args.output / "geometry-review.jpg", quality=90)

    yaml = (
        f"path: {args.output.resolve().as_posix()}\n"
        "train: images/train\n"
        "val: images/val\n"
        "names:\n  0: outer_frame\n  1: inner_screen\n"
    )
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "dataset.yaml").write_text(yaml, encoding="utf-8")
    (args.output / "annotation-report.txt").write_text(
        f"screenshots={len(screenshot_paths)}\nraw_fisheye=1\nclasses=outer_frame,inner_screen\nreview={args.output / 'geometry-review.jpg'}\n",
        encoding="utf-8",
    )
    print(f"screenshots: {len(screenshot_paths)}")
    print("raw fisheye: 1")
    print(f"review: {args.output / 'geometry-review.jpg'}")


if __name__ == "__main__":
    main()
