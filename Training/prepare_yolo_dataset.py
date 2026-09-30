"""Prepare a YOLO detection dataset for the round game-machine display.

The supplied training2 folder contains images but no annotation files. This
script creates a first, reviewable set of pseudo labels from the machine's
outer circular ring. Keep the generated preview and correct any bad boxes in a
labeling tool before treating the model as production quality.
"""

from __future__ import annotations

import argparse
import random
import shutil
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw


def find_outer_ring(image: np.ndarray) -> tuple[int, int, int] | None:
    height, width = image.shape[:2]
    short_side = min(height, width)
    # The first four screenshots are small crops; the remaining images are
    # larger crops. Work on a bounded image so Hough is fast and consistent.
    scale = min(1.0, 720.0 / max(height, width))
    reduced = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(reduced, cv2.COLOR_BGR2GRAY)
    gray = cv2.medianBlur(gray, 7)
    reduced_short = min(reduced.shape[:2])
    circles = cv2.HoughCircles(
        gray,
        cv2.HOUGH_GRADIENT,
        dp=1.15,
        minDist=max(reduced_short * 0.25, 48),
        param1=110,
        param2=28,
        minRadius=max(int(reduced_short * 0.34), 30),
        maxRadius=max(int(reduced_short * 0.68), 32),
    )
    candidates: list[tuple[float, float, float, float]] = []
    if circles is not None:
        for cx, cy, radius in np.round(circles[0]).astype(int):
            cx /= scale
            cy /= scale
            radius /= scale
            # Reject circles that are clearly an overlay or a hand. The target
            # ring should overlap the centre region of the image.
            distance = float(np.hypot(cx - width / 2, cy - height / 2) / short_side)
            if distance > 0.45 or radius < short_side * 0.24 or radius > short_side * 0.75:
                continue
            candidates.append((distance, -radius, cx, cy))
    if not candidates:
        return None
    _, negative_radius, cx, cy = min(candidates)
    return int(round(cx)), int(round(cy)), int(round(-negative_radius))


def read_image(path: Path) -> np.ndarray:
    # cv2.imread cannot open some non-ASCII Windows paths. PIL keeps the
    # original path handling and gives OpenCV a normal in-memory BGR image.
    rgb = np.asarray(Image.open(path).convert("RGB"))
    return cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)


def yolo_box(cx: int, cy: int, radius: int, width: int, height: int, padding: float) -> str:
    x1 = max(0.0, cx - radius * (1.0 + padding))
    y1 = max(0.0, cy - radius * (1.0 + padding))
    x2 = min(float(width), cx + radius * (1.0 + padding))
    y2 = min(float(height), cy + radius * (1.0 + padding))
    box_cx = (x1 + x2) / 2.0 / width
    box_cy = (y1 + y2) / 2.0 / height
    box_w = (x2 - x1) / width
    box_h = (y2 - y1) / height
    return f"0 {box_cx:.6f} {box_cy:.6f} {box_w:.6f} {box_h:.6f}\n"


def make_preview(rows: list[tuple[str, Image.Image, str]], output: Path) -> None:
    cell_width, cell_height = 240, 225
    columns = 5
    sheet = Image.new("RGB", (columns * cell_width, ((len(rows) + columns - 1) // columns) * cell_height), (38, 41, 45))
    draw = ImageDraw.Draw(sheet)
    for index, (name, image, label) in enumerate(rows):
        x = (index % columns) * cell_width
        y = (index // columns) * cell_height
        image.thumbnail((cell_width - 10, 190))
        sheet.paste(image, (x + (cell_width - image.width) // 2, y + 2))
        draw.text((x + 5, y + 195), f"{index + 1:02d} {name}", fill="white")
        draw.text((x + 5, y + 208), label, fill=(170, 220, 170))
    sheet.save(output, quality=92)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True, help="Folder containing source PNG/JPG images")
    parser.add_argument("--output", type=Path, default=Path("work/machine-yolo"))
    parser.add_argument("--val-ratio", type=float, default=0.2)
    parser.add_argument("--padding", type=float, default=0.04)
    parser.add_argument("--seed", type=int, default=20260930)
    args = parser.parse_args()

    files = sorted(p for p in args.source.rglob("*") if p.suffix.lower() in {".png", ".jpg", ".jpeg"})
    if not files:
        raise SystemExit(f"No image files found under {args.source}")
    random.Random(args.seed).shuffle(files)

    image_root = args.output / "images"
    label_root = args.output / "labels"
    for split in ("train", "val"):
        (image_root / split).mkdir(parents=True, exist_ok=True)
        (label_root / split).mkdir(parents=True, exist_ok=True)

    preview_rows: list[tuple[str, Image.Image, str]] = []
    missing: list[str] = []
    labelled: list[tuple[Path, tuple[int, int, int]]] = []
    for path in files:
        try:
            image = read_image(path)
        except Exception:
            missing.append(path.name)
            continue
        circle = find_outer_ring(image)
        if circle is None:
            missing.append(path.name)
            continue
        labelled.append((path, circle))

    val_count = max(1, round(len(labelled) * args.val_ratio))
    val_names = {path.name for path, _ in labelled[:val_count]}
    for path, (cx, cy, radius) in labelled:
        split = "val" if path.name in val_names else "train"
        target_image = image_root / split / path.name
        shutil.copy2(path, target_image)
        image = read_image(path)
        height, width = image.shape[:2]
        label = yolo_box(cx, cy, radius, width, height, args.padding)
        (label_root / split / f"{path.stem}.txt").write_text(label, encoding="utf-8")

        preview = Image.open(path).convert("RGB")
        draw = ImageDraw.Draw(preview)
        x1 = max(0, int(cx - radius * (1 + args.padding)))
        y1 = max(0, int(cy - radius * (1 + args.padding)))
        x2 = min(width, int(cx + radius * (1 + args.padding)))
        y2 = min(height, int(cy + radius * (1 + args.padding)))
        draw.rectangle((x1, y1, x2, y2), outline=(40, 230, 80), width=max(2, width // 220))
        preview_rows.append((path.name, preview, f"box {x1},{y1},{x2},{y2}"))

    dataset_yaml = f"path: {args.output.resolve().as_posix()}\ntrain: images/train\nval: images/val\nnames:\n  0: machine\n"
    (args.output / "dataset.yaml").write_text(dataset_yaml, encoding="utf-8")
    make_preview(preview_rows, args.output / "pseudo-label-preview.jpg")
    report = [
        f"source_images: {len(files)}",
        f"labelled_images: {len(labelled)}",
        f"train_images: {len(labelled) - val_count}",
        f"val_images: {val_count}",
        f"missing_labels: {len(missing)}",
    ]
    if missing:
        report.append("missing_files:")
        report.extend(f"  - {name}" for name in missing)
    (args.output / "prepare-report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print("\n".join(report))
    print(f"preview: {args.output / 'pseudo-label-preview.jpg'}")


if __name__ == "__main__":
    main()
