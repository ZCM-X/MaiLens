# MaiLens

MaiLens is an iPhone app starter for manually tuning a clip-on fisheye lens on the iPhone 15 Pro Max 0.5× camera. It captures the rear ultra-wide camera, previews an angle-polynomial fisheye correction in Metal, and saves the tuning profile on the device.

## What is implemented

- Live 1080p preview from the iPhone rear ultra-wide camera. The app requests camera permission at launch.
- Metal inverse mapping for the OpenCV fisheye angle model: `theta_d = theta * (1 + k1*theta^2 + k2*theta^4)`.
- Manual controls for lens center X/Y, `k1`, `k2`, output horizontal field of view, and an on/off correction switch.
- A preliminary preset seeded from the checkerboard photos in `C:\Users\93543\Downloads\qipan` and local persistence of the tuned profile.
- JSON profile sharing, so the manually tuned settings can be saved and reused.

The app intentionally does not yet include machine tracking, horizon lock, video recording, or live streaming. Those should build on a validated lens profile and the corrected camera frame path in this starter.

## Calibration note

The seed profile detected 7 of 8 checkerboard images at 4032×3024 with 9×6 inner corners and reported 1.61 px overall reprojection RMS. The detected corners cover only the middle of the images. That is enough to initialize the manual controls, not to claim an accurate correction near the outer edge of the external fisheye lens. Capture more checkerboard views around the usable image circle and validate against the app's actual 0.5× video frames before relying on edge geometry.

## Build on CodeMagic

1. Push this `MaiLens` directory to a GitHub repository (or use it as the repository root).
2. Add the repository in CodeMagic and select the `mai-lens-ios` workflow.
3. The workflow installs XcodeGen, generates `MaiLens.xcodeproj` from `project.yml`, and builds an unsigned simulator app. It does not require Apple signing credentials for this validation build.

To build locally, use a Mac with Xcode and XcodeGen installed, then run `xcodegen generate --spec project.yml` followed by an iOS Simulator build in Xcode.
