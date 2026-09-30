# MaiLens screen-anchor detector v2

This is the clean first training pass for the automatic lock. It does not use
the old `machine-lock` weights or its labels.

The single class is `screen`: the circular playable display inside the
cabinet. The screen centre is a better lock anchor than hands, buttons, or the
outer lens rim. The dataset builder reads the 50 images in
`D:\桌面文件\训练2` and adds the real fisheye still
`H:\IMG_8695.JPG` with an explicit inner-screen annotation. It writes a
review sheet before training and oversamples the real fisheye image with
label-preserving affine and exposure changes.

```powershell
& D:\Python312\python.exe Training/v2/build_screen_dataset.py `
  --screenshots 'D:\桌面文件\训练2' `
  --raw 'H:\IMG_8695.JPG' `
  --output work/screen-yolo-v2

& D:\Python312\python.exe Training/v2/train_screen.py `
  --data work/screen-yolo-v2/dataset.yaml `
  --weights yolo11n.pt `
  --device 0
```

The current Windows training result is stored as
`Training/models/screen-anchor-yolo11n-v2.pt` and the matching ONNX export is
`Training/models/screen-anchor-yolo11n-v2.onnx`.

The validation score is only a data-pipeline check: the ten validation images
come from the supplied screenshot set and the raw fisheye variants are made
from one still. Before shipping a real-time model, collect several short raw
camera clips with the machine off-centre, partly occluded, and at different
distances, then label those frames and keep entire clips separated between
training and validation.

At runtime, select one candidate using confidence, distance from the previous
centre, and an edge penalty. Never pass every YOLO box directly to the crop
controller; the fisheye rim and ceiling create plausible low-confidence boxes.
