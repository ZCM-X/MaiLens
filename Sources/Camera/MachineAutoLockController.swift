import Combine
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

/// Detects the prominent circular game-machine display and feeds a smoothed
/// crop transform to the Metal preview. Detection is automatic; no user ROI is
/// required.
final class MachineAutoLockController: ObservableObject {
    @Published private(set) var status: MachineLockStatus = .searching
    @Published private(set) var isEnabled = true

    /// Called on the Vision queue. Consumers must make their own thread-safe copy.
    var onFramingUpdate: ((MachineAutoLockFraming) -> Void)?

    private let visionQueue = DispatchQueue(label: "com.mailens.machine-auto-lock", qos: .userInitiated)
    private let sequenceHandler = VNSequenceRequestHandler()
    private var trackingRequest: VNTrackObjectRequest?
    private var settings = LensCorrectionSettings.preliminary
    private var displaySize = CGSize(width: 9, height: 16)
    private var autoLockEnabled = true
    private var frameCounter = 0
    private var lostFrameCount = 0
    private var smoothedCenter = CGPoint(x: 0.5, y: 0.5)
    private var smoothedZoom: CGFloat = 1
    private var lastVisionBox: CGRect?
    private var lastStatus: MachineLockStatus = .searching

    func updateSettings(_ value: LensCorrectionSettings) {
        visionQueue.async { [weak self] in self?.settings = value }
    }

    func updatePreviewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        visionQueue.async { [weak self] in self?.displaySize = size }
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
        let shouldRedetect = trackingRequest == nil || frameCounter % 12 == 0 || (lostFrameCount > 0 && frameCounter % 3 == 0)
        if shouldRedetect, let candidate = detectMachineLikeCircle(in: pixelBuffer) {
            if trackingRequest == nil || lostFrameCount > 4 || overlap(candidate, lastVisionBox) > 0.12 {
                beginTracking(candidate)
            }
        }

        guard let request = trackingRequest else {
            if frameCounter % 12 == 1 { publishStatus(.searching) }
            return
        }

        do {
            try sequenceHandler.perform([request], on: pixelBuffer)
            guard let observation = request.results?.first as? VNDetectedObjectObservation,
                  observation.confidence >= 0.18 else {
                handleTrackingLoss()
                return
            }

            request.inputObservation = observation
            lastVisionBox = observation.boundingBox
            lostFrameCount = 0
            let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            updateFraming(for: observation.boundingBox, sourceSize: frameSize)
            publishStatus(.tracking)
        } catch {
            handleTrackingLoss()
        }
    }

    private func detectMachineLikeCircle(in pixelBuffer: CVPixelBuffer) -> CGRect? {
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
            let continuity = prior == nil ? 1.0 : max(0.35, overlap(box, prior))
            let score = area * circularity * (1.25 - min(centerDistance, 0.75)) * continuity
            if score > bestScore {
                bestScore = score
                bestBox = box
            }
        }
        return bestBox
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
        guard let center = rectified.last else { return }

        let minX = rectified.map(\.x).min() ?? center.x
        let maxX = rectified.map(\.x).max() ?? center.x
        let minY = rectified.map(\.y).min() ?? center.y
        let maxY = rectified.map(\.y).max() ?? center.y
        let width = maxX - minX
        let height = maxY - minY
        // Express the target diameter relative to the preview's short side.
        let targetSize = max(width, height * displaySize.height / displaySize.width)
        // Keep the screen comfortably inside frame; allow a little zoom-out
        // when the machine moves closer, bounded to avoid extreme lens edges.
        let desiredZoom = min(max(0.74 / max(targetSize, 0.08), 0.78), 2.6)

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
