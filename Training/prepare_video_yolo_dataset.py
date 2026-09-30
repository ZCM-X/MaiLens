"""Build a MaiLens machine detector dataset from screenshots and video frames.

The still images in ``D:\桌面文件\训练2`` show the machine close up, while the
reference lock video contains the harder case: the machine is smaller, off
centre, and partly covered by hands.  This helper samples that video, creates
initial boxes from the machine's circular outer ring, and combines both
sources into one reviewable YOLO dataset.

The generated labels are still pseudo labels.  Open the contact sheet and
correct any bad boxes before treating the model as production quality.
"""

from __future__ import annotations

import argparse
import random
import shutil
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw

from prepare_yolo_dataset import find_outer_ring, read_image, yolo_box


@dataclass
class Record:
    name: str
    group: str
    image: np.ndarray
    source_path: Path | None = None


def load_stills(source: Path) -> list[Record]:
    records: list[Record] = []
    for path in sorted(source.rglob("*")):
        if path.suffix.lower() not in {".png", ".jpg", ".jpeg"}:
            continue
        try:
            image = read_image(path)
        except Exception as error:
            print(f"skip {path}: {error}")
            continue
        records.append(Record(name=path.name, group="stills", image=image, source_path=path))
    return records


def load_video(path: Path, step: int, max_frames: int) -> list[Record]:
    capture = cv2.VideoCapture(str(path))
    if not capture.isOpened():
        raise RuntimeError(f"Cannot open video: {path}")

    records: list[Record] = []
    frame_index = 0
    while len(records) < max_frames:
        ok, frame = capture.read()
        if not ok:
            break
        if frame_index % step == 0:
            records.append(
                Record(
                    name=f"{path.stem}_frame{frame_index:06d}.jpg",
                    group=path.stem,
                    image=frame,
                )
            )
        frame_index += 1
    capture.release()
    return records


def split_records(records: list[Record], val_ratio: float, seed: int) -> tuple[list[Record], list[Record]]:
    shuffled = list(records)
    random.Random(seed).shuffle(shuffled)
    val_count = max(1, round(len(shuffled) * val_ratio))
    return shuffled[val_count:], shuffled[:val_count]


def make_preview(rows: list[tuple[str, Image.Image, str]], output: Path) -> None:
    cell_width, cell_height = 240, 225
    columns = 5
    if not rows:
        return
    sheet = Image.new(
        "RGB",
        (columns * cell_width, ((len(rows) + columns - 1) // columns) * cell_height),
        (38, 41, 45),
    )
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
    parser.add_argument("--source", type=Path, required=True, help="Folder containing still images")
    parser.add_argument("--video", type=Path, action="append", required=True, help="Video to sample")
    parser.add_argument("--output", type=Path, default=Path("work/machine-yolo-video"))
    parser.add_argument("--video-step", type=int, default=15, help="Take one frame every N source frames")
    parser.add_argument("--max-video-frames", type=int, default=120)
    parser.add_argument("--val-ratio", type=float, default=0.2)
    parser.add_argument("--padding", type=float, default=0.04)
    parser.add_argument("--preview-limit", type=int, default=80)
    parser.add_argument("--seed", type=int, default=20260930)
    args = parser.parse_args()
    if args.video_step < 1:
        raise SystemExit("--video-step must be at least 1")

    records = load_stills(args.source)
    for video in args.video:
        records.extend(load_video(video, args.video_step, args.max_video_frames))
    if not records:
        raise SystemExit("No source images or video frames were loaded")

    train_records, val_records = split_records(records, args.val_ratio, args.seed)
    split_map = {id(record): "train" for record in train_records}
    split_map.update({id(record): "val" for record in val_records})

    image_root = args.output / "images"
    label_root = args.output / "labels"
    if args.output.exists():
        shutil.rmtree(args.output)
    for split in ("train", "val"):
        (image_root / split).mkdir(parents=True, exist_ok=True)
        (label_root / split).mkdir(parents=True, exist_ok=True)

    preview_rows: list[tuple[str, Image.Image, str]] = []
    missing: list[str] = []
    labelled = 0
    for index, record in enumerate(records):
        circle = find_outer_ring(record.image)
        if circle is None:
            missing.append(record.name)
            continue
        cx, cy, radius = circle
        split = split_map[id(record)]
        image_path = image_root / split / record.name
        if record.source_path is not None:
            shutil.copy2(record.source_path, image_path)
        else:
            rgb = cv2.cvtColor(record.image, cv2.COLOR_BGR2RGB)
            Image.fromarray(rgb).save(image_path, quality=94)

        height, width = record.image.shape[:2]
        (label_root / split / f"{Path(record.name).stem}.txt").write_text(
            yolo_box(cx, cy, radius, width, height, args.padding), encoding="utf-8"
        )
        labelled += 1

        if len(preview_rows) < args.preview_limit:
            preview = Image.fromarray(cv2.cvtColor(record.image, cv2.COLOR_BGR2RGB))
            draw = ImageDraw.Draw(preview)
            x1 = max(0, int(cx - radius * (1 + args.padding)))
            y1 = max(0, int(cy - radius * (1 + args.padding)))
            x2 = min(width, int(cx + radius * (1 + args.padding)))
            y2 = min(height, int(cy + radius * (1 + args.padding)))
            draw.rectangle((x1, y1, x2, y2), outline=(40, 230, 80), width=max(2, width // 500))
            preview_rows.append((record.name, preview, f"box {x1},{y1},{x2},{y2}"))

    dataset_yaml = (
        f"path: {args.output.resolve().as_posix()}\n"
        "train: images/train\n"
        "val: images/val\n"
        "names:\n  0: machine\n"
    )
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "dataset.yaml").write_text(dataset_yaml, encoding="utf-8")
    make_preview(preview_rows, args.output / "pseudo-label-preview.jpg")
    report = [
        f"source_records: {len(records)}",
        f"labelled_records: {labelled}",
        f"train_records: {sum(split_map[id(r)] == 'train' for r in records)}",
        f"val_records: {sum(split_map[id(r)] == 'val' for r in records)}",
        f"missing_labels: {len(missing)}",
        f"preview_records: {len(preview_rows)}",
    ]
    if missing:
        report.append("missing_files:")
        report.extend(f"  - {name}" for name in missing)
    (args.output / "prepare-report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print("\n".join(report))
    print(f"preview: {args.output / 'pseudo-label-preview.jpg'}")


if __name__ == "__main__":
    main()
