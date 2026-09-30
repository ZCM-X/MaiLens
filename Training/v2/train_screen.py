"""Train and evaluate the clean screen-anchor detector."""

from __future__ import annotations

import argparse
from pathlib import Path

from ultralytics import YOLO


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, default=Path("work/screen-yolo-v2/dataset.yaml"))
    parser.add_argument("--weights", type=Path, default=Path("yolo11n.pt"))
    parser.add_argument("--project", type=Path, default=Path("work/screen-yolo-v2/runs"))
    parser.add_argument("--epochs", type=int, default=100)
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
        name="screen-anchor-yolo11n",
        patience=25,
        cache=False,
        workers=0,
        pretrained=True,
        # The target is circular but the camera can be tilted and the crop
        # can move, so keep moderate geometric augmentation.
        degrees=10,
        translate=0.12,
        scale=0.35,
        shear=4,
        perspective=0.0008,
        fliplr=0.5,
        mosaic=0.25,
        mixup=0.0,
        hsv_h=0.02,
        hsv_s=0.55,
        hsv_v=0.40,
        close_mosaic=15,
        plots=True,
    )
    best = Path(run.save_dir) / "weights" / "best.pt"
    print(f"best_weights: {best}")
    if not best.exists():
        return

    trained = YOLO(str(best))
    print("validation:")
    metrics = trained.val(data=str(args.data), imgsz=640, device=args.device, workers=0, plots=True)
    print(f"map50={float(metrics.box.map50):.4f} map50_95={float(metrics.box.map):.4f}")
    print("raw-fisheye prediction:")
    results = trained.predict(source="H:/IMG_8695.JPG", imgsz=640, conf=0.15, device=args.device, save=True, project=str(args.project), name="raw-fisheye-check", verbose=False)
    for result in results:
        for box, confidence in zip(result.boxes.xyxy.tolist(), result.boxes.conf.tolist()):
            print(f"conf={confidence:.4f} xyxy={[round(value, 1) for value in box]}")
    onnx_path = trained.export(format="onnx", imgsz=640, simplify=True, opset=17)
    print(f"onnx: {onnx_path}")


if __name__ == "__main__":
    main()
