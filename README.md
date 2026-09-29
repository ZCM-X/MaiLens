# MaiLens

MaiLens is an iPhone app for a clip-on fisheye lens on the iPhone 15 Pro Max 0.5× camera. It captures the rear ultra-wide camera, corrects the lens in Metal, and can automatically keep a round game-machine display centered at a consistent size while the phone moves.

## What is implemented

- Live 1080p preview from the iPhone rear ultra-wide camera. The app requests camera permission at launch.
- Metal inverse mapping for the OpenCV fisheye angle model: `theta_d = theta * (1 + k1*theta^2 + k2*theta^4)`.
- Manual controls for lens center X/Y, `k1`, `k2`, output horizontal field of view, and an on/off correction switch.
- A bundled lens profile based on the user's machine-shot settings, with local persistence of subsequent tuning.
- JSON profile sharing, so the manually tuned settings can be saved and reused.
- Automatic machine lock: Vision searches for a large, near-circular display contour, tracks it between detections, maps its center and size into the corrected preview, and smoothly adjusts the Metal crop. The UI reports searching, tracking, and temporary loss states. There is no manual target box.

The first automatic-lock detector is a geometric circular-contour heuristic, tuned for the round game-machine display in the supplied example. It is not a trained semantic model and may select a different round object or lose the machine when the display is obscured. This first pass adjusts the live preview only; horizon lock, recording, and streaming are not implemented yet.

## Calibration note

The bundled profile uses a 106.458° output horizontal field of view from the user's machine-shot JSON, plus the available lens-center and radial-distortion values. Lens tuning is optional for trying automatic lock; different clip-on lens alignment can affect how accurately the target bounds map into the corrected image.

## Build on CodeMagic

1. Push this `MaiLens` directory to a GitHub repository (or use it as the repository root).
2. Add the repository in CodeMagic and select the `mai-lens-ios` workflow.
3. The workflow installs XcodeGen and the Metal toolchain, generates `MaiLens.xcodeproj` from `project.yml`, archives for a generic iOS device, and packages `MaiLens-unsigned.ipa` as a CodeMagic artifact. It does not require Apple signing credentials.

The IPA is unsigned and cannot be installed as-is. Sign it with your third-party signing tool and a matching provisioning profile before installing it on an iPhone.

To build locally, use a Mac with Xcode and XcodeGen installed, then run `xcodegen generate --spec project.yml` followed by `xcodebuild -project MaiLens.xcodeproj -scheme MaiLens -destination 'generic/platform=iOS' -configuration Release -archivePath build/MaiLens.xcarchive CODE_SIGNING_ALLOWED=NO archive`. Package the resulting `MaiLens.xcarchive/Products/Applications/MaiLens.app` under a top-level `Payload/` folder in a ZIP archive and name it `MaiLens-unsigned.ipa`.
