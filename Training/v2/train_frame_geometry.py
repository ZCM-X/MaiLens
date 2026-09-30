"""Train the outer-frame/inner-screen geometry detector."""

from __future__ import annotations

import argparse
from pathlib import Path

from ultralytics import YOLO


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, default=Path("work/frame-geometry-yolo-v2/dataset.yaml"))
    parser.add_argument("--weights", type=Path, default=Path("yolo11n.pt"))
    parser.add_argument("--project", type=Path, default=Path("work/frame-geometry-yolo-v2/runs"))
    parser.add_argument("--epochs", type=int, default=80)
    parser.add_argument("--device", default="0")
    args = parser.parse_args()

    model = YOLO(str(args.weights))
    run = model.train(
        data=str(args.data),
        imgsz=640,
        epochs=args.epochs,
        batch=16,
        device=args.device,
        project=str(args.project),
        name="frame-geometry-yolo11n",
        patience=20,
        cache=False,
        workers=0,
        pretrained=True,
        degrees=8,
        translate=0.10,
        scale=0.30,
        shear=3,
        perspective=0.0006,
        fliplr=0.5,
        mosaic=0.20,
        mixup=0.0,
        hsv_h=0.02,
        hsv_s=0.50,
        hsv_v=0.35,
        close_mosaic=12,
        plots=True,
    )
    best = Path(run.save_dir) / "weights" / "best.pt"
    print(f"best_weights: {best}")
    if not best.exists():
        return
    trained = YOLO(str(best))
    metrics = trained.val(data=str(args.data), imgsz=640, device=args.device, workers=0, plots=True)
    print(f"map50={float(metrics.box.map50):.4f} map50_95={float(metrics.box.map):.4f}")
    results = trained.predict(source="H:/IMG_8695.JPG", imgsz=640, conf=0.20, device=args.device, save=True, project=str(args.project), name="raw-geometry-check", verbose=False)
    for result in results:
        for box, confidence, category in zip(result.boxes.xyxy.tolist(), result.boxes.conf.tolist(), result.boxes.cls.tolist()):
            print(f"class={int(category)} conf={confidence:.4f} xyxy={[round(value, 1) for value in box]}")
    onnx_path = trained.export(format="onnx", imgsz=640, simplify=True, opset=17)
    print(f"onnx: {onnx_path}")


if __name__ == "__main__":
    main()
