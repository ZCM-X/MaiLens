import Combine
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import simd
import Vision

enum MachineGeometryLockStatus: Equatable {
    case searching
    case tracking
    case lost
    case paused

    var title: String {
        switch self {
        case .searching: return "正在检测机台"
        case .tracking: return "机台居中锁定"
        case .lost: return "短时漏检，保持构图"
        case .paused: return "自动锁定已暂停"
        }
    }
}

/// The virtual-camera state consumed by the Metal renderer. `center` is the
/// detected screen centre in the gimbal-locked pinhole view; `viewRotation`
/// turns the output camera toward that ray before sampling the fisheye image.
struct MachineGeometryFraming: Equatable {
    var center: CGPoint
    var zoom: CGFloat
    var viewRotation: MachineViewRotation
    var screenEllipseDetected: Bool
    var isActive: Bool

    var leftGap: CGFloat = 0
    var rightGap: CGFloat = 0
    var topGap: CGFloat = 0
    var bottomGap: CGFloat = 0
    var estimatedMachineDistanceMM: CGFloat? = nil

    /// The screen ellipse pulled back to a circle, as the 2x2 the shader
    /// applies to the ray before anything else.
    var rectifyShape: SIMD4<Float> = SIMD4(1, 0, 0, 1)
    var rectifyStrength: Float = 0
    var ringCosine: SIMD4<Float> = SIMD4(MachineRectifier.tileRatio, 0, 0, 0)
    var ringSine: SIMD4<Float> = .zero
    var ringStrength: Float = 0
    var ringTarget: Float = MachineRectifier.tileRatio
    /// Screen radius in ray-plane units — the same units as the shader's
    /// `rectilinear` — before the shader's zoom. Keeping it free of the frame
    /// size is what lets the live preview and the 1080x1920 recording apply the
    /// ring at the same place even though their focals differ.
    var screenRadiusPlane: Float = 0

    static let identity = MachineGeometryFraming(
        center: CGPoint(x: 0.5, y: 0.5),
        zoom: 1,
        viewRotation: .identity,
        screenEllipseDetected: false,
        isActive: false
    )
}

/// Columns map output-camera rays into the gimbal-locked camera coordinate
/// system. SIMD4 columns match Metal's 16-byte-aligned uniform layout.
struct MachineViewRotation: Equatable {
    var right: SIMD4<Float>
    var down: SIMD4<Float>
    var forward: SIMD4<Float>

    static let identity = MachineViewRotation(
        right: SIMD4<Float>(1, 0, 0, 0),
        down: SIMD4<Float>(0, 1, 0, 0),
        forward: SIMD4<Float>(0, 0, 1, 0)
    )

    var matrix: simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3<Float>(right.x, right.y, right.z),
            SIMD3<Float>(down.x, down.y, down.z),
            SIMD3<Float>(forward.x, forward.y, forward.z)
        ))
    }
}

/// Reconciles the detected outer button ring and inner screen, locks the
/// calibrated screen centre, and sets zoom from their measured border gap. The
/// eight gameplay judgement markers are not part of this physical geometry.
final class MachineGeometryLockController: ObservableObject {
    @Published private(set) var status: MachineGeometryLockStatus = .searching
    @Published private(set) var isEnabled = true
    @Published private(set) var framing = MachineGeometryFraming.identity
    @Published private(set) var detectorAvailable = false
    @Published private(set) var detectorLoadMessage: String?
    /// Screen ellipse minor/major as seen now: 1 is round, 0.9 is a 26° tilt.
    @Published private(set) var screenFlatness: Float = 0
    /// Spread of the eight measured slots as a fraction of their mean.
    @Published private(set) var ringSpread: Float = 0

    var previewStatusTitle: String {
        guard detectorAvailable else { return "机台模型未加载" }
        if status == .tracking, framing.isActive {
            return String(format: "机台居中 ×%.2f", framing.zoom)
        }
        return status.title
    }

    /// Called on the Vision queue. The renderer copies the value immediately.
    var onFramingUpdate: ((MachineGeometryFraming) -> Void)?

    private let visionQueue = DispatchQueue(
        label: "com.mailens.machine-geometry-lock",
        qos: .userInitiated
    )
    private let frameGate = NSLock()
    private var framePending = false
    private let sequenceHandler = VNSequenceRequestHandler()
    private let detector = FrameGeometryCoreMLDetector()
    private var running = false
    private var enabledValue = true
    private var frameCounter = 0
    private var lostFrameCount = 0
    private var hasAcquiredLock = false
    private var lastDetectionPresentationTime: TimeInterval?
    private var lastSuccessfulTrackingTime: TimeInterval?
    private var outerTrackingRequest: VNTrackObjectRequest?
    private var innerTrackingRequest: VNTrackObjectRequest?
    private var hasTrackingPair: Bool {
        outerTrackingRequest != nil && innerTrackingRequest != nil
    }
    private var lastOuterBox: CGRect?
    private var lastInnerBox: CGRect?
    private var settings = LensCorrectionSettings.preliminary
    private var previewSize = CGSize(width: 9, height: 16)
    private var sourceSize = CGSize(width: 9, height: 16)
    private var gimbal = DigitalGimbalTransform.identity
    private var horizonRadians: CGFloat = 0
    private var smoothedCenter = CGPoint(x: 0.5, y: 0.5)
    private var smoothedZoom: CGFloat = 1
    private var detectedScreenEllipse: ScreenEllipse?
    private var machineBorderGapMM: CGFloat = 75
    private var rectifyStrength: Float = 1.0
    private var ringRoundStrength: Float = 1.0
    private var smoothedRingCosine = SIMD4<Float>(MachineRectifier.tileRatio, 0, 0, 0)
    private var smoothedRingSine = SIMD4<Float>.zero
    private var hasRingFit = false
    private var lastRingSpread: Float = 0
    private var publishedFlatness: Float = -1
    private var publishedRingSpread: Float = -1
    private var referenceMachineDistanceMM: CGFloat?
    private var referenceZoom: CGFloat = 1
    /// How hard the crop is allowed to follow the machine.  The gyro already
    /// takes the phone's rotation out, so all this smooths is tracker noise —
    /// keep it short enough that the cabinet reads as pinned to the middle of
    /// the frame rather than chasing it.
    private static let centerTimeConstant: Double = 0.10
    /// Screen radius in ray-plane units when the lock was taken, and the zoom
    /// that went with it.  Their ratio is what compensates forward/backward
    /// movement; the dead band and rate cap stop detector noise on the other
    /// axes from leaking into the picture as size wobble.
    private var anchorScreenRadiusPlane: Float = 0
    private var hasAnchorRadius = false
    private var anchorZoom: CGFloat = 1
    private static let zoomDeadband: CGFloat = 0.03
    private static let zoomRatePerSecond: CGFloat = 0.35
    private static let zoomRange: ClosedRange<CGFloat> = 0.90...2.20
    private var lastFramingTimestamp: TimeInterval?
    private var lastContourRefinementFrame = 0
    private var lastPublishedStatus: MachineGeometryLockStatus = .searching

    init() {
        detectorAvailable = detector.isAvailable
        detectorLoadMessage = detector.loadFailureMessage
    }

    func start() {
        visionQueue.async { [weak self] in
            guard let self else { return }
            self.running = true
            self.publishStatus(self.enabledValue ? .searching : .paused)
        }
    }

    func stop() {
        visionQueue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.resetTracking()
            self.publishFraming(.identity)
            self.publishStatus(.paused)
        }
    }

    func updateSettings(_ value: LensCorrectionSettings) {
        visionQueue.async { [weak self] in self?.settings = value }
    }

    func updateMachineBorderGapMM(_ value: Double) {
        let clamped = CGFloat(min(max(value, 25), 200))
        visionQueue.async { [weak self] in
            guard let self, abs(self.machineBorderGapMM - clamped) > 0.001 else { return }
            self.machineBorderGapMM = clamped
            self.referenceMachineDistanceMM = nil
        }
    }

    /// How much of the screen-ellipse-to-circle correction to apply. 1 is
    /// "the screen is round"; 0 hands the preview back to the raw geometry.
    func updateRectifyStrength(_ value: Double) {
        let clamped = Float(min(max(value, 0), 1))
        visionQueue.async { [weak self] in self?.rectifyStrength = clamped }
    }

    /// How much of the eight-slot pull-back to apply. 0 leaves the ring as
    /// the lens saw it, 1 puts all eight slots on one circle.
    func updateRingRoundStrength(_ value: Double) {
        let clamped = Float(min(max(value, 0), 1))
        visionQueue.async { [weak self] in self?.ringRoundStrength = clamped }
    }

    func updatePreviewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        visionQueue.async { [weak self] in self?.previewSize = size }
    }

    func updateGimbalTransform(_ value: DigitalGimbalTransform) {
        visionQueue.async { [weak self] in self?.gimbal = value }
    }

    func updateHorizonAngle(_ angle: CGFloat) {
        visionQueue.async { [weak self] in self?.horizonRadians = angle }
    }

    func toggle() {
        let next = !isEnabled
        isEnabled = next
        visionQueue.async { [weak self] in
            guard let self else { return }
            self.enabledValue = next
            self.resetTracking()
            self.publishFraming(.identity)
            self.publishStatus(next ? .searching : .paused)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        visionQueue.async { [weak self] in
            guard let self else { return }
            self.enabledValue = enabled
            self.resetTracking()
            self.publishFraming(.identity)
            self.publishStatus(enabled ? .searching : .paused)
        }
    }

    func process(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: TimeInterval,
        gimbalTransform: DigitalGimbalTransform
    ) {
        frameGate.lock()
        guard !framePending else {
            frameGate.unlock()
            return
        }
        framePending = true
        frameGate.unlock()
        visionQueue.async { [weak self] in
            guard let self else { return }
            if self.running, self.enabledValue {
                self.processFrame(pixelBuffer, presentationTime: presentationTime, gimbalTransform: gimbalTransform)
            }
            self.frameGate.lock()
            self.framePending = false
            self.frameGate.unlock()
        }
    }

    private func processFrame(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: TimeInterval,
        gimbalTransform: DigitalGimbalTransform
    ) {
        frameCounter &+= 1
        gimbal = gimbalTransform
        sourceSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        // Core ML stays off the display-rate path. Search more often before a
        // lock and during loss, then let Vision tracking bridge detections.
        if shouldRunDetection(at: presentationTime),
           let detection = detectGeometry(in: pixelBuffer) {
            let stable = stabilizedDetection(detection)
            if let ellipse = stable.ellipse {
                detectedScreenEllipse = stabilizedEllipse(
                    ellipse,
                    against: detectedScreenEllipse,
                    alpha: 0.35
                )
            }
            if lostFrameCount > 0 || needsDetectorCorrection(stable) || !hasTrackingPair {
                if updateFraming(
                    outer: stable.outer,
                    inner: stable.inner,
                    pixelBuffer: pixelBuffer,
                    gimbalTransform: gimbalTransform,
                    presentationTime: presentationTime
                ) {
                    beginTracking(outer: stable.outer, inner: stable.inner)
                    hasAcquiredLock = true
                    lastSuccessfulTrackingTime = presentationTime
                    publishStatus(.tracking)
                    return
                }
            }
        }

        // Track every camera frame. The previous half-rate gate cut a typical
        // 30 fps camera feed to 15 tracking updates per second, making the crop
        // visibly chase the machine in steps. Vision runs on this serial queue;
        // the camera callback never waits for tracking to finish.
        if advanceTracker(on: pixelBuffer, gimbalTransform: gimbalTransform, presentationTime: presentationTime) {
            hasAcquiredLock = true
            lastSuccessfulTrackingTime = presentationTime
            publishStatus(.tracking)
        } else {
            updateStatusAfterMiss(presentationTime: presentationTime)
        }
    }

    private func shouldRunDetection(at presentationTime: TimeInterval) -> Bool {
        guard detector.isAvailable else { return false }
        let interval: TimeInterval
        if !hasTrackingPair {
            interval = 0.22
        } else if lostFrameCount > 0 {
            interval = 0.14
        } else {
            interval = 0.34
        }

        guard presentationTime.isFinite else {
            return frameCounter % (hasTrackingPair ? 12 : 8) == 0
        }
        if let previous = lastDetectionPresentationTime,
           presentationTime >= previous,
           presentationTime - previous < interval {
            return false
        }
        lastDetectionPresentationTime = presentationTime
        return true
    }

    private func stabilizedDetection(_ detection: GeometryDetection) -> GeometryDetection {
        guard let previousOuter = lastOuterBox,
              let previousInner = lastInnerBox else { return detection }
        return GeometryDetection(
            outer: stabilizedBox(detection.outer, against: previousOuter, alpha: 0.28),
            inner: stabilizedBox(detection.inner, against: previousInner, alpha: 0.24),
            ellipse: detection.ellipse
        )
    }

    private func needsDetectorCorrection(_ detection: GeometryDetection) -> Bool {
        guard hasTrackingPair,
              let previousOuter = lastOuterBox,
              let previousInner = lastInnerBox else { return true }

        let outerCenterError = hypot(
            (detection.outer.midX - previousOuter.midX) / max(previousOuter.width, 0.001),
            (detection.outer.midY - previousOuter.midY) / max(previousOuter.height, 0.001)
        )
        let innerCenterError = hypot(
            (detection.inner.midX - previousInner.midX) / max(previousOuter.width, 0.001),
            (detection.inner.midY - previousInner.midY) / max(previousOuter.height, 0.001)
        )
        let outerScaleError = max(
            abs(log(max(detection.outer.width, 0.001) / max(previousOuter.width, 0.001))),
            abs(log(max(detection.outer.height, 0.001) / max(previousOuter.height, 0.001)))
        )
        // Ignore tiny low-rate detector fluctuations while both optical tracks
        // agree. Re-anchor only after measurable geometric drift accumulates.
        return outerCenterError > 0.035 || innerCenterError > 0.035 || outerScaleError > 0.08
    }

    private func updateStatusAfterMiss(presentationTime: TimeInterval) {
        guard hasAcquiredLock else {
            publishStatus(.searching)
            return
        }
        let missDuration: TimeInterval
        if presentationTime.isFinite,
           let lastSuccessfulTime = lastSuccessfulTrackingTime,
           presentationTime >= lastSuccessfulTime {
            missDuration = presentationTime - lastSuccessfulTime
        } else {
            missDuration = Double(lostFrameCount) / 30.0
        }
        // Keep the lock state stable through brief detector/tracker gaps. The
        // last framing remains active while the detector reacquires the pair.
        if missDuration >= 0.90 {
            publishStatus(.lost)
        }
    }

    private func detectGeometry(in pixelBuffer: CVPixelBuffer) -> GeometryDetection? {
        guard let raw = detector.detect(in: pixelBuffer, priorOuter: lastOuterBox, priorInner: lastInnerBox) else {
            return nil
        }

        // Object detection supplies the semantic labels. Contour fitting is a
        // refinement stage inside the outer ROI and is only accepted when it
        // agrees with the detector, preventing one high-contrast edge from
        // moving the crop by itself.
        let ellipse: ScreenEllipse?
        if frameCounter - lastContourRefinementFrame >= 8 {
            ellipse = refineInnerEllipse(
                in: pixelBuffer,
                outer: raw.outer,
                predictedInner: raw.inner
            )
            lastContourRefinementFrame = frameCounter
        } else {
            ellipse = nil
        }
        let refinedInner = ellipse.map {
            blendRect(raw.inner, $0.bounds, currentWeight: 0.62)
        } ?? raw.inner
        guard isPlausiblePair(outer: raw.outer, inner: refinedInner) else { return nil }
        return GeometryDetection(outer: raw.outer, inner: refinedInner, ellipse: ellipse)
    }

    private func advanceTracker(
        on pixelBuffer: CVPixelBuffer,
        gimbalTransform: DigitalGimbalTransform,
        presentationTime: TimeInterval
    ) -> Bool {
        guard let outerRequest = outerTrackingRequest,
              let innerRequest = innerTrackingRequest else { return false }
        do {
            try sequenceHandler.perform([outerRequest, innerRequest], on: pixelBuffer)
            guard let outerObservation = outerRequest.results?.first as? VNDetectedObjectObservation,
                  let innerObservation = innerRequest.results?.first as? VNDetectedObjectObservation,
                  outerObservation.confidence >= 0.16,
                  innerObservation.confidence >= 0.16,
                  outerObservation.boundingBox.width > 0.03,
                  outerObservation.boundingBox.height > 0.03,
                  innerObservation.boundingBox.width > 0.03,
                  innerObservation.boundingBox.height > 0.03 else {
                handleTrackingLoss()
                return false
            }

            outerRequest.inputObservation = outerObservation
            innerRequest.inputObservation = innerObservation
            let previousOuter = lastOuterBox ?? outerObservation.boundingBox
            let previousInner = lastInnerBox ?? innerObservation.boundingBox
            let trackedOuter = stabilizedBox(outerObservation.boundingBox, against: previousOuter, alpha: 0.82)
            let trackedInner = stabilizedBox(innerObservation.boundingBox, against: previousInner, alpha: 0.82)
            let previousEllipse = detectedScreenEllipse
            advanceTrackedEllipse(from: previousInner, to: trackedInner)
            guard updateFraming(
                outer: trackedOuter,
                inner: trackedInner,
                pixelBuffer: pixelBuffer,
                gimbalTransform: gimbalTransform,
                presentationTime: presentationTime
            ) else {
                detectedScreenEllipse = previousEllipse
                handleTrackingLoss()
                return false
            }
            lastOuterBox = trackedOuter
            lastInnerBox = trackedInner
            lostFrameCount = 0
            return true
        } catch {
            handleTrackingLoss()
            return false
        }
    }

    private func beginTracking(outer: CGRect, inner: CGRect) {
        let outerRequest = VNTrackObjectRequest(
            detectedObjectObservation: VNDetectedObjectObservation(boundingBox: outer)
        )
        let innerRequest = VNTrackObjectRequest(
            detectedObjectObservation: VNDetectedObjectObservation(boundingBox: inner)
        )
        outerRequest.trackingLevel = .accurate
        innerRequest.trackingLevel = .accurate
        outerTrackingRequest = outerRequest
        innerTrackingRequest = innerRequest
        lastOuterBox = outer
        lastInnerBox = inner
        lostFrameCount = 0
    }

    private func updateFraming(
        outer: CGRect,
        inner: CGRect,
        pixelBuffer: CVPixelBuffer,
        gimbalTransform: DigitalGimbalTransform,
        presentationTime: TimeInterval
    ) -> Bool {
        let outerTopLeft = visionToTopLeft(outer)
        let innerTopLeft = visionToTopLeft(inner)
        guard isPlausiblePair(outer: outerTopLeft, inner: innerTopLeft) else { return false }

        let mappedOuter = mapRectified(outerTopLeft)
        let mappedInner = mapRectified(innerTopLeft)
        // The paired boxes cross-check the machine geometry: the inner box must
        // remain inside the outer button frame, and the inner screen defines the
        // exact lock point.
        let rectifiedIntersection = mappedOuter.intersection(mappedInner)
        let rectifiedInnerArea = mappedInner.width * mappedInner.height
        guard !rectifiedIntersection.isNull,
              rectifiedInnerArea > 0,
              rectifiedIntersection.width * rectifiedIntersection.height / rectifiedInnerArea > 0.68 else {
            return false
        }
        let cameraScreenCenter = detectedScreenEllipse.map { mapRectifiedPoint($0.center) }
            ?? CGPoint(x: mappedInner.midX, y: mappedInner.midY)
        // Where the cabinet sits once the gyro has taken the phone's rotation
        // out. This is the stable frame the lock lives in.
        let lockedCenter = lockedPoint(
            fromCameraPoint: cameraScreenCenter,
            transform: gimbalTransform
        )

        let deltaTime: CGFloat
        if let previousTime = lastFramingTimestamp,
           presentationTime.isFinite, presentationTime > previousTime {
            deltaTime = min(max(CGFloat(presentationTime - previousTime), 1.0 / 120.0), 0.15)
        } else {
            deltaTime = 1.0 / 30.0
        }
        lastFramingTimestamp = presentationTime.isFinite ? presentationTime : nil

        // Where the cabinet is right now, in the frame the gyro has already
        // de-rotated.  The output camera below is aimed straight at this, which
        // is what pins the cabinet to the middle of the picture no matter where
        // it started or how the phone is waved.  Only tracker noise is filtered
        // here; holding a frozen anchor instead would freeze the cabinet
        // wherever the lock happened to catch it, off to one side.
        let centerAlpha = CGFloat(1 - exp(-Double(deltaTime) / Self.centerTimeConstant))
        smoothedCenter = CGPoint(
            x: smoothedCenter.x + (lockedCenter.x - smoothedCenter.x) * centerAlpha,
            y: smoothedCenter.y + (lockedCenter.y - smoothedCenter.y) * centerAlpha
        )

        let viewRotation = machineViewRotation(
            aimingAt: smoothedCenter,
            previewSize: previewSize,
            horizontalFOV: settings.horizontalFOV
        )

        // Measure the outer ring in the anchored view. The four border gaps
        // stay in the readout as the physical 75 mm check, but they no longer
        // drive the zoom: four box edges move several percent for a handful of
        // detector pixels, and dividing the lock distance by their mean is what
        // amplified that into the fourfold zoom swing.
        let correctedOuterBounds = projectedBounds(
            of: outerTopLeft,
            gimbalTransform: gimbalTransform,
            viewRotation: viewRotation
        )
        let correctedInnerBounds = projectedBounds(
            of: innerTopLeft,
            gimbalTransform: gimbalTransform,
            viewRotation: viewRotation
        )
        guard correctedOuterBounds.width.isFinite,
              correctedOuterBounds.height.isFinite,
              correctedOuterBounds.width > 0.02,
              correctedOuterBounds.width < 3.2 else { return false }

        // How much of the portrait frame the complete button ring takes up
        // right now.  On the anchor frame this picks the fill zoom; later
        // frames keep it as the reference and only follow the radius ratio.
        let targetSize = max(
            correctedOuterBounds.width,
            correctedOuterBounds.height * previewSize.height / max(previewSize.width, 1)
        )

        let gapLeftPixels = max(correctedInnerBounds.minX - correctedOuterBounds.minX, 0)
            * previewSize.width
        let gapRightPixels = max(correctedOuterBounds.maxX - correctedInnerBounds.maxX, 0)
            * previewSize.width
        let gapTopPixels = max(correctedInnerBounds.minY - correctedOuterBounds.minY, 0)
            * previewSize.height
        let gapBottomPixels = max(correctedOuterBounds.maxY - correctedInnerBounds.maxY, 0)
            * previewSize.height
        let meanGapPixels = (gapLeftPixels + gapRightPixels + gapTopPixels + gapBottomPixels) * 0.25
        let horizontalFOV = CGFloat(min(max(settings.horizontalFOV, 1), 179)) * .pi / 180
        let virtualFocalPixels = previewSize.width / (2 * tan(horizontalFOV * 0.5))
        var estimatedMachineDistanceMM: CGFloat = 0
        if meanGapPixels.isFinite, meanGapPixels > 0.5, virtualFocalPixels.isFinite {
            estimatedMachineDistanceMM = virtualFocalPixels * machineBorderGapMM / meanGapPixels
        }

        // The screen ellipse and the 2x2 that turns it back into the circle it
        // is on the real cabinet, both in the locked output plane -- the plane
        // the shader corrects in. The detector reads the preview plane, so the
        // view rotation that centres the screen has to be carried through
        // first; skipping that leaves the correction tilted by however far
        // off-centre the cabinet was when the lock caught it.
        var shape = matrix_identity_float2x2
        var screenRadius: CGFloat = 0
        var screenRadiusPlane: Float = 0
        var ringCosine = smoothedRingCosine
        var ringSine = smoothedRingSine
        var ringActive = hasRingFit
        if let ellipse = detectedScreenEllipse {
            let cosine = cos(ellipse.angle)
            let sine = sin(ellipse.angle)
            let majorSource = CGPoint(
                x: ellipse.center.x + ellipse.majorRadius * cosine / sourceSize.width,
                y: ellipse.center.y + ellipse.majorRadius * sine / sourceSize.height
            )
            let minorSource = CGPoint(
                x: ellipse.center.x - ellipse.minorRadius * sine / sourceSize.width,
                y: ellipse.center.y + ellipse.minorRadius * cosine / sourceSize.height
            )
            let plane = MachinePlaneMap(
                outputToPreview: viewRotation.matrix,
                previewSize: previewSize,
                horizontalFOV: settings.horizontalFOV
            )
            let centerPreview = mapRectifiedPoint(ellipse.center)
            let focal = plane.focal
            if let lockedEllipseCenter = plane.lockedPlane(centerPreview),
               let lockedMajor = plane.lockedPlane(mapRectifiedPoint(majorSource)),
               let lockedMinor = plane.lockedPlane(mapRectifiedPoint(minorSource)) {
                // Back to pixel-like units: the 2x2 is scale invariant, but the
                // radius has to be comparable with the shader's focal.
                let majorAxis = CGPoint(x: (lockedMajor.x - lockedEllipseCenter.x) * focal,
                                        y: (lockedMajor.y - lockedEllipseCenter.y) * focal)
                let minorAxis = CGPoint(x: (lockedMinor.x - lockedEllipseCenter.x) * focal,
                                        y: (lockedMinor.y - lockedEllipseCenter.y) * focal)
                shape = MachineRectifier.shape(majorAxis: majorAxis,
                                               minorAxis: minorAxis,
                                               strength: Double(rectifyStrength))
                screenRadius = (hypot(majorAxis.x, majorAxis.y)
                                + hypot(minorAxis.x, minorAxis.y)) * 0.5
                screenRadiusPlane = Float(screenRadius / max(focal, 1))

                // The eight decorative frames are one part repeated eight
                // times, so head-on they sit at one radius in all eight
                // directions. Read them off the camera buffer and fit that ring.
                if screenRadius > 12, ringRoundStrength > 0 {
                    let reading = ButtonRingSampler.measure(
                        pixelBuffer: pixelBuffer,
                        sourceSize: sourceSize,
                        settings: settings,
                        map: plane,
                        centerPreview: centerPreview,
                        screenRadius: screenRadius
                    )
                    if reading.isValid,
                       let fit = MachineRectifier.fitBest(reading.ratios) {
                        let alpha: Float = 0.25
                        smoothedRingCosine += (fit.cosine - smoothedRingCosine) * alpha
                        smoothedRingSine += (fit.sine - smoothedRingSine) * alpha
                        hasRingFit = true
                        lastRingSpread = reading.spread
                        ringCosine = smoothedRingCosine
                        ringSine = smoothedRingSine
                        ringActive = true
                    }
                }
            }
        }

        // Distance compensation runs on the screen radius, the one measurement
        // that tracks phone-to-machine distance instead of detector jitter. The
        // anchor frame fixes both the reference radius and the zoom, and later
        // frames only move the zoom by a dead-banded, rate-limited fraction of
        // the radius ratio, so a one-pixel radius wobble cannot snap the crop.
        if !hasAnchorRadius, screenRadiusPlane > 0 {
            // Fit the full button ring into the portrait frame, then
            // freeze that as the reference the radius ratio scales.
            if targetSize.isFinite, targetSize > 0.05, targetSize < 3.2 {
                smoothedZoom = min(max(0.84 / targetSize, Self.zoomRange.lowerBound),
                                    Self.zoomRange.upperBound)
            }
            anchorScreenRadiusPlane = screenRadiusPlane
            anchorZoom = smoothedZoom
            hasAnchorRadius = true
        }
        if hasAnchorRadius, anchorScreenRadiusPlane > 0, screenRadiusPlane > 0 {
            let ratio = CGFloat(anchorScreenRadiusPlane / screenRadiusPlane)
            let target = anchorZoom * ratio
            let delta = target - smoothedZoom
            if abs(delta) > Self.zoomDeadband, delta.isFinite {
                // Zoom is not a free parameter: it is the phone-to-cabinet
                // distance, and distance cannot change at 6x a second. Cap
                // it at well under one zoom unit per second so a spurious
                // radius reading reads as a slow push instead of a jump.
                let maxStep = max(CGFloat(deltaTime) * Self.zoomRatePerSecond, 0.0002)
                smoothedZoom += max(min(delta, maxStep), -maxStep)
            }
        }
        smoothedZoom = min(max(smoothedZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let renderedGapScale = smoothedZoom * (gimbalTransform.gimbalActive ? 1.36 : 1)

        let flatness = detectedScreenEllipse.map {
            Float($0.minorRadius / max($0.majorRadius, 0.001))
        } ?? 0
        if abs(flatness - publishedFlatness) > 0.002
            || abs(lastRingSpread - publishedRingSpread) > 0.002 {
            publishedFlatness = flatness
            publishedRingSpread = lastRingSpread
            let spread = lastRingSpread
            DispatchQueue.main.async { [weak self] in
                self?.screenFlatness = flatness
                self?.ringSpread = spread
            }
        }

        var distanceForReadout: CGFloat? = nil
        if estimatedMachineDistanceMM > 0 { distanceForReadout = estimatedMachineDistanceMM }

        let current = MachineGeometryFraming(
            center: smoothedCenter,
            zoom: smoothedZoom,
            viewRotation: viewRotation,
            screenEllipseDetected: detectedScreenEllipse != nil,
            isActive: true,
            leftGap: max(correctedInnerBounds.minX - correctedOuterBounds.minX, 0)
                * previewSize.width * renderedGapScale,
            rightGap: max(correctedOuterBounds.maxX - correctedInnerBounds.maxX, 0)
                * previewSize.width * renderedGapScale,
            topGap: max(correctedInnerBounds.minY - correctedOuterBounds.minY, 0)
                * previewSize.height * renderedGapScale,
            bottomGap: max(correctedOuterBounds.maxY - correctedInnerBounds.maxY, 0)
                * previewSize.height * renderedGapScale,
            estimatedMachineDistanceMM: distanceForReadout,
            // The shader rebuilds this as float2x2(float2(x, y), float2(z, w)),
            // i.e. column major, so the two column vectors go in order.
            rectifyShape: SIMD4<Float>(shape.columns.0.x, shape.columns.0.y,
                                       shape.columns.1.x, shape.columns.1.y),
            rectifyStrength: detectedScreenEllipse == nil || rectifyStrength <= 0
                ? 0 : 1,
            ringCosine: ringCosine,
            ringSine: ringSine,
            ringStrength: ringActive ? ringRoundStrength : 0,
            ringTarget: MachineRectifier.tileRatio,
            screenRadiusPlane: screenRadiusPlane
        )
        publishFraming(current)
        return true
    }

    private func handleTrackingLoss() {
        lostFrameCount += 1
        guard lostFrameCount > 45 else { return }

        outerTrackingRequest = nil
        innerTrackingRequest = nil
        lastOuterBox = nil
        lastInnerBox = nil
        detectedScreenEllipse = nil
        // Keep the last framing while reacquiring. Returning to identity here
        // visibly lets the machine drift whenever a short detector run fails.
        publishStatus(hasAcquiredLock ? .lost : .searching)
    }

    private func resetTracking() {
        outerTrackingRequest = nil
        innerTrackingRequest = nil
        lastOuterBox = nil
        lastInnerBox = nil
        lostFrameCount = 0
        frameCounter = 0
        hasAcquiredLock = false
        lastDetectionPresentationTime = nil
        lastSuccessfulTrackingTime = nil
        lastContourRefinementFrame = 0
        smoothedCenter = CGPoint(x: 0.5, y: 0.5)
        anchorScreenRadiusPlane = 0
        hasAnchorRadius = false
        anchorZoom = 1
        smoothedZoom = 1
        hasRingFit = false
        smoothedRingCosine = SIMD4<Float>(MachineRectifier.tileRatio, 0, 0, 0)
        smoothedRingSine = .zero
        detectedScreenEllipse = nil
        hasAnchorRadius = false
        referenceMachineDistanceMM = nil
        referenceZoom = 1
        lastFramingTimestamp = nil
    }

    private func lockedPoint(fromCameraPoint point: CGPoint, transform: DigitalGimbalTransform) -> CGPoint {
        guard transform.isActive,
              previewSize.width > 0,
              previewSize.height > 0 else { return point }
        let focal = previewSize.width / (2 * tan(CGFloat(settings.horizontalFOV * .pi / 180) * 0.5))
        let x = (point.x - 0.5) * previewSize.width / max(focal, 1)
        let y = (point.y - 0.5) * previewSize.height / max(focal, 1)
        let sourceRay = simd_normalize(SIMD3<Float>(Float(x), Float(y), 1))
        let inverse = transform.cameraFromLocked.inverse
        let lockedRay = simd_normalize(inverse * sourceRay)
        guard abs(lockedRay.z) > 0.05 else { return point }
        let lockedX = CGFloat(lockedRay.x / lockedRay.z) * focal / previewSize.width + 0.5
        let lockedY = CGFloat(lockedRay.y / lockedRay.z) * focal / previewSize.height + 0.5
        return CGPoint(x: lockedX, y: lockedY)
    }

    private func publishFraming(_ next: MachineGeometryFraming) {
        onFramingUpdate?(next)
        DispatchQueue.main.async { [weak self] in self?.framing = next }
    }

    private func publishStatus(_ next: MachineGeometryLockStatus) {
        guard next != lastPublishedStatus else { return }
        lastPublishedStatus = next
        DispatchQueue.main.async { [weak self] in self?.status = next }
    }

    private func mapRectified(_ rect: CGRect) -> CGRect {
        bounds(of: samplePoints(on: rect).map(mapRectifiedPoint))
    }

    private func samplePoints(on rect: CGRect) -> [CGPoint] {
        let midX = rect.midX
        let midY = rect.midY
        return [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: midY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: midY)
        ]
    }

    private func mapRectifiedPoint(_ point: CGPoint) -> CGPoint {
        LensCoordinateMapper.rectifiedPoint(
            fromFisheye: point,
            sourceSize: sourceSize,
            previewSize: previewSize,
            settings: settings
        )
    }

    private func projectedBounds(
        of rawRect: CGRect,
        gimbalTransform: DigitalGimbalTransform,
        viewRotation: MachineViewRotation
    ) -> CGRect {
        let points = samplePoints(on: rawRect).compactMap { rawPoint -> CGPoint? in
            let rectified = mapRectifiedPoint(rawPoint)
            let locked = lockedPoint(fromCameraPoint: rectified, transform: gimbalTransform)
            return pointInMachineView(locked, rotation: viewRotation)
        }
        return points.count >= 4 ? bounds(of: points) : .zero
    }

    private func machineViewRotation(
        aimingAt center: CGPoint,
        previewSize: CGSize,
        horizontalFOV: Double
    ) -> MachineViewRotation {
        guard previewSize.width > 0, previewSize.height > 0 else { return .identity }
        let radians = min(max(horizontalFOV, 1), 179) * .pi / 180
        let focal = previewSize.width / (2 * tan(CGFloat(radians) * 0.5))
        let rayX = (center.x - 0.5) * previewSize.width / max(focal, 1)
        let rayY = (center.y - 0.5) * previewSize.height / max(focal, 1)
        let forward = simd_normalize(SIMD3<Float>(Float(rayX), Float(rayY), 1))

        let opticalRight = SIMD3<Float>(1, 0, 0)
        var right = opticalRight - simd_dot(opticalRight, forward) * forward
        if simd_length_squared(right) < 0.0001 {
            let opticalDown = SIMD3<Float>(0, 1, 0)
            right = opticalDown - simd_dot(opticalDown, forward) * forward
        }
        right = simd_normalize(right)
        let down = simd_normalize(simd_cross(forward, right))
        return MachineViewRotation(
            right: SIMD4<Float>(right, 0),
            down: SIMD4<Float>(down, 0),
            forward: SIMD4<Float>(forward, 0)
        )
    }

    /// Expresses a tracked rectified ray in the rotated output camera. This is
    /// used to size the outer-ring crop; the Metal renderer rotates the pixels.
    private func pointInMachineView(
        _ point: CGPoint,
        rotation: MachineViewRotation
    ) -> CGPoint? {
        guard previewSize.width > 0, previewSize.height > 0 else { return nil }
        let radians = min(max(settings.horizontalFOV, 1), 179) * .pi / 180
        let focal = previewSize.width / (2 * tan(CGFloat(radians) * 0.5))
        let ray = simd_normalize(SIMD3<Float>(
            Float((point.x - 0.5) * previewSize.width / max(focal, 1)),
            Float((point.y - 0.5) * previewSize.height / max(focal, 1)),
            1
        ))
        let outputRay = simd_normalize(rotation.matrix.inverse * ray)
        guard outputRay.z > 0.05 else { return nil }
        let x = CGFloat(outputRay.x / outputRay.z) * focal / previewSize.width + 0.5
        let y = CGFloat(outputRay.y / outputRay.z) * focal / previewSize.height + 0.5
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func bounds(of points: [CGPoint]) -> CGRect {
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func visionToTopLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    private func isPlausiblePair(outer: CGRect, inner: CGRect) -> Bool {
        let outer = outer.standardized
        let inner = inner.standardized
        guard outer.width > 0.08, outer.height > 0.08,
              inner.width > 0.04, inner.height > 0.04,
              outer.width < 1.02, outer.height < 1.02 else { return false }
        let intersection = outer.intersection(inner)
        guard !intersection.isNull, !intersection.isEmpty else { return false }
        let containedArea = intersection.width * intersection.height
        let innerArea = inner.width * inner.height
        guard innerArea > 0, containedArea / innerArea > 0.72 else { return false }
        let edgeCount = [outer.minX < 0.01, outer.maxX > 0.99, outer.minY < 0.01, outer.maxY > 0.99]
            .filter { $0 }
            .count
        return edgeCount <= 2
    }

    private func stabilizedBox(_ current: CGRect, against previous: CGRect, alpha: CGFloat) -> CGRect {
        CGRect(
            x: previous.minX + (current.minX - previous.minX) * alpha,
            y: previous.minY + (current.minY - previous.minY) * alpha,
            width: previous.width + (current.width - previous.width) * alpha,
            height: previous.height + (current.height - previous.height) * alpha
        )
    }

    private func blendRect(_ previous: CGRect, _ current: CGRect, currentWeight: CGFloat) -> CGRect {
        stabilizedBox(current, against: previous, alpha: currentWeight)
    }

    private func stabilizedEllipse(
        _ current: ScreenEllipse,
        against previous: ScreenEllipse?,
        alpha: CGFloat
    ) -> ScreenEllipse {
        guard let previous else { return current }
        let angleDelta = 0.5 * atan2(
            sin(2 * (current.angle - previous.angle)),
            cos(2 * (current.angle - previous.angle))
        )
        let center = CGPoint(
            x: previous.center.x + (current.center.x - previous.center.x) * alpha,
            y: previous.center.y + (current.center.y - previous.center.y) * alpha
        )
        let majorRadius = previous.majorRadius + (current.majorRadius - previous.majorRadius) * alpha
        let minorRadius = previous.minorRadius + (current.minorRadius - previous.minorRadius) * alpha
        let angle = previous.angle + angleDelta * alpha
        return ScreenEllipse(
            center: center,
            majorRadius: majorRadius,
            minorRadius: minorRadius,
            angle: angle,
            bounds: ellipseBounds(
                center: center,
                majorRadius: majorRadius,
                minorRadius: minorRadius,
                angle: angle
            )
        )
    }

    private func advanceTrackedEllipse(from previousBox: CGRect, to currentBox: CGRect) {
        guard let ellipse = detectedScreenEllipse,
              previousBox.width > 0.001,
              previousBox.height > 0.001 else { return }
        let previous = visionToTopLeft(previousBox)
        let current = visionToTopLeft(currentBox)
        let scaleX = current.width / previous.width
        let scaleY = current.height / previous.height
        guard scaleX.isFinite, scaleY.isFinite,
              scaleX > 0.5, scaleX < 2,
              scaleY > 0.5, scaleY < 2 else { return }
        let scale = sqrt(scaleX * scaleY)
        let center = CGPoint(
            x: ellipse.center.x + current.midX - previous.midX,
            y: ellipse.center.y + current.midY - previous.midY
        )
        let majorRadius = ellipse.majorRadius * scale
        let minorRadius = ellipse.minorRadius * scale
        detectedScreenEllipse = ScreenEllipse(
            center: center,
            majorRadius: majorRadius,
            minorRadius: minorRadius,
            angle: ellipse.angle,
            bounds: ellipseBounds(
                center: center,
                majorRadius: majorRadius,
                minorRadius: minorRadius,
                angle: ellipse.angle
            )
        )
    }

    private func ellipseBounds(
        center: CGPoint,
        majorRadius: CGFloat,
        minorRadius: CGFloat,
        angle: CGFloat
    ) -> CGRect {
        let widthRadius = hypot(majorRadius * cos(angle), minorRadius * sin(angle)) / max(sourceSize.width, 1)
        let heightRadius = hypot(majorRadius * sin(angle), minorRadius * cos(angle)) / max(sourceSize.height, 1)
        return CGRect(
            x: center.x - widthRadius,
            y: center.y - heightRadius,
            width: widthRadius * 2,
            height: heightRadius * 2
        )
    }

    /// Fits an ellipse-like contour using the point covariance, then blends
    /// only a validated result with the detector box. This rejects isolated
    /// highlights while removing the visible rectangle pumping from YOLO.
    private func refineInnerEllipse(
        in pixelBuffer: CVPixelBuffer,
        outer: CGRect,
        predictedInner: CGRect
    ) -> ScreenEllipse? {
        let request = VNDetectContoursRequest()
        request.maximumImageDimension = 512
        request.contrastAdjustment = 1.0
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let outerTopLeft = visionToTopLeft(outer)
        var allContours = Array(observation.topLevelContours)
        var index = 0
        var best: (ellipse: ScreenEllipse, score: CGFloat)?
        while index < allContours.count {
            let contour = allContours[index]
            index += 1
            allContours.append(contentsOf: contour.childContours)
            guard contour.pointCount >= 24 else { continue }
            guard let ellipse = contourEllipseFit(contour) else { continue }
            let topLeft = ellipse.bounds
            guard topLeft.width > 0.04, topLeft.height > 0.04,
                  outerTopLeft.contains(CGPoint(x: topLeft.midX, y: topLeft.midY)) else { continue }
            let overlap = intersectionOverUnion(topLeft, predictedInner)
            guard overlap > 0.12 else { continue }
            let aspect = (topLeft.width * sourceSize.width)
                / max(topLeft.height * sourceSize.height, 0.001)
            guard aspect > 0.45, aspect < 2.20 else { continue }
            let centerDistance = hypot(topLeft.midX - predictedInner.midX, topLeft.midY - predictedInner.midY)
            let score = overlap * 0.72
                + CGFloat(exp(-Double(centerDistance) * 7.0)) * 0.18
                + CGFloat(exp(-abs(log(max(aspect, 0.001))) * 2.0)) * 0.10
            if best == nil || score > best!.score {
                best = (ellipse, score)
            }
        }
        guard let best, best.score > 0.24 else { return nil }
        let bounds = blendRect(predictedInner, best.ellipse.bounds, currentWeight: 0.62)
        return ScreenEllipse(
            center: best.ellipse.center,
            majorRadius: best.ellipse.majorRadius,
            minorRadius: best.ellipse.minorRadius,
            angle: best.ellipse.angle,
            bounds: bounds
        )
    }

    private func contourEllipseFit(_ contour: VNContour) -> ScreenEllipse? {
        var points: [CGPoint] = []
        contour.normalizedPath.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                points.append(element.points[0])
            case .addQuadCurveToPoint:
                points.append(element.points[1])
            case .addCurveToPoint:
                points.append(element.points[2])
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }
        guard points.count >= 12 else { return nil }
        let pixelPoints = points.map {
            CGPoint(x: $0.x * sourceSize.width, y: (1 - $0.y) * sourceSize.height)
        }
        let mean = CGPoint(
            x: pixelPoints.reduce(0) { $0 + $1.x } / CGFloat(pixelPoints.count),
            y: pixelPoints.reduce(0) { $0 + $1.y } / CGFloat(pixelPoints.count)
        )
        var xx: CGFloat = 0
        var yy: CGFloat = 0
        var xy: CGFloat = 0
        for point in pixelPoints {
            let dx = point.x - mean.x
            let dy = point.y - mean.y
            xx += dx * dx
            yy += dy * dy
            xy += dx * dy
        }
        let count = CGFloat(points.count)
        xx /= count
        yy /= count
        xy /= count
        let trace = xx + yy
        let discriminant = max(trace * trace - 4 * (xx * yy - xy * xy), 0)
        let root = sqrt(discriminant)
        let majorVariance = max((trace + root) * 0.5, 0.000001)
        let minorVariance = max((trace - root) * 0.5, 0.000001)
        // Uniform samples around an ellipse have variance a²/2 and b²/2.
        let majorRadius = sqrt(2 * majorVariance)
        let minorRadius = sqrt(2 * minorVariance)
        let aspect = majorRadius / max(minorRadius, 0.001)
        guard majorRadius.isFinite, minorRadius.isFinite,
              majorRadius > 8, minorRadius > 8,
              aspect >= 1, aspect < 3.0 else { return nil }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        let center = CGPoint(x: mean.x / sourceSize.width, y: mean.y / sourceSize.height)
        let fittedBounds = ellipseBounds(
            center: center,
            majorRadius: majorRadius,
            minorRadius: minorRadius,
            angle: angle
        )
        let pathBounds = visionToTopLeft(contour.normalizedPath.boundingBoxOfPath.standardized)
        let width = min(max(fittedBounds.width, pathBounds.width * 0.60), pathBounds.width * 1.18)
        let height = min(max(fittedBounds.height, pathBounds.height * 0.60), pathBounds.height * 1.18)
        let bounds = CGRect(
            x: center.x - width * 0.5,
            y: center.y - height * 0.5,
            width: width,
            height: height
        )
        return ScreenEllipse(
            center: center,
            majorRadius: majorRadius,
            minorRadius: minorRadius,
            angle: angle,
            bounds: bounds
        )
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection.width * intersection.height
        return union > 0 ? intersection.width * intersection.height / union : 0
    }
}

private struct GeometryDetection {
    let outer: CGRect
    let inner: CGRect
    let ellipse: ScreenEllipse?
}

private struct ScreenEllipse {
    let center: CGPoint
    let majorRadius: CGFloat
    let minorRadius: CGFloat
    let angle: CGFloat
    let bounds: CGRect
}

private struct FrameGeometryCandidate {
    let box: CGRect
    let confidence: CGFloat
    let classKind: ClassKind

    enum ClassKind {
        case outer
        case inner
        case unknown
    }
}

/// Vision wrapper kept independent of generated Swift model classes so the
/// same source works with every CodeMagic export of the package model.
private final class FrameGeometryCoreMLDetector {
    private let request: VNCoreMLRequest?
    let loadFailureMessage: String?

    var isAvailable: Bool { request != nil }

    init() {
        guard let url = Bundle.main.url(forResource: "FrameGeometryDetector", withExtension: "mlmodelc") else {
            request = nil
            loadFailureMessage = "App 包内没有 FrameGeometryDetector.mlmodelc。请安装包含机台模型的新版 IPA。"
            return
        }
        do {
            let model = try MLModel(contentsOf: url)
            let visionModel = try VNCoreMLModel(for: model)
            let request = VNCoreMLRequest(model: visionModel)
            request.imageCropAndScaleOption = .scaleFit
            self.request = request
            loadFailureMessage = nil
        } catch {
            request = nil
            loadFailureMessage = "机台模型加载失败：\(error.localizedDescription)"
        }
    }

    func detect(
        in pixelBuffer: CVPixelBuffer,
        priorOuter: CGRect?,
        priorInner: CGRect?
    ) -> GeometryDetection? {
        guard let request else { return nil }
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        } catch {
            return nil
        }

        let observations = (request.results as? [VNRecognizedObjectObservation]) ?? []
        var candidates: [FrameGeometryCandidate] = []
        for observation in observations {
            let confidence = CGFloat(observation.labels.first?.confidence ?? observation.confidence)
            guard confidence >= 0.22 else { continue }
            let box = observation.boundingBox.standardized
            guard box.width > 0.04, box.height > 0.04 else { continue }
            let identifier = observation.labels.first?.identifier.lowercased() ?? ""
            let kind: FrameGeometryCandidate.ClassKind
            if identifier.contains("outer") || identifier.contains("frame") || identifier == "0" {
                kind = .outer
            } else if identifier.contains("inner") || identifier.contains("screen") || identifier == "1" {
                kind = .inner
            } else {
                kind = .unknown
            }
            candidates.append(FrameGeometryCandidate(box: box, confidence: confidence, classKind: kind))
        }
        guard !candidates.isEmpty else { return nil }

        let outerCandidates = candidates.filter { $0.classKind == .outer }
        let innerCandidates = candidates.filter { $0.classKind == .inner }
        var outer = best(candidates: outerCandidates, prior: priorOuter)
        var inner = best(candidates: innerCandidates, prior: priorInner)

        // Some Vision/Core ML versions expose generated numeric labels without
        // preserving the class names. In that case the largest plausible box
        // is the outer frame and the contained smaller box is the screen.
        if outer == nil {
            outer = candidates.max { area($0.box) < area($1.box) }
        }
        if inner == nil, let selectedOuter = outer {
            inner = candidates
                .filter { $0.box != selectedOuter.box && area($0.box) < area(selectedOuter.box) }
                .min { area($0.box) < area($1.box) }
        }

        guard let outer, let inner else { return nil }
        guard plausiblePair(outer.box, inner.box) else { return nil }
        return GeometryDetection(outer: outer.box, inner: inner.box, ellipse: nil)
    }

    private func best(candidates: [FrameGeometryCandidate], prior: CGRect?) -> FrameGeometryCandidate? {
        candidates.max { lhs, rhs in
            score(lhs, prior: prior) < score(rhs, prior: prior)
        }
    }

    private func score(_ candidate: FrameGeometryCandidate, prior: CGRect?) -> CGFloat {
        let box = candidate.box
        let areaScore = CGFloat(exp(-abs(log(max(area(box), 0.001) / 0.20)) * 0.55))
        let centerScore = CGFloat(exp(-hypot(box.midX - 0.5, box.midY - 0.5) * 1.5))
        let continuity = prior.map { max(intersectionOverUnion(box, $0), CGFloat(exp(-hypot(box.midX - $0.midX, box.midY - $0.midY) * 5.0)) * 0.35) } ?? 0.35
        let edgeCount = [box.minX < 0.01, box.maxX > 0.99, box.minY < 0.01, box.maxY > 0.99].filter { $0 }.count
        let edgePenalty = CGFloat(edgeCount) * 0.10 + (area(box) > 0.72 ? 0.26 : 0)
        return candidate.confidence * 0.60 + areaScore * 0.14 + centerScore * 0.10 + continuity * 0.36 - edgePenalty
    }

    private func plausiblePair(_ outer: CGRect, _ inner: CGRect) -> Bool {
        guard outer.width > 0.08, outer.height > 0.08,
              inner.width > 0.04, inner.height > 0.04 else { return false }
        let intersection = outer.intersection(inner)
        guard !intersection.isNull, !intersection.isEmpty else { return false }
        let innerArea = inner.width * inner.height
        guard innerArea > 0,
              intersection.width * intersection.height / innerArea > 0.72 else { return false }
        let edgeCount = [outer.minX < 0.01, outer.maxX > 0.99, outer.minY < 0.01, outer.maxY > 0.99].filter { $0 }.count
        return edgeCount <= 2
    }

    private func area(_ box: CGRect) -> CGFloat { box.width * box.height }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let union = area(lhs) + area(rhs) - area(intersection)
        return union > 0 ? area(intersection) / union : 0
    }
}
