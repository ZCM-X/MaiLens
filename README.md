# MaiLens

MaiLens is an iPhone app for a clip-on fisheye lens on the iPhone 15 Pro Max 0.5× camera. It captures the rear ultra-wide camera, corrects the lens in Metal, and keeps the view locked like a digital gimbal while the phone moves.

## What is implemented

- Live 1080p preview from the iPhone rear ultra-wide camera. The app requests camera permission at launch.
- Metal inverse mapping for the OpenCV fisheye angle model: `theta_d = theta * (1 + k1*theta^2 + k2*theta^4)`.
- Manual controls for lens center X/Y, `k1`, `k2`, output horizontal field of view, and an on/off correction switch.
- A bundled lens profile based on the user's machine-shot settings, with local persistence of subsequent tuning.
- JSON profile sharing, so the manually tuned settings can be saved and reused.
- Lock mode digital gimbal: CoreMotion latches a levelled camera attitude, builds a raw-attitude quaternion correction at 120 Hz, interpolates it to each camera frame timestamp, and rotates the pinhole ray in Metal before the fisheye inverse map. A 1.36× reserve crop supplies room for yaw, pitch, and roll without exposing the lens edge. The preview has a visible “锁定当前画面” control and a button to re-lock the current view.
- Camera lock controls: after the camera has warmed up, MaiLens automatically latches the current focus position and exposure duration/ISO. The UI can unlock either one or both, relock them, and adjust exposure compensation from −3 to +3 EV. Compensation continues to work while exposure is locked by changing custom ISO/shutter values.
- Automatic machine geometry lock: a two-class `outer_frame`/`inner_screen` Core ML detector is paired with Vision contour refinement, containment and edge checks, short-loss tracking, EMA crop smoothing, and mild anisotropic correction. The Metal preview and processed recording consume the same framing state, so the machine keeps its position and apparent distance while the phone moves.
- Processed video recording: the same Metal transform used by the preview is rendered into a 1080×1920 H.264 MP4 in the app's Documents folder. Microphone audio is added after the user starts recording and grants permission. The share sheet can export the video or save it to Photos.

The supplied training set combines the 50 still images from `D:\桌面文件\训练2` with the real fisheye still from `H:\IMG_8695.JPG`. The eight chart judgement markers are deliberately excluded from geometry training. CodeMagic exports the trained frame model to `Resources/FrameGeometryDetector.mlpackage` before building; live streaming remains to be added.

## Calibration note

The bundled profile uses a 106.458° output horizontal field of view from the user's machine-shot JSON, plus the available lens-center and radial-distortion values. Lens tuning is optional; different clip-on lens alignment can affect the corrected image.

## Build on CodeMagic

1. Push this `MaiLens` directory to a GitHub repository (or use it as the repository root).
2. Add the repository in CodeMagic and select the `mai-lens-ios` workflow.
3. The workflow installs XcodeGen and the Metal toolchain, generates `MaiLens.xcodeproj` from `project.yml`, archives for a generic iOS device, and packages `MaiLens-unsigned.ipa` as a CodeMagic artifact. It does not require Apple signing credentials.

The IPA is unsigned and cannot be installed as-is. Sign it with your third-party signing tool and a matching provisioning profile before installing it on an iPhone.

To build locally, use a Mac with Xcode and XcodeGen installed, then run `xcodegen generate --spec project.yml` followed by `xcodebuild -project MaiLens.xcodeproj -scheme MaiLens -destination 'generic/platform=iOS' -configuration Release -archivePath build/MaiLens.xcarchive CODE_SIGNING_ALLOWED=NO archive`. Package the resulting `MaiLens.xcarchive/Products/Applications/MaiLens.app` under a top-level `Payload/` folder in a ZIP archive and name it `MaiLens-unsigned.ipa`.
