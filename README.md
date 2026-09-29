# MaiLens

MaiLens is an iPhone app starter for manually tuning a clip-on fisheye lens on the iPhone 15 Pro Max 0.5× camera. It captures the rear ultra-wide camera, previews an angle-polynomial fisheye correction in Metal, and saves the tuning profile on the device.

## What is implemented

- Live 1080p preview from the iPhone rear ultra-wide camera. The app requests camera permission at launch.
- Metal inverse mapping for the OpenCV fisheye angle model: `theta_d = theta * (1 + k1*theta^2 + k2*theta^4)`.
- Manual controls for lens center X/Y, `k1`, `k2`, output horizontal field of view, and an on/off correction switch.
- A bundled lens profile based on the user's machine-shot settings, with local persistence of subsequent tuning.
- JSON profile sharing, so the manually tuned settings can be saved and reused.

The app intentionally does not yet include machine tracking, horizon lock, video recording, or live streaming. Those should build on a validated lens profile and the corrected camera frame path in this starter.

## Calibration note

The bundled profile uses a 106.458° output horizontal field of view from the user's machine-shot JSON. Its lens center and radial coefficients come from the preliminary checkerboard calibration: 7 of 8 images detected at 4032×3024, with 1.61 px overall reprojection RMS. The detected corners cover only the middle of the images, so this does not establish edge accuracy for the external fisheye. Capture more checkerboard views around the usable image circle and validate against the app's actual 0.5× video frames before relying on edge geometry.

## Build on CodeMagic

1. Push this `MaiLens` directory to a GitHub repository (or use it as the repository root).
2. Add the repository in CodeMagic and select the `mai-lens-ios` workflow.
3. The workflow installs XcodeGen and the Metal toolchain, generates `MaiLens.xcodeproj` from `project.yml`, archives for a generic iOS device, and packages `MaiLens-unsigned.ipa` as a CodeMagic artifact. It does not require Apple signing credentials.

The IPA is unsigned and cannot be installed as-is. Sign it with your third-party signing tool and a matching provisioning profile before installing it on an iPhone.

To build locally, use a Mac with Xcode and XcodeGen installed, then run `xcodegen generate --spec project.yml` followed by `xcodebuild -project MaiLens.xcodeproj -scheme MaiLens -destination 'generic/platform=iOS' -configuration Release -archivePath build/MaiLens.xcarchive CODE_SIGNING_ALLOWED=NO archive`. Package the resulting `MaiLens.xcarchive/Products/Applications/MaiLens.app` under a top-level `Payload/` folder in a ZIP archive and name it `MaiLens-unsigned.ipa`.
