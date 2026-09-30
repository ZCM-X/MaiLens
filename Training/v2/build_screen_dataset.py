"""Build a clean MaiLens screen-anchor dataset.

This is intentionally independent of the first machine detector experiment.
The model has one class, ``screen``: the circular playable display inside the
cabinet.  The screen is the most useful visual anchor for the later virtual
gimbal because its centre and diameter are stable while hands and the bezel
change appearance.

The source screenshots do not contain annotation files.  OpenCV proposes a
circle for each screenshot, and the script writes a review sheet before any
training is started.  The raw fisheye still is given an explicit annotation
because generic Hough settings otherwise prefer the outer lens rim.
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


CLASS_NAME = "screen"


def read_bgr(path: Path) -> np.ndarray:
    rgb = np.asarray(Image.open(path).convert("RGB"))
    return cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)


def circle_candidates(image: np.ndarray) -> list[tuple[float, float, float, float]]:
    """Return central circle candidates as (score, cx, cy, radius)."""
    height, width = image.shape[:2]
    scale = min(1.0, 960.0 / max(height, width))
    reduced = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(reduced, cv2.COLOR_BGR2GRAY)
    gray = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8)).apply(gray)
    gray = cv2.GaussianBlur(gray, (5, 5), 0)
    short_side = min(reduced.shape[:2])
    circles = cv2.HoughCircles(
        gray,
        cv2.HOUGH_GRADIENT,
        dp=1.15,
        minDist=max(short_side * 0.18, 40),
        param1=110,
        param2=28,
        minRadius=max(int(short_side * 0.18), 24),
        maxRadius=max(int(short_side * 0.62), 30),
    )
    if circles is None:
        return []

    edges = cv2.Canny(gray, 70, 150)
    output: list[tuple[float, float, float, float]] = []
    for cx, cy, radius in np.asarray(circles[0], dtype=np.float32):
        cx /= scale
        cy /= scale
        radius /= scale
        distance = math.hypot(cx - width / 2.0, cy - height / 2.0) / min(width, height)
        if distance > 0.25 or radius < min(width, height) * 0.15:
            continue

        # Sample the edge map around the circumference.  This rejects the
        # small bright hand/game-art circles that happen to be near centre.
        sample_count = 96
        hits = 0
        for angle in np.linspace(0, 2 * math.pi, sample_count, endpoint=False):
            x = int(round((cx * scale) + math.cos(angle) * radius * scale))
            y = int(round((cy * scale) + math.sin(angle) * radius * scale))
            if 2 <= x < edges.shape[1] - 2 and 2 <= y < edges.shape[0] - 2:
                if np.max(edges[y - 2 : y + 3, x - 2 : x + 3]) > 0:
                    hits += 1
        support = hits / sample_count
        # Prefer a centred, well-supported circle, with a mild preference for
        # the largest circle only after the geometry has been scored.
        score = support * 0.68 + max(0.0, 1.0 - distance / 0.25) * 0.27 + min(radius / min(width, height), 0.7) * 0.05
        output.append((score, cx, cy, radius))
    return sorted(output, reverse=True)


def circle_box(cx: float, cy: float, radius: float, width: int, height: int, padding: float = 0.025) -> tuple[float, float, float, float]:
    r = radius * (1.0 + padding)
    x1 = max(0.0, cx - r)
    y1 = max(0.0, cy - r)
    x2 = min(float(width), cx + r)
    y2 = min(float(height), cy + r)
    return ((x1 + x2) / 2 / width, (y1 + y2) / 2 / height, (x2 - x1) / width, (y2 - y1) / height)


def yolo_line(box: tuple[float, float, float, float]) -> str:
    return f"0 {box[0]:.6f} {box[1]:.6f} {box[2]:.6f} {box[3]:.6f}\n"


def put_record(root: Path, split: str, name: str, image: np.ndarray, box: tuple[float, float, float, float]) -> None:
    image_path = root / "images" / split / name
    label_path = root / "labels" / split / f"{Path(name).stem}.txt"
    image_path.parent.mkdir(parents=True, exist_ok=True)
    label_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(image_path), image, [cv2.IMWRITE_JPEG_QUALITY, 94])
    label_path.write_text(yolo_line(box), encoding="utf-8")


def augment_raw(image: np.ndarray, box: tuple[float, float, float, float], rng: random.Random, index: int) -> tuple[np.ndarray, tuple[float, float, float, float]]:
    """Make a deployment-domain variant and transform its box exactly."""
    height, width = image.shape[:2]
    angle = rng.uniform(-9.0, 9.0)
    scale = rng.uniform(0.84, 1.18)
    shift_x = rng.uniform(-0.075, 0.075) * width
    shift_y = rng.uniform(-0.075, 0.075) * height
    matrix = cv2.getRotationMatrix2D((width / 2.0, height / 2.0), angle, scale)
    matrix[:, 2] += (shift_x, shift_y)
    transformed = cv2.warpAffine(
        image,
        matrix,
        (width, height),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_REFLECT_101,
    )

    x, y, w, h = box
    corners = np.array(
        [[(x - w / 2) * width, (y - h / 2) * height],
         [(x + w / 2) * width, (y - h / 2) * height],
         [(x + w / 2) * width, (y + h / 2) * height],
         [(x - w / 2) * width, (y + h / 2) * height]],
        dtype=np.float32,
    )
    transformed_corners = cv2.transform(corners[None, :, :], matrix)[0]
    x1 = float(np.clip(transformed_corners[:, 0].min(), 0, width - 1))
    y1 = float(np.clip(transformed_corners[:, 1].min(), 0, height - 1))
    x2 = float(np.clip(transformed_corners[:, 0].max(), 1, width))
    y2 = float(np.clip(transformed_corners[:, 1].max(), 1, height))

    # Exposure and white balance vary substantially under arcade lighting.
    hsv = cv2.cvtColor(transformed, cv2.COLOR_BGR2HSV).astype(np.float32)
    hsv[:, :, 1] *= rng.uniform(0.80, 1.20)
    hsv[:, :, 2] *= rng.uniform(0.72, 1.22)
    transformed = cv2.cvtColor(np.clip(hsv, 0, 255).astype(np.uint8), cv2.COLOR_HSV2BGR)
    if index % 3 == 0:
        noise = np.random.default_rng(20261001 + index).normal(0, 2.2, transformed.shape).astype(np.float32)
        transformed = np.clip(transformed.astype(np.float32) + noise, 0, 255).astype(np.uint8)
    return transformed, ((x1 + x2) / 2 / width, (y1 + y2) / 2 / height, (x2 - x1) / width, (y2 - y1) / height)


def make_review(rows: list[tuple[str, Image.Image, tuple[int, int, int, int]]], path: Path) -> None:
    cell_w, cell_h, columns = 280, 240, 4
    sheet = Image.new("RGB", (columns * cell_w, math.ceil(len(rows) / columns) * cell_h), (28, 31, 34))
    draw = ImageDraw.Draw(sheet)
    for index, (name, image, rect) in enumerate(rows):
        x = (index % columns) * cell_w
        y = (index // columns) * cell_h
        image = image.copy()
        image.thumbnail((cell_w - 12, 205))
        # Rectangles are drawn before thumbnailing in the caller, so use the
        # already rendered image when this helper is called.
        sheet.paste(image, (x + (cell_w - image.width) // 2, y + 2))
        draw.text((x + 5, y + 211), f"{index + 1:02d} {name}", fill="white")
        draw.text((x + 5, y + 226), f"box {rect[0]},{rect[1]},{rect[2]},{rect[3]}", fill=(160, 225, 170))
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path, quality=92)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--screenshots", type=Path, required=True)
    parser.add_argument("--raw", type=Path, required=True, help="One real fisheye still from the phone/lens")
    parser.add_argument("--output", type=Path, default=Path("work/screen-yolo-v2"))
    parser.add_argument("--val-ratio", type=float, default=0.2)
    parser.add_argument("--seed", type=int, default=20261001)
    args = parser.parse_args()

    if args.output.exists():
        shutil.rmtree(args.output)
    randomizer = random.Random(args.seed)
    screenshot_paths = sorted(args.screenshots.rglob("*.png")) + sorted(args.screenshots.rglob("*.jpg"))
    if not screenshot_paths:
        raise SystemExit("No screenshot images found")

    labelled: list[tuple[Path, np.ndarray, tuple[float, float, float, float]]] = []
    review_rows: list[tuple[str, Image.Image, tuple[int, int, int, int]]] = []
    for path in screenshot_paths:
        image = read_bgr(path)
        candidates = circle_candidates(image)
        if not candidates:
            raise SystemExit(f"No screen circle found in {path}")
        _, cx, cy, radius = candidates[0]
        height, width = image.shape[:2]
        box = circle_box(cx, cy, radius, width, height)
        labelled.append((path, image, box))
        preview = Image.fromarray(cv2.cvtColor(image, cv2.COLOR_BGR2RGB))
        preview.thumbnail((260, 205))
        # Draw in thumbnail coordinates for an unambiguous review sheet.
        draw = ImageDraw.Draw(preview)
        sx, sy = preview.width / width, preview.height / height
        x1 = int((cx - radius * 1.025) * sx); y1 = int((cy - radius * 1.025) * sy)
        x2 = int((cx + radius * 1.025) * sx); y2 = int((cy + radius * 1.025) * sy)
        draw.rectangle((x1, y1, x2, y2), outline=(40, 240, 80), width=max(2, preview.width // 180))
        review_rows.append((path.name, preview, (x1, y1, x2, y2)))

    val_count = max(1, round(len(labelled) * args.val_ratio))
    shuffled = list(labelled)
    randomizer.shuffle(shuffled)
    val_paths = {record[0].name for record in shuffled[:val_count]}
    for path, image, box in labelled:
        put_record(args.output, "val" if path.name in val_paths else "train", path.name, image, box)

    # The raw image is deliberately in train: it is the deployment domain.
    # Its explicit annotation prevents the outer fisheye rim from becoming a
    # false target.  Transformed copies make the one real still useful without
    # pretending that a synthetic validation score is real-world accuracy.
    raw = read_bgr(args.raw)
    raw_box = (0.502, 0.508, 0.515, 0.392)
    put_record(args.output, "train", "raw-fisheye.jpg", raw, raw_box)
    # Oversample the real camera domain.  One raw still among fifty screen
    # captures is otherwise ignored by the detector's classification loss.
    for index in range(48):
        variant, variant_box = augment_raw(raw, raw_box, randomizer, index)
        split = "val" if index >= 40 else "train"
        put_record(args.output, split, f"raw-fisheye-aug-{index:03d}.jpg", variant, variant_box)
    raw_preview = Image.fromarray(cv2.cvtColor(raw, cv2.COLOR_BGR2RGB))
    raw_preview.thumbnail((260, 205))
    rd = ImageDraw.Draw(raw_preview)
    x, y, w, h = raw_box
    rx1, ry1 = int((x - w / 2) * raw_preview.width), int((y - h / 2) * raw_preview.height)
    rx2, ry2 = int((x + w / 2) * raw_preview.width), int((y + h / 2) * raw_preview.height)
    rd.rectangle((rx1, ry1, rx2, ry2), outline=(40, 240, 80), width=3)
    review_rows.append((args.raw.name, raw_preview, (rx1, ry1, rx2, ry2)))

    yaml = f"path: {args.output.resolve().as_posix()}\ntrain: images/train\nval: images/val\nnames:\n  0: {CLASS_NAME}\n"
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "dataset.yaml").write_text(yaml, encoding="utf-8")
    make_review(review_rows, args.output / "annotation-review.jpg")
    (args.output / "annotation-report.txt").write_text(
        f"screenshots={len(labelled)}\nval={val_count}\nraw_train=1\nreview={args.output / 'annotation-review.jpg'}\n",
        encoding="utf-8",
    )
    print(f"screenshots: {len(labelled)}")
    print(f"validation screenshots: {val_count}")
    print("raw fisheye: 1 (explicit inner-screen box)")
    print(f"review: {args.output / 'annotation-review.jpg'}")


if __name__ == "__main__":
    main()
