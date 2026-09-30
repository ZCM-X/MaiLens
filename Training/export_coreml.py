"""Export the trained MaiLens frame-geometry detector for Vision/Core ML.

Ultralytics deliberately refuses Core ML export on Windows.  CodeMagic runs
this script on its macOS builder before XcodeGen creates the project. The
resulting package is named ``FrameGeometryDetector`` so the app can load it
without generated Swift model classes. It contains ``outer_frame`` and
``inner_screen`` classes.
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from ultralytics import YOLO


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if not args.weights.exists():
        raise SystemExit(f"weights not found: {args.weights}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    exported = Path(
        YOLO(str(args.weights)).export(
            format="coreml",
            imgsz=640,
            nms=True,
            half=False,
            simplify=True,
        )
    )
    if not exported.exists():
        raise SystemExit(f"Ultralytics reported a missing export: {exported}")
    if args.output.exists():
        if args.output.is_dir():
            shutil.rmtree(args.output)
        else:
            args.output.unlink()
    if exported.is_dir():
        shutil.copytree(exported, args.output)
    else:
        shutil.copy2(exported, args.output)
    print(f"coreml: {args.output}")


if __name__ == "__main__":
    main()
