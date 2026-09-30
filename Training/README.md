# MaiLens machine detector training

`D:\桌面文件\训练2` contains 50 machine screenshots but no annotation files. The preparation script creates initial YOLO labels around the machine's outer circular ring and writes a contact sheet for review:

```powershell
& D:\Python312\python.exe Training/prepare_yolo_dataset.py `
  --source 'D:\桌面文件\训练2' `
  --output work/machine-yolo
```

Open `work/machine-yolo/pseudo-label-preview.jpg`. The green rectangle should contain the complete round machine body that the app is supposed to keep stable. Correct any bad boxes with a labeling tool before training. These labels are intentionally treated as a starting point, not ground truth.

Once the preview is correct and `yolo11n.pt` is available:

```powershell
& D:\Python312\python.exe Training/train_yolo.py
```

The script uses motion and scale augmentation, validates on a held-out split, and exports an ONNX model. For iPhone deployment, convert the validated model to Core ML on macOS/CodeMagic and run it through Vision. The detector alone is not the stabilizer: the app still needs a Kalman/optical-flow tracker and a low-pass crop controller to produce the locked look from the model boxes.

## Include the real lock video

The close-up screenshots are not enough for the target composition: the final
video has a smaller machine, large side panels, and hands crossing the display.
Build a mixed dataset with sampled frames from that video:

```powershell
& D:\Python312\python.exe Training/prepare_video_yolo_dataset.py `
  --source 'D:\桌面文件\训练2' `
  --video 'C:\Users\93543\Videos\2026-09-30 05-32-59.mp4' `
  --output work/machine-yolo-video `
  --video-step 15
```

Review `work/machine-yolo-video/pseudo-label-preview.jpg`, then train it with
`--data work/machine-yolo-video/dataset.yaml`. The repository contains the
resulting small detector at `Training/models/machine-lock-yolo11n-video.pt`.
CodeMagic exports that weight to `Resources/MachineDetector.mlpackage` before
building the app. Windows cannot perform this Core ML export, so a local
Windows build uses the contour fallback until the package is generated on the
macOS builder.
