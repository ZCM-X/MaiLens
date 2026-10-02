# MaiLens

MaiLens is an iPhone app for a clip-on fisheye lens on the iPhone 15 Pro Max 0.5× camera. It captures the rear ultra-wide camera, corrects the lens in Metal, and keeps the view locked like a digital gimbal while the phone moves.

## What is implemented

- Live 1080p preview from the iPhone rear ultra-wide camera. The app requests camera permission at launch.
- Metal inverse mapping for the OpenCV fisheye angle model: `theta_d = theta * (1 + k1*theta^2 + k2*theta^4)`.
- Manual controls for lens center X/Y, `k1`, `k2`, output field of view, lens half field of view, image-circle ratio, and an on/off correction switch.
- A bundled clip-on fisheye profile with defaults of 103° horizontal output FOV, 69° lens half-FOV, and a 1.15× image circle relative to the input's short side. Lens values persist locally and are included in exported lens profiles.
- JSON profile sharing, so the manually tuned settings can be saved and reused.
- Lock mode digital gimbal: CoreMotion latches a levelled camera attitude, builds a raw-attitude quaternion correction at 120 Hz, interpolates it to each camera frame timestamp, and rotates the pinhole ray in Metal before the fisheye inverse map. A 1.36× reserve crop supplies room for yaw, pitch, and roll without exposing the lens edge. The preview has a visible “锁定当前画面” control and a button to re-lock the current view.
- Camera lock controls: after the camera has warmed up, MaiLens automatically latches the current focus position and exposure duration/ISO. The UI can unlock either one or both, relock them, and adjust exposure compensation from −3 to +3 EV. Compensation continues to work while exposure is locked by changing custom ISO/shutter values.
- Automatic machine geometry lock: the v5 two-class `outer_buttons`/`inner_screen` Core ML detector reconciles the boxes, while Vision contour fitting refines the circular screen centre. The controller turns a rectilinear virtual camera toward that screen-centre ray, then the Metal shader rotates each output ray through the gimbal pose and inverse fisheye map. The 75 mm physical gap from the outer frame to the inner screen is used with the projected border gaps to estimate phone-to-machine distance; zoom follows that estimate to counter forward/backward movement while preserving the initial composition. The four projected gaps and estimated distance are shown in the UI. This is a perspective-preserving view reframe; it does not stretch the preview to force the screen ellipse into a circle. The preview and processed recording use the same transform.
- Processed video recording: the same Metal transform used by the preview is rendered into a 1080×1920 H.264 MP4 in the app's Documents folder. Microphone audio is added after the user starts recording and grants permission. The share sheet can export the video or save it to Photos.

The deployed v5 checkpoint is fine-tuned from the PC detector with corrected raw phone-fisheye frames. CodeMagic exports it as an Xcode model source; Xcode compiles it to `FrameGeometryDetector.mlmodelc` for the iOS archive, which is checked before IPA packaging. The live preview loads the model through Vision. It recognizes the physical outer button ring and the circular gameplay screen; the eight chart judgement markers are deliberately excluded from geometry training.

## Panoramic-style machine reframe

When the machine lock is active, the detected inner-screen centre becomes the forward ray of a virtual camera. The renderer rotates that camera view toward the screen and samples the fisheye sensor with the configured rectilinear horizontal FOV (103° by default). The annotated 75 mm gap between the machine's outer frame and inner screen provides a physical scale reference for estimating camera distance; the controller uses that estimate to compensate zoom as the phone moves forward or backward. A slider lets the measured physical spacing be tuned, and the app shows the estimated distance and four projected gaps. This uses ray-based reprojection and avoids independent X/Y stretching. The two-box detector can centre and zoom on the machine, but it does not estimate a full 3D plane pose for arbitrary keystone removal.

## Calibration note

The bundled profile starts at 103° horizontal output FOV, 69° lens half-FOV, and a 1.15× image-circle diameter measured against the input frame's short side, plus the available lens-center and radial-distortion values. The half-FOV and image-circle ratio determine the source focal scale; the radial coefficients shape the edge curve. Lens geometry and the 75 mm machine gap calibration are tuned separately.

## Build on CodeMagic

1. Push this `MaiLens` directory to a GitHub repository (or use it as the repository root).
2. Add the repository in CodeMagic and select the `mai-lens-ios` workflow.
3. The workflow installs XcodeGen and the Metal toolchain, generates `MaiLens.xcodeproj` from `project.yml`, archives for a generic iOS device, and packages `MaiLens-unsigned.ipa` as a CodeMagic artifact. It does not require Apple signing credentials.

The IPA is unsigned and cannot be installed as-is. Sign it with your third-party signing tool and a matching provisioning profile before installing it on an iPhone.

To build locally, use a Mac with Xcode and XcodeGen installed, then run `xcodegen generate --spec project.yml` followed by `xcodebuild -project MaiLens.xcodeproj -scheme MaiLens -destination 'generic/platform=iOS' -configuration Release -archivePath build/MaiLens.xcarchive CODE_SIGNING_ALLOWED=NO archive`. Package the resulting `MaiLens.xcarchive/Products/Applications/MaiLens.app` under a top-level `Payload/` folder in a ZIP archive and name it `MaiLens-unsigned.ipa`.
