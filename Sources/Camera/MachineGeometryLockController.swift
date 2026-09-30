import Combine
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

enum MachineGeometryLockStatus: Equatable {
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

/// The framing state consumed by the Metal renderer. All coordinates are in
/// top-left normalized rectified-image space, so the controller can keep the
/// target in a stable world position while the phone moves underneath it.
struct MachineGeometryFraming: Equatable {
    var center: CGPoint
    var zoom: CGFloat
    var stretchX: CGFloat
    var stretchY: CGFloat
    var isActive: Bool

    var leftGap: CGFloat = 0
    var rightGap: CGFloat = 0
    var topGap: CGFloat = 0
    var bottomGap: CGFloat = 0

    static let identity = MachineGeometryFraming(
        center: CGPoint(x: 0.5, y: 0.5),
        zoom: 1,
        stretchX: 1,
        stretchY: 1,
        isActive: false
    )
}

/// Runs the two-class outer-frame/inner-screen detector and turns its noisy
/// boxes into a slow, gimbal-like crop. The eight gameplay judgement markers
/// are deliberately not involved: they are user-specific chart coordinates,
/// not physical geometry.
final class MachineGeometryLockController: ObservableObject {
    @Published private(set) var status: MachineGeometryLockStatus = .searching
    @Published private(set) var isEnabled = true
    @Published private(set) var framing = MachineGeometryFraming.identity
    @Published private(set) var detectorAvailable = false

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
    private var trackingRequest: VNTrackObjectRequest?
    private var lastOuterBox: CGRect?
    private var lastInnerBox: CGRect?
    private var settings = LensCorrectionSettings.preliminary
    private var previewSize = CGSize(width: 9, height: 16)
    private var sourceSize = CGSize(width: 9, height: 16)
    private var gimbal = DigitalGimbalTransform.identity
    private var horizonRadians: CGFloat = 0
    private var smoothedCenter = CGPoint(x: 0.5, y: 0.5)
    private var smoothedZoom: CGFloat = 1
    private var smoothedStretchX: CGFloat = 1
    private var smoothedStretchY: CGFloat = 1
    private var lastPublishedStatus: MachineGeometryLockStatus = .searching

    init() {
        detectorAvailable = detector.isAvailable
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
            self.trackingRequest = nil
            self.lastOuterBox = nil
            self.lastInnerBox = nil
            self.lostFrameCount = 0
            self.publishFraming(.identity)
            self.publishStatus(.paused)
        }
    }

    func updateSettings(_ value: LensCorrectionSettings) {
        visionQueue.async { [weak self] in self?.settings = value }
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

    func process(_ pixelBuffer: CVPixelBuffer) {
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
                self.processFrame(pixelBuffer)
            }
            self.frameGate.lock()
            self.framePending = false
            self.frameGate.unlock()
        }
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        frameCounter &+= 1
        sourceSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        let needsDetection = detector.isAvailable
            ? trackingRequest == nil || frameCounter % 8 == 0 || lostFrameCount > 0
            : trackingRequest == nil || frameCounter % 6 == 0 || lostFrameCount > 0

        if needsDetection, let detection = detectGeometry(in: pixelBuffer) {
            beginTracking(outer: detection.outer, inner: detection.inner)
            updateFraming(outer: detection.outer, inner: detection.inner)
            publishStatus(.tracking)
            return
        }

        if advanceTracker(on: pixelBuffer) {
            publishStatus(.tracking)
        } else if trackingRequest == nil {
            publishStatus(.searching)
        } else {
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
        let refinedInner = refineInnerEllipse(
            in: pixelBuffer,
            outer: raw.outer,
            predictedInner: raw.inner
        ) ?? raw.inner
        guard isPlausiblePair(outer: raw.outer, inner: refinedInner) else { return nil }
        return GeometryDetection(outer: raw.outer, inner: refinedInner)
    }

    private func advanceTracker(on pixelBuffer: CVPixelBuffer) -> Bool {
        guard let request = trackingRequest else { return false }
        do {
            try sequenceHandler.perform([request], on: pixelBuffer)
            guard let observation = request.results?.first as? VNDetectedObjectObservation,
                  observation.confidence >= 0.16,
                  observation.boundingBox.width > 0.03,
                  observation.boundingBox.height > 0.03 else {
                handleTrackingLoss()
                return false
            }

            request.inputObservation = observation
            let previousOuter = lastOuterBox ?? observation.boundingBox
            let trackedOuter = stabilizedBox(observation.boundingBox, against: previousOuter, alpha: 0.42)
            let trackedInner: CGRect
            if let previousInner = lastInnerBox {
                let oldCenter = CGPoint(x: previousOuter.midX, y: previousOuter.midY)
                let newCenter = CGPoint(x: trackedOuter.midX, y: trackedOuter.midY)
                let scaleX = trackedOuter.width / max(previousOuter.width, 0.001)
                let scaleY = trackedOuter.height / max(previousOuter.height, 0.001)
                trackedInner = CGRect(
                    x: newCenter.x + (previousInner.minX - oldCenter.x) * scaleX,
                    y: newCenter.y + (previousInner.minY - oldCenter.y) * scaleY,
                    width: previousInner.width * scaleX,
                    height: previousInner.height * scaleY
                )
            } else {
                trackedInner = inset(trackedOuter, fraction: 0.20)
            }
            lastOuterBox = trackedOuter
            lastInnerBox = trackedInner
            lostFrameCount = 0
            updateFraming(outer: trackedOuter, inner: trackedInner)
            return true
        } catch {
            handleTrackingLoss()
            return false
        }
    }

    private func beginTracking(outer: CGRect, inner: CGRect) {
        trackingRequest = VNTrackObjectRequest(
            detectedObjectObservation: VNDetectedObjectObservation(boundingBox: outer)
        )
        trackingRequest?.trackingLevel = .accurate
        lastOuterBox = outer
        lastInnerBox = inner
        lostFrameCount = 0
    }

    private func updateFraming(outer: CGRect, inner: CGRect) {
        let outerTopLeft = visionToTopLeft(outer)
        let innerTopLeft = visionToTopLeft(inner)
        guard isPlausiblePair(outer: outerTopLeft, inner: innerTopLeft) else { return }

        let mappedOuter = mapRectified(outerTopLeft)
        let mappedInner = mapRectified(innerTopLeft)
        let center = CGPoint(x: mappedInner.midX, y: mappedInner.midY)

        // Detector boxes are normalized to the source image. Correct for the
        // current virtual-gimbal pose before storing the target in the locked
        // coordinate system; the shader then applies the pose to every ray.
        let gimbalOffset = gimbal.cropOffset(
            horizontalFOV: settings.horizontalFOV,
            previewSize: previewSize
        )
        let lockedCenter = CGPoint(
            x: center.x - gimbalOffset.x,
            y: center.y - gimbalOffset.y
        )

        let targetSize = max(
            mappedInner.width,
            mappedInner.height * previewSize.height / max(previewSize.width, 1)
        )
        guard targetSize.isFinite, targetSize > 0.025, targetSize < 1.6 else { return }

        let aspect = previewSize.width * max(mappedInner.width, 0.001)
            / max(previewSize.height * mappedInner.height, 0.001)
        let desiredStretchX = min(max(aspect, 0.90), 1.10)
        let desiredStretchY: CGFloat = 1
        let horizonFill = max(
            abs(cos(horizonRadians)) + abs(sin(horizonRadians)) / max(previewSize.width / max(previewSize.height, 1), 0.01),
            abs(cos(horizonRadians)) + abs(sin(horizonRadians)) * previewSize.width / max(previewSize.height, 1)
        )
        let desiredZoom = min(
            max(0.72 / (max(targetSize, 0.06) * max(horizonFill, 1)), 0.78),
            2.8
        )

        smoothedCenter = CGPoint(
            x: smoothedCenter.x + (lockedCenter.x - smoothedCenter.x) * 0.20,
            y: smoothedCenter.y + (lockedCenter.y - smoothedCenter.y) * 0.20
        )
        smoothedZoom += (desiredZoom - smoothedZoom) * 0.10
        smoothedStretchX += (desiredStretchX - smoothedStretchX) * 0.08
        smoothedStretchY += (desiredStretchY - smoothedStretchY) * 0.08

        let current = MachineGeometryFraming(
            center: smoothedCenter,
            zoom: smoothedZoom,
            stretchX: smoothedStretchX,
            stretchY: smoothedStretchY,
            isActive: true,
            leftGap: max(innerTopLeft.minX - outerTopLeft.minX, 0),
            rightGap: max(outerTopLeft.maxX - innerTopLeft.maxX, 0),
            topGap: max(innerTopLeft.minY - outerTopLeft.minY, 0),
            bottomGap: max(outerTopLeft.maxY - innerTopLeft.maxY, 0)
        )
        publishFraming(current)
    }

    private func handleTrackingLoss() {
        lostFrameCount += 1
        publishStatus(lostFrameCount > 45 ? .searching : .lost)
        guard lostFrameCount > 45 else { return }

        trackingRequest = nil
        lastOuterBox = nil
        lastInnerBox = nil
        smoothedCenter.x += (0.5 - smoothedCenter.x) * 0.06
        smoothedCenter.y += (0.5 - smoothedCenter.y) * 0.06
        smoothedZoom += (1 - smoothedZoom) * 0.06
        smoothedStretchX += (1 - smoothedStretchX) * 0.06
        smoothedStretchY += (1 - smoothedStretchY) * 0.06

        if abs(smoothedCenter.x - 0.5) < 0.003,
           abs(smoothedCenter.y - 0.5) < 0.003,
           abs(smoothedZoom - 1) < 0.01 {
            publishFraming(.identity)
        } else {
            publishFraming(MachineGeometryFraming(
                center: smoothedCenter,
                zoom: smoothedZoom,
                stretchX: smoothedStretchX,
                stretchY: smoothedStretchY,
                isActive: true
            ))
        }
    }

    private func resetTracking() {
        trackingRequest = nil
        lastOuterBox = nil
        lastInnerBox = nil
        lostFrameCount = 0
        frameCounter = 0
        smoothedCenter = CGPoint(x: 0.5, y: 0.5)
        smoothedZoom = 1
        smoothedStretchX = 1
        smoothedStretchY = 1
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
        let points = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ].map {
            LensCoordinateMapper.rectifiedPoint(
                fromFisheye: $0,
                sourceSize: sourceSize,
                previewSize: previewSize,
                settings: settings
            )
        }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(
            x: xs.min() ?? rect.minX,
            y: ys.min() ?? rect.minY,
            width: (xs.max() ?? rect.maxX) - (xs.min() ?? rect.minX),
            height: (ys.max() ?? rect.maxY) - (ys.min() ?? rect.minY)
        )
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

    private func inset(_ box: CGRect, fraction: CGFloat) -> CGRect {
        box.insetBy(dx: box.width * fraction, dy: box.height * fraction)
    }

    /// Fits an ellipse-like contour using the point covariance, then blends
    /// only a validated result with the detector box. This rejects isolated
    /// highlights while removing the visible rectangle pumping from YOLO.
    private func refineInnerEllipse(
        in pixelBuffer: CVPixelBuffer,
        outer: CGRect,
        predictedInner: CGRect
    ) -> CGRect? {
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
        var best: (box: CGRect, score: CGFloat)?
        while index < allContours.count {
            let contour = allContours[index]
            index += 1
            allContours.append(contentsOf: contour.childContours)
            guard contour.pointCount >= 24 else { continue }
            let box = contourEllipseBounds(contour)
                ?? contour.normalizedPath.boundingBoxOfPath.standardized
            let topLeft = visionToTopLeft(box)
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
                best = (topLeft, score)
            }
        }
        guard let best, best.score > 0.24 else { return nil }
        return CGRect(
            x: predictedInner.minX * 0.38 + best.box.minX * 0.62,
            y: predictedInner.minY * 0.38 + best.box.minY * 0.62,
            width: predictedInner.width * 0.38 + best.box.width * 0.62,
            height: predictedInner.height * 0.38 + best.box.height * 0.62
        )
    }

    private func contourEllipseBounds(_ contour: VNContour) -> CGRect? {
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
        let mean = CGPoint(
            x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
            y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
        )
        var xx: CGFloat = 0
        var yy: CGFloat = 0
        var xy: CGFloat = 0
        for point in points {
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
        let majorAxis = sqrt(2 * majorVariance)
        let minorAxis = sqrt(2 * minorVariance)
        guard majorAxis.isFinite, minorAxis.isFinite,
              majorAxis > 0.015, minorAxis > 0.015 else { return nil }
        let pathBounds = contour.normalizedPath.boundingBoxOfPath.standardized
        let width = min(max(majorAxis * 2, pathBounds.width * 0.60), pathBounds.width * 1.18)
        let height = min(max(minorAxis * 2, pathBounds.height * 0.60), pathBounds.height * 1.18)
        return CGRect(
            x: mean.x - width * 0.5,
            y: mean.y - height * 0.5,
            width: width,
            height: height
        ).standardized
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

    var isAvailable: Bool { request != nil }

    init() {
        guard let url = Bundle.main.url(forResource: "FrameGeometryDetector", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url),
              let visionModel = try? VNCoreMLModel(for: model) else {
            request = nil
            return
        }
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFit
        self.request = request
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
        return GeometryDetection(outer: outer.box, inner: inner.box)
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
