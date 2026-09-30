"""Train and export a small machine detector for MaiLens."""

from __future__ import annotations

import argparse
from pathlib import Path

from ultralytics import YOLO


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, default=Path("work/machine-yolo/dataset.yaml"))
    parser.add_argument("--weights", default="yolo11n.pt")
    parser.add_argument("--project", type=Path, default=Path("work/machine-yolo/runs"))
    parser.add_argument("--epochs", type=int, default=120)
    parser.add_argument("--device", default="0")
    parser.add_argument("--name", default="machine-lock-yolo11n")
    args = parser.parse_args()

    model = YOLO(args.weights)
    run = model.train(
        data=str(args.data),
        imgsz=640,
        epochs=args.epochs,
        batch=-1,
        device=args.device,
        project=str(args.project),
        name=args.name,
        patience=30,
        cache=False,
        workers=4,
        pretrained=True,
        degrees=8,
        translate=0.12,
        scale=0.35,
        shear=3,
        perspective=0.0005,
        fliplr=0.5,
        mosaic=0.35,
        mixup=0.05,
        hsv_h=0.015,
        hsv_s=0.45,
        hsv_v=0.35,
        close_mosaic=15,
        plots=True,
    )
    best = Path(run.save_dir) / "weights" / "best.pt"
    print(f"best_weights: {best}")
    if best.exists():
        export_model = YOLO(str(best))
        onnx_path = export_model.export(format="onnx", imgsz=640, simplify=True, opset=17)
        print(f"onnx: {onnx_path}")


if __name__ == "__main__":
    main()
