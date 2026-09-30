# MaiLens

MaiLens is an iPhone app for a clip-on fisheye lens on the iPhone 15 Pro Max 0.5× camera. It captures the rear ultra-wide camera, corrects the lens in Metal, and can automatically keep a round game-machine display centered at a consistent size while the phone moves.

## What is implemented

- Live 1080p preview from the iPhone rear ultra-wide camera. The app requests camera permission at launch.
- Metal inverse mapping for the OpenCV fisheye angle model: `theta_d = theta * (1 + k1*theta^2 + k2*theta^4)`.
- Manual controls for lens center X/Y, `k1`, `k2`, output horizontal field of view, and an on/off correction switch.
- A bundled lens profile based on the user's machine-shot settings, with local persistence of subsequent tuning.
- JSON profile sharing, so the manually tuned settings can be saved and reused.
- Automatic machine lock: when the CodeMagic build includes `MachineDetector.mlmodel`, Vision runs the trained detector, chooses the round target, tracks it between detections, maps its center and size into the corrected preview, and smoothly adjusts the Metal crop. Builds without the model fall back to the circular contour detector. The UI reports searching, tracking, and temporary loss states. There is no manual target box.
- Digital gimbal: CoreMotion locks the camera attitude at the centering moment, filters yaw/pitch/roll at 60 Hz, and moves a 1.36× Metal crop in the opposite direction to compensate hand rotation. The preview has a visible “锁定当前画面” control; this mode preserves the chosen initial tilt instead of depending on machine detection.
- Horizon leveling: CoreMotion gravity measurements rotate the preview and compensate the crop to keep the horizon level.
- Processed video recording: the same Metal transform used by the preview is rendered into a 1080×1920 H.264 MP4 in the app's Documents folder. Microphone audio is added after the user starts recording and grants permission. The share sheet can export the video or save it to Photos.

The supplied training set combines the 50 still images from `D:\桌面文件\训练2` with sampled frames from the lock reference video. The labels are generated from the visible outer ring and should still be reviewed if more camera angles are added. Live streaming remains to be added.

## Calibration note

The bundled profile uses a 106.458° output horizontal field of view from the user's machine-shot JSON, plus the available lens-center and radial-distortion values. Lens tuning is optional for trying automatic lock; different clip-on lens alignment can affect how accurately the target bounds map into the corrected image.

## Build on CodeMagic

1. Push this `MaiLens` directory to a GitHub repository (or use it as the repository root).
2. Add the repository in CodeMagic and select the `mai-lens-ios` workflow.
3. The workflow installs XcodeGen and the Metal toolchain, generates `MaiLens.xcodeproj` from `project.yml`, archives for a generic iOS device, and packages `MaiLens-unsigned.ipa` as a CodeMagic artifact. It does not require Apple signing credentials.

The IPA is unsigned and cannot be installed as-is. Sign it with your third-party signing tool and a matching provisioning profile before installing it on an iPhone.

To build locally, use a Mac with Xcode and XcodeGen installed, then run `xcodegen generate --spec project.yml` followed by `xcodebuild -project MaiLens.xcodeproj -scheme MaiLens -destination 'generic/platform=iOS' -configuration Release -archivePath build/MaiLens.xcarchive CODE_SIGNING_ALLOWED=NO archive`. Package the resulting `MaiLens.xcarchive/Products/Applications/MaiLens.app` under a top-level `Payload/` folder in a ZIP archive and name it `MaiLens-unsigned.ipa`.
