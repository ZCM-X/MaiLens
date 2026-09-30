import Combine
import CoreML
import CoreGraphics
import CoreVideo
import Foundation
import Vision

enum MachineLockStatus: Equatable {
    case searching
    case tracking
    case lost
    case paused

    var title: String {
        switch self {
        case .searching: return "自动寻找机台"
        case .tracking: return "机台已锁定"
        case .lost: return "目标暂时丢失"
        case .paused: return "自动锁定已暂停"
        }
    }
}

struct MachineAutoLockFraming {
    var center: CGPoint
    var zoom: CGFloat
    var isActive: Bool

    static let identity = MachineAutoLockFraming(center: CGPoint(x: 0.5, y: 0.5), zoom: 1, isActive: false)
}

private enum MachineDetectionSource: Equatable {
    case model
    case contour
}

private struct MachineDetectionCandidate {
    let box: CGRect
    let confidence: CGFloat
    let source: MachineDetectionSource
}

private struct MachineModelDetection {
    let box: CGRect
    let confidence: CGFloat
}

/// Detects the prominent circular game-machine display and feeds a smoothed
/// crop transform to the Metal preview. Detection is automatic; no user ROI is
/// required.
final class MachineAutoLockController: ObservableObject {
    // The virtual gimbal is the primary stabilizer. Machine anchoring remains
    // available as an experiment, but it is deliberately off at launch so a
    // detector box cannot move the shot or fight the attitude lock.
    @Published private(set) var status: MachineLockStatus = .paused
    @Published private(set) var isEnabled = false

    /// Called on the Vision queue. Consumers must make their own thread-safe copy.
    var onFramingUpdate: ((MachineAutoLockFraming) -> Void)?

    private let visionQueue = DispatchQueue(label: "com.mailens.machine-auto-lock", qos: .userInitiated)
    private let sequenceHandler = VNSequenceRequestHandler()
    private let machineModel = MachineCoreMLDetector()
    private var trackingRequest: VNTrackObjectRequest?
    private var settings = LensCorrectionSettings.preliminary
    private var displaySize = CGSize(width: 9, height: 16)
    private var autoLockEnabled = false
    private var frameCounter = 0
    private var lostFrameCount = 0
    private var smoothedCenter = CGPoint(x: 0.5, y: 0.5)
    private var smoothedZoom: CGFloat = 1
    private var smoothedTargetSize: CGFloat?
    private var lastVisionBox: CGRect?
    private var lastStatus: MachineLockStatus = .searching
    private var horizonRadians: CGFloat = 0
    private var gimbal = DigitalGimbalTransform.identity

    func updateSettings(_ value: LensCorrectionSettings) {
        visionQueue.async { [weak self] in self?.settings = value }
    }

    func updatePreviewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        visionQueue.async { [weak self] in self?.displaySize = size }
    }

    func updateHorizonAngle(_ angle: CGFloat) {
        visionQueue.async { [weak self] in self?.horizonRadians = angle }
    }

    func updateGimbalTransform(_ value: DigitalGimbalTransform) {
        visionQueue.async { [weak self] in self?.gimbal = value }
    }

    func toggle() {
        let shouldEnable = !isEnabled
        isEnabled = shouldEnable
        visionQueue.async { [weak self] in
            guard let self else { return }
            self.autoLockEnabled = shouldEnable
            self.resetTracking()
            self.onFramingUpdate?(.identity)
            self.publishStatus(shouldEnable ? .searching : .paused)
        }
    }

    func process(_ pixelBuffer: CVPixelBuffer) {
        visionQueue.async { [weak self] in
            guard let self, self.autoLockEnabled else { return }
            self.processFrame(pixelBuffer)
        }
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        frameCounter += 1

        if machineModel.isAvailable {
            processCoreMLFrame(pixelBuffer)
            return
        }

        // The contour fallback follows the same detector/tracker cadence as
        // the Core ML path. This keeps local Windows previews useful before
        // CodeMagic has bundled MachineDetector.mlmodelc.
        let shouldRedetect = trackingRequest == nil
            || frameCounter % 10 == 0
            || (lostFrameCount > 0 && frameCounter % 3 == 0)
        if shouldRedetect, let candidate = detectMachine(in: pixelBuffer) {
            beginTracking(candidate)
            updateFraming(for: candidate, sourceSize: frameSize(of: pixelBuffer))
            publishStatus(.tracking)
            return
        }

        if !advanceTracker(on: pixelBuffer) && trackingRequest == nil {
            publishStatus(.searching)
        }
    }

    private func processCoreMLFrame(_ pixelBuffer: CVPixelBuffer) {
        // Core ML corrects drift every few frames. Vision tracks on every
        // frame in between, so a lateral phone movement is reflected in the
        // crop immediately instead of waiting for the next YOLO inference.
        let shouldDetect = trackingRequest == nil
            || frameCounter % 8 == 0
            || (lostFrameCount > 0 && frameCounter % 3 == 0)

        if shouldDetect, let candidate = detectMachine(in: pixelBuffer) {
            beginTracking(candidate)
            updateFraming(for: candidate, sourceSize: frameSize(of: pixelBuffer))
            publishStatus(.tracking)
            return
        }

        if !advanceTracker(on: pixelBuffer) {
            // Keep the last crop during a short detector gap. The target may
            // be covered by a hand for a few frames; snapping to the middle
            // here is exactly the failure mode that makes the reference video
            // look unlike a gimbal.
            publishStatus(lastVisionBox == nil ? .searching : .lost)
        }
    }

    private func frameSize(of pixelBuffer: CVPixelBuffer) -> CGSize {
        CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    }

    @discardableResult
    private func advanceTracker(on pixelBuffer: CVPixelBuffer) -> Bool {
        guard let request = trackingRequest else { return false }

        do {
            try sequenceHandler.perform([request], on: pixelBuffer)
            guard let observation = request.results?.first as? VNDetectedObjectObservation,
                  observation.confidence >= 0.15,
                  observation.boundingBox.width > 0.02,
                  observation.boundingBox.height > 0.02 else {
                handleTrackingLoss()
                return false
            }

            request.inputObservation = observation
            lastVisionBox = observation.boundingBox
            lostFrameCount = 0
            updateFraming(for: observation.boundingBox, sourceSize: frameSize(of: pixelBuffer))
            publishStatus(.tracking)
            return true
        } catch {
            handleTrackingLoss()
            return false
        }
    }

    /// Prefer the trained detector when the Core ML artifact is bundled. The
    /// contour detector remains a useful fallback for development builds that
    /// have not run the macOS/Core ML export step yet.
    private func detectMachine(in pixelBuffer: CVPixelBuffer) -> CGRect? {
        var candidates: [MachineDetectionCandidate] = []
        if let modelCandidate = machineModel.detect(in: pixelBuffer, prior: lastVisionBox) {
            candidates.append(MachineDetectionCandidate(
                box: modelCandidate.box,
                confidence: modelCandidate.confidence,
                source: .model
            ))
        }
        if let contourCandidate = detectMachineLikeCircle(in: pixelBuffer) {
            candidates.append(contourCandidate)
        }

        guard !candidates.isEmpty else { return nil }
        let sourceSize = frameSize(of: pixelBuffer)
        return candidates.max { lhs, rhs in
            candidateScore(lhs, prior: lastVisionBox, sourceSize: sourceSize)
                < candidateScore(rhs, prior: lastVisionBox, sourceSize: sourceSize)
        }?.box
    }

    private func detectMachineLikeCircle(in pixelBuffer: CVPixelBuffer) -> MachineDetectionCandidate? {
        let request = VNDetectContoursRequest()
        request.maximumImageDimension = 512
        request.contrastAdjustment = 1.0
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first else { return nil }
        let prior = lastVisionBox
        let frameWidth = Double(CVPixelBufferGetWidth(pixelBuffer))
        let frameHeight = Double(CVPixelBufferGetHeight(pixelBuffer))
        let shortSide = max(min(frameWidth, frameHeight), 1)
        var contours = Array(observation.topLevelContours)
        var index = 0
        var bestBox: CGRect?
        var bestScore = -Double.infinity

        // The display edge is often nested inside a bezel contour, so inspect
        // child contours as well as the outer silhouette.
        while index < contours.count {
            let contour = contours[index]
            index += 1
            contours.append(contentsOf: contour.childContours)
            guard contour.pointCount >= 28 else { continue }

            let box = contour.normalizedPath.boundingBoxOfPath.standardized
            let width = Double(box.width)
            let height = Double(box.height)
            guard width > 0, height > 0 else { continue }
            let area = width * height
            let pixelWidth = width * frameWidth
            let pixelHeight = height * frameHeight
            let circularity = min(pixelWidth, pixelHeight) / max(pixelWidth, pixelHeight)
            let diameterOnShortSide = max(pixelWidth, pixelHeight) / shortSide
            guard area >= 0.012, area <= 0.88,
                  circularity >= 0.62,
                  diameterOnShortSide >= 0.12,
                  diameterOnShortSide <= 1.45 else { continue }

            let centerDistance = hypot(
                (Double(box.midX) - 0.5) * frameWidth / shortSide,
                (Double(box.midY) - 0.5) * frameHeight / shortSide
            )
            let continuity: Double
            if let prior {
                let distance = hypot(box.midX - prior.midX, box.midY - prior.midY)
                continuity = max(
                    overlap(box, prior),
                    exp(-distance * 5.0) * 0.35
                )
            } else {
                continuity = 1.0
            }
            let score = area * circularity * (1.25 - min(centerDistance, 0.75)) * continuity
            if score > bestScore {
                bestScore = score
                bestBox = box
            }
        }
        guard let bestBox else { return nil }
        return MachineDetectionCandidate(
            box: bestBox,
            confidence: CGFloat(min(max(bestScore * 2.0, 0.10), 0.95)),
            source: .contour
        )
    }

    private func candidateScore(
        _ candidate: MachineDetectionCandidate,
        prior: CGRect?,
        sourceSize: CGSize
    ) -> CGFloat {
        let box = candidate.box.standardized
        // Vision boxes are normalized independently by image width and height.
        // Convert back to pixel dimensions so a physically round machine gets
        // a roundness score of 1 in portrait as well as landscape orientation.
        let pixelWidth = box.width * sourceSize.width
        let pixelHeight = box.height * sourceSize.height
        let aspect = pixelWidth / max(pixelHeight, 0.001)
        let shapeScore = CGFloat(exp(-min(abs(log(max(aspect, 0.001))), 3) * 2.2))
        let area = box.width * box.height
        let areaScore = CGFloat(exp(-abs(log(max(area, 0.001) / 0.18)) * 0.65))
        let centerDistance = hypot(box.midX - 0.5, box.midY - 0.5)
        let centerScore = CGFloat(exp(-centerDistance * 1.8))
        let continuity: CGFloat
        if let prior {
            let overlapScore = CGFloat(overlap(box, prior))
            let distance = hypot(box.midX - prior.midX, box.midY - prior.midY)
            continuity = max(overlapScore, CGFloat(exp(-distance * 5.0)) * 0.42)
        } else {
            continuity = 0.42
        }

        let edgeCount = [box.minX < 0.02, box.maxX > 0.98, box.minY < 0.02, box.maxY > 0.98]
            .filter { $0 }
            .count
        var score = candidate.confidence * (candidate.source == .model ? 0.64 : 0.42)
            + shapeScore * 0.28
            + areaScore * 0.10
            + centerScore * 0.07
            + continuity * 0.46

        // A detector box covering the whole portrait frame is usually the
        // ceiling, desk, or a hand. A contour with a clear round silhouette
        // is safer in that case, even when the model's raw confidence is a
        // little higher.
        if area > 0.62 { score -= 0.42 }
        if edgeCount >= 2 { score -= 0.24 }
        if let prior, continuity < 0.08 {
            // Do not jump to another high-contrast object while the tracked
            // machine is briefly occluded.
            score -= 0.30
            if candidate.source == .model && overlap(box, prior) < 0.02 {
                score -= 0.16
            }
        }
        if candidate.source == .contour { score += 0.05 }
        return score
    }

    private func beginTracking(_ box: CGRect) {
        let observation = VNDetectedObjectObservation(boundingBox: box)
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate
        trackingRequest = request
        lastVisionBox = box
        lostFrameCount = 0
    }

    private func updateFraming(for visionBox: CGRect, sourceSize: CGSize) {
        // Vision uses a bottom-left origin; Metal and the fisheye mapper use
        // top-left normalized image coordinates.
        let rawPoints = [
            CGPoint(x: visionBox.minX, y: 1 - visionBox.maxY),
            CGPoint(x: visionBox.midX, y: 1 - visionBox.maxY),
            CGPoint(x: visionBox.maxX, y: 1 - visionBox.maxY),
            CGPoint(x: visionBox.maxX, y: 1 - visionBox.midY),
            CGPoint(x: visionBox.maxX, y: 1 - visionBox.minY),
            CGPoint(x: visionBox.midX, y: 1 - visionBox.minY),
            CGPoint(x: visionBox.minX, y: 1 - visionBox.minY),
            CGPoint(x: visionBox.minX, y: 1 - visionBox.midY),
            CGPoint(x: visionBox.midX, y: 1 - visionBox.midY)
        ]
        let rectified = rawPoints.map {
            LensCoordinateMapper.rectifiedPoint(fromFisheye: $0, sourceSize: sourceSize, previewSize: displaySize, settings: settings)
        }
        guard let rawCenter = rectified.last else { return }

        // The detector runs on the un-stabilized camera frame. Remove the
        // predicted gimbal movement here so the smoothed machine center stays
        // in world coordinates; the renderer adds that movement back when it
        // samples the enlarged crop.
        let gimbalOffset = gimbal.cropOffset(
            horizontalFOV: settings.horizontalFOV,
            previewSize: displaySize
        )
        let center = CGPoint(
            x: rawCenter.x - gimbalOffset.x,
            y: rawCenter.y - gimbalOffset.y
        )

        let minX = rectified.map(\.x).min() ?? center.x
        let maxX = rectified.map(\.x).max() ?? center.x
        let minY = rectified.map(\.y).min() ?? center.y
        let maxY = rectified.map(\.y).max() ?? center.y
        let width = maxX - minX
        let height = maxY - minY
        // Express the target diameter relative to the preview's short side.
        let measuredTargetSize = max(width, height * displaySize.height / displaySize.width)
        // The detector box is allowed to move quickly, but its measured size
        // is deliberately low-pass filtered. This removes the visible pump
        // caused by a hand, bezel highlight, or one-frame Core ML box change.
        if let previousTargetSize = smoothedTargetSize {
            smoothedTargetSize = previousTargetSize
                + (measuredTargetSize - previousTargetSize) * 0.07
        } else {
            smoothedTargetSize = measuredTargetSize
        }
        let targetSize = smoothedTargetSize ?? measuredTargetSize
        // Keep the screen comfortably inside frame; allow a little zoom-out
        // when the machine moves closer, bounded to avoid extreme lens edges.
        let aspect = displaySize.width / max(displaySize.height, 1)
        let cosine = abs(cos(horizonRadians))
        let sine = abs(sin(horizonRadians))
        let horizonFillZoom = max(cosine + sine / max(aspect, 0.01), cosine + sine * aspect)
        let desiredZoom = min(max(0.74 / (max(targetSize, 0.08) * horizonFillZoom), 0.78), 2.6)

        let centerAlpha: CGFloat = 0.24
        let zoomAlpha: CGFloat = 0.12
        smoothedCenter = CGPoint(
            x: smoothedCenter.x + (center.x - smoothedCenter.x) * centerAlpha,
            y: smoothedCenter.y + (center.y - smoothedCenter.y) * centerAlpha
        )
        smoothedZoom += (desiredZoom - smoothedZoom) * zoomAlpha

        onFramingUpdate?(MachineAutoLockFraming(center: smoothedCenter, zoom: smoothedZoom, isActive: true))
    }

    private func handleTrackingLoss() {
        lostFrameCount += 1
        publishStatus(lostFrameCount > 45 ? .searching : .lost)

        guard lostFrameCount > 45 else { return }
        trackingRequest = nil
        lastVisionBox = nil
        smoothedTargetSize = nil
        smoothedCenter.x += (0.5 - smoothedCenter.x) * 0.08
        smoothedCenter.y += (0.5 - smoothedCenter.y) * 0.08
        smoothedZoom += (1.0 - smoothedZoom) * 0.08
        let settled = abs(smoothedCenter.x - 0.5) < 0.003
            && abs(smoothedCenter.y - 0.5) < 0.003
            && abs(smoothedZoom - 1) < 0.01
        if settled {
            smoothedCenter = CGPoint(x: 0.5, y: 0.5)
            smoothedZoom = 1
            onFramingUpdate?(.identity)
        } else {
            onFramingUpdate?(MachineAutoLockFraming(center: smoothedCenter, zoom: smoothedZoom, isActive: true))
        }
    }

    private func resetTracking() {
        trackingRequest = nil
        lastVisionBox = nil
        lostFrameCount = 0
        smoothedCenter = CGPoint(x: 0.5, y: 0.5)
        smoothedZoom = 1
        smoothedTargetSize = nil
    }

    private func publishStatus(_ next: MachineLockStatus) {
        guard next != lastStatus else { return }
        lastStatus = next
        DispatchQueue.main.async { [weak self] in self?.status = next }
    }

    private func overlap(_ lhs: CGRect, _ rhs: CGRect?) -> Double {
        guard let rhs else { return 0 }
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection.width * intersection.height
        guard union > 0 else { return 0 }
        return Double(intersection.width * intersection.height / union)
    }
}

/// Loads the optional ``MachineDetector.mlmodel`` generated by the training
/// workflow and turns Vision's object observations into one stable candidate.
/// Ultralytics can emit several overlapping boxes for the same circular
/// machine.  The aspect-ratio and continuity terms keep the lock on the
/// round target instead of a tall side panel in a livestream layout.
private final class MachineCoreMLDetector {
    private let request: VNCoreMLRequest?

    var isAvailable: Bool { request != nil }

    init() {
        guard let url = Bundle.main.url(forResource: "MachineDetector", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url),
              let visionModel = try? VNCoreMLModel(for: model) else {
            request = nil
            return
        }
        let request = VNCoreMLRequest(model: visionModel)
        // Preserve the portrait camera aspect ratio. scaleFill stretches a
        // round machine into a wide shape before it reaches YOLO, which is a
        // common reason for ceiling/table false positives in this app.
        request.imageCropAndScaleOption = .scaleFit
        self.request = request
    }

    func detect(in pixelBuffer: CVPixelBuffer, prior: CGRect?) -> MachineModelDetection? {
        guard let request else { return nil }
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        } catch {
            return nil
        }

        let observations = (request.results as? [VNRecognizedObjectObservation]) ?? []
        guard !observations.isEmpty else { return nil }

        var best: (box: CGRect, confidence: CGFloat, score: CGFloat)?
        for observation in observations {
            let label = observation.labels.first
            // The current training set has one class. Core ML Tools versions
            // use different identifiers ("machine", "0", or a generated
            // class name), so filtering by a literal label can discard every
            // valid detection.
            let confidence = CGFloat(label?.confidence ?? observation.confidence)
            guard confidence >= 0.10 else { continue }
            let box = observation.boundingBox.standardized
            guard box.width > 0.08, box.height > 0.08 else { continue }

            let frameWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let frameHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            let aspect = (box.width * frameWidth) / max(box.height * frameHeight, 0.001)
            // A circular object remains roughly square after scaleFit. Reject
            // very tall/wide regions that usually represent the desk or a
            // side panel, while allowing a partially cropped machine.
            guard aspect >= 0.40, aspect <= 2.50 else { continue }
            let aspectScore = exp(-min(abs(log(max(aspect, 0.001))), 3) * 2.0)
            let centerDistance = hypot(box.midX - 0.5, box.midY - 0.5)
            let centerScore = exp(-centerDistance * 2.2)
            let continuity = prior.map { CGFloat(overlap(box, $0)) } ?? 0.35
            let edgeCount = [box.minX < 0.02, box.maxX > 0.98, box.minY < 0.02, box.maxY > 0.98]
                .filter { $0 }
                .count
            // A box touching three or four sides is almost always a false
            // positive over the whole portrait frame. Let the contour fallback
            // search for the circular bezel instead of locking the crop to the
            // ceiling and desk.
            guard edgeCount <= 2 else { continue }
            let edgePenalty = CGFloat(edgeCount) * 0.08 + (box.width > 0.96 ? 0.10 : 0)
            let score = confidence * 0.58 + aspectScore * 0.28 + centerScore * 0.08 + continuity * 0.34 - edgePenalty
            if best == nil || score > best!.score {
                best = (box, confidence, score)
            }
        }
        guard let best else { return nil }
        return MachineModelDetection(box: best.box, confidence: best.confidence)
    }

    private func overlap(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection.width * intersection.height
        guard union > 0 else { return 0 }
        return Double(intersection.width * intersection.height / union)
    }
}
