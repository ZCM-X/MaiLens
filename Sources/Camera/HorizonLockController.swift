import Combine
import CoreGraphics
import CoreMotion
import Foundation
import simd

/// The correction that the renderer applies to a pinhole ray before sampling
/// the fisheye image. A gimbal correction is a 3D rotation, not a 2D crop
/// translation.
struct DigitalGimbalTransform {
    var cameraFromLocked: simd_float3x3
    var timestamp: TimeInterval
    var yaw: CGFloat
    var pitch: CGFloat
    var roll: CGFloat
    var isActive: Bool
    var gimbalActive: Bool

    static let identity = DigitalGimbalTransform(
        cameraFromLocked: matrix_identity_float3x3,
        timestamp: 0,
        isActive: false,
        gimbalActive: false
    )

    init(cameraFromLocked: simd_float3x3,
         timestamp: TimeInterval = 0,
         isActive: Bool,
         gimbalActive: Bool = false) {
        self.cameraFromLocked = cameraFromLocked
        self.timestamp = timestamp
        self.isActive = isActive
        self.gimbalActive = gimbalActive

        // These angles are retained for the optional machine-lock path. The
        // renderer no longer uses them for stabilisation; it uses the full
        // matrix above. The forward ray is enough to estimate yaw and pitch.
        let forward = cameraFromLocked * SIMD3<Float>(0, 0, 1)
        self.yaw = CGFloat(atan2(forward.x, forward.z))
        self.pitch = CGFloat(atan2(forward.y, forward.z))
        let right = cameraFromLocked.columns.0
        self.roll = CGFloat(atan2(right.y, right.x))
    }

    /// Compatibility helper for the optional machine detector. It estimates
    /// where the locked optical axis falls in the current rectified image.
    /// The gimbal renderer itself never uses this approximation.
    func cropOffset(horizontalFOV: Double, previewSize: CGSize) -> CGPoint {
        guard isActive, previewSize.width > 0, previewSize.height > 0 else {
            return .zero
        }
        let horizontalRadians = horizontalFOV * .pi / 180.0
        let aspect = Double(previewSize.width / previewSize.height)
        let verticalRadians = 2.0 * atan(
            tan(horizontalRadians * 0.5) / max(aspect, 0.01)
        )
        return CGPoint(
            x: CGFloat(-tan(Double(yaw)) / (2.0 * tan(horizontalRadians * 0.5))),
            y: CGFloat(tan(Double(pitch)) / (2.0 * tan(verticalRadians * 0.5)))
        )
    }
}

private struct MotionSample {
    var timestamp: TimeInterval
    var relativeDeviceQuaternion: simd_quatf
    var lockVersion: UInt64
}

/// CoreMotion-backed virtual gimbal. This follows the working FisheyeGimbal
/// implementation: latch a levelled world attitude, build the correction from
/// the raw attitude (so fast shake is corrected too), and sample the motion
/// history at the camera frame timestamp.
final class HorizonLockController: ObservableObject {
    @Published private(set) var isEnabled = true
    @Published private(set) var isGimbalEnabled = true
    @Published private(set) var errorMessage: String?

    /// Kept as separate callbacks so the optional machine detector can still
    /// display its status. The preview uses `renderTransform(forFrameAt:)` for
    /// frame-timed pose selection.
    var onAngleUpdate: ((CGFloat) -> Void)?
    var onGimbalUpdate: ((DigitalGimbalTransform) -> Void)?

    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.mailens.virtual-gimbal"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let stateLock = NSLock()

    private var samples: [MotionSample] = []
    private let maxSampleCount = 48
    private var filtered: simd_quatf
    private var lockedQuaternion: simd_quatf
    private var gravityFiltered = SIMD3<Float>(0, -1, 0)
    private var horizonQuaternion: simd_quatf
    private var hasSample = false
    private var hasGravity = false
    private var lastTimestamp: TimeInterval = 0
    private var lockVersion: UInt64 = 0
    private var gimbalEnabledValue = true
    private var horizonEnabledValue = true
    private var latestTransform = DigitalGimbalTransform.identity
    private var horizonTiltValue: CGFloat = 0

    // Camera coordinates are +X right, +Y down, +Z out through the back
    // camera. Core Motion's device coordinates use +Y up and +Z toward the
    // user, hence the two sign flips.
    private let cameraToDevice = simd_float3x3(columns: (
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(0, -1, 0),
        SIMD3<Float>(0, 0, -1)
    ))

    init() {
        filtered = Self.identityQuaternion()
        lockedQuaternion = Self.identityQuaternion()
        horizonQuaternion = Self.identityQuaternion()
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            publishError("此设备暂不支持地平线稳定和模拟云台。")
            return
        }
        guard !motionManager.isDeviceMotionActive else { return }

        motionManager.deviceMotionUpdateInterval = 1.0 / 120.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical,
                                               to: motionQueue) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.publishError(error.localizedDescription)
                return
            }
            guard let motion else { return }
            self.consume(motion)
        }
        DispatchQueue.main.async { [weak self] in self?.errorMessage = nil }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        stateLock.lock()
        resetStateLocked()
        stateLock.unlock()
        onGimbalUpdate?(.identity)
        onAngleUpdate?(0)
    }

    func toggle() {
        stateLock.lock()
        horizonEnabledValue.toggle()
        let active = gimbalEnabledValue || horizonEnabledValue
        let transform = setRenderSampleLocked(
            quaternion: active ? currentRelativeQuaternionLocked() : Self.identityQuaternion(),
            timestamp: lastTimestamp
        )
        let angle = horizonEnabledValue ? horizonTiltValue : 0
        let enabled = horizonEnabledValue
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.isEnabled = enabled
        }
        onGimbalUpdate?(transform)
        onAngleUpdate?(angle)
        if !active {
            motionManager.stopDeviceMotionUpdates()
        } else {
            start()
        }
    }

    func toggleGimbal() {
        stateLock.lock()
        gimbalEnabledValue.toggle()
        if gimbalEnabledValue, hasSample {
            lockedQuaternion = levelLockedAttitude(from: filtered)
        }
        let active = gimbalEnabledValue || horizonEnabledValue
        let transform = setRenderSampleLocked(
            quaternion: active ? currentRelativeQuaternionLocked() : Self.identityQuaternion(),
            timestamp: lastTimestamp
        )
        let enabled = gimbalEnabledValue
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.isGimbalEnabled = enabled
        }
        onGimbalUpdate?(transform)
        if !active {
            motionManager.stopDeviceMotionUpdates()
        } else {
            start()
        }
    }

    /// Latches the current pointing direction. The roll is rebuilt from
    /// gravity, so pressing this button while holding the phone crooked does
    /// not bake that crooked horizon into the shot.
    func recenterGimbal() {
        stateLock.lock()
        guard hasSample else {
            stateLock.unlock()
            return
        }
        lockedQuaternion = levelLockedAttitude(from: filtered)
        let transform = setRenderSampleLocked(
            quaternion: currentRelativeQuaternionLocked(),
            timestamp: lastTimestamp
        )
        stateLock.unlock()
        onGimbalUpdate?(transform)
    }

    /// Returns the correction belonging to the camera frame. CoreMotion and
    /// AVCaptureVideoDataOutput run at different cadences; interpolating the
    /// short history avoids alternating old/new poses on the preview.
    func renderTransform(forFrameAt frameTime: TimeInterval) -> DigitalGimbalTransform {
        stateLock.lock()
        guard hasSample else {
            stateLock.unlock()
            return .identity
        }

        let usable = frameTime.isFinite && frameTime > 0
            && abs(frameTime - lastTimestamp) < 1.0
        let requested = usable ? frameTime : lastTimestamp
        let sample = usable ? sampleLocked(at: requested) : MotionSample(
            timestamp: lastTimestamp,
            relativeDeviceQuaternion: currentRelativeQuaternionLocked(),
            lockVersion: lockVersion
        )
        let active = gimbalEnabledValue || horizonEnabledValue
        let gimbalActive = gimbalEnabledValue
        let matrix = active
            ? cameraToDevice * simd_float3x3(sample.relativeDeviceQuaternion) * cameraToDevice
            : matrix_identity_float3x3
        stateLock.unlock()
        return DigitalGimbalTransform(cameraFromLocked: matrix,
                                      timestamp: sample.timestamp,
                                      isActive: active,
                                      gimbalActive: gimbalActive)
    }

    private func consume(_ deviceMotion: CMDeviceMotion) {
        let attitude = deviceMotion.attitude.quaternion
        let current = simd_quatf(ix: Float(attitude.x),
                                 iy: Float(attitude.y),
                                 iz: Float(attitude.z),
                                 r: Float(attitude.w))
        let timestamp = deviceMotion.timestamp
        let gravity = SIMD3<Float>(Float(deviceMotion.gravity.x),
                                   Float(deviceMotion.gravity.y),
                                   Float(deviceMotion.gravity.z))

        stateLock.lock()
        if !hasSample {
            hasSample = true
            filtered = current
            gravityFiltered = gravity
            hasGravity = true
            lockedQuaternion = levelLockedAttitude(from: current)
            lastTimestamp = timestamp
        }

        let dt = min(max(timestamp - lastTimestamp, 1.0 / 240.0), 0.25)
        lastTimestamp = timestamp
        // Keep the filtered attitude only for the latch. The correction below
        // deliberately uses `current`, so fast shake is not left behind.
        let attitudeAlpha = Float(1 - exp(-dt / 0.055))
        filtered = slerpShortest(filtered, current,
                                 amount: min(max(attitudeAlpha, 0), 1))

        let gravityAlpha = Float(1 - exp(-dt / 0.06))
        gravityFiltered += (gravity - gravityFiltered) * gravityAlpha
        let gravityLength = simd_length(gravityFiltered)
        if gravityLength > 0.001 { gravityFiltered /= gravityLength }

        let relative = currentRelativeQuaternionLocked(rawAttitude: current)
        let active = gimbalEnabledValue || horizonEnabledValue
        let matrix = active
            ? cameraToDevice * simd_float3x3(relative) * cameraToDevice
            : matrix_identity_float3x3
        let transform = DigitalGimbalTransform(cameraFromLocked: matrix,
                                                timestamp: timestamp,
                                                isActive: active,
                                                gimbalActive: gimbalEnabledValue)
        latestTransform = transform
        samples.append(MotionSample(timestamp: timestamp,
                                    relativeDeviceQuaternion: relative,
                                    lockVersion: lockVersion))
        if samples.count > maxSampleCount {
            samples.removeFirst(samples.count - maxSampleCount)
        }
        let horizonAngle = horizonTiltValue
        let horizonIsEnabled = horizonEnabledValue
        stateLock.unlock()

        onGimbalUpdate?(transform)
        onAngleUpdate?(horizonIsEnabled ? horizonAngle : 0)
    }

    /// Must be called with `stateLock` held.
    private func currentRelativeQuaternionLocked(rawAttitude: simd_quatf? = nil) -> simd_quatf {
        let raw = rawAttitude ?? filtered
        if gimbalEnabledValue {
            // Raw attitude gives q_true^-1 * q_locked, correcting fast shake
            // that a low-pass-only implementation leaves visible.
            return raw.inverse * lockedQuaternion
        }
        if horizonEnabledValue {
            return horizonCorrectionLocked()
        }
        return Self.identityQuaternion()
    }

    /// Must be called with `stateLock` held.
    private func setRenderSampleLocked(quaternion: simd_quatf,
                                       timestamp: TimeInterval) -> DigitalGimbalTransform {
        lockVersion &+= 1
        samples.removeAll(keepingCapacity: true)
        samples.append(MotionSample(timestamp: timestamp,
                                    relativeDeviceQuaternion: quaternion,
                                    lockVersion: lockVersion))
        let active = gimbalEnabledValue || horizonEnabledValue
        let matrix = active
            ? cameraToDevice * simd_float3x3(quaternion) * cameraToDevice
            : matrix_identity_float3x3
        let transform = DigitalGimbalTransform(cameraFromLocked: matrix,
                                                timestamp: timestamp,
                                                isActive: active,
                                                gimbalActive: gimbalEnabledValue)
        latestTransform = transform
        return transform
    }

    /// Must be called with `stateLock` held.
    private func levelLockedAttitude(from attitude: simd_quatf) -> simd_quatf {
        let gravityWorld = attitude.act(gravityFiltered)
        let gravityLength = simd_length(gravityWorld)
        guard gravityLength > 0.05, hasGravity else { return attitude }
        let vertical = gravityWorld / gravityLength

        let cameraToWorld = simd_float3x3(attitude) * cameraToDevice
        var forward = cameraToWorld * SIMD3<Float>(0, 0, 1)
        let forwardLength = simd_length(forward)
        guard forwardLength > 0.05 else { return attitude }
        forward /= forwardLength

        let cameraRight = cameraToWorld * SIMD3<Float>(1, 0, 0)
        var right = simd_cross(forward, vertical)
        let rightLength = simd_length(right)
        guard rightLength > 0.15 else { return attitude }
        right /= rightLength
        if simd_dot(right, cameraRight) < 0 { right = -right }

        let down = simd_cross(forward, right)
        let lockedCameraToWorld = simd_float3x3(columns: (right, down, forward))
        return simd_quatf(lockedCameraToWorld * cameraToDevice)
    }

    /// Must be called with `stateLock` held.
    private func horizonCorrectionLocked() -> simd_quatf {
        let g = cameraToDevice * gravityFiltered
        let planar = (g.x * g.x + g.y * g.y).squareRoot()
        guard planar > 0.2 else { return horizonQuaternion }
        let theta = atan2(-g.x, g.y)
        horizonTiltValue = CGFloat(theta)
        horizonQuaternion = simd_quatf(angle: -theta,
                                       axis: SIMD3<Float>(0, 0, 1))
        return horizonQuaternion
    }

    /// Must be called with `stateLock` held.
    private func sampleLocked(at time: TimeInterval) -> MotionSample {
        guard let first = samples.first, let last = samples.last else {
            return MotionSample(timestamp: lastTimestamp,
                                relativeDeviceQuaternion: currentRelativeQuaternionLocked(),
                                lockVersion: lockVersion)
        }
        if time <= first.timestamp { return first }
        if time >= last.timestamp { return last }

        for index in 1..<samples.count {
            let upper = samples[index]
            guard time <= upper.timestamp else { continue }
            let lower = samples[index - 1]
            guard upper.lockVersion == lower.lockVersion else { return lower }
            let span = max(upper.timestamp - lower.timestamp, 0.000001)
            let amount = Float(min(max((time - lower.timestamp) / span, 0), 1))
            return MotionSample(
                timestamp: time,
                relativeDeviceQuaternion: slerpShortest(
                    lower.relativeDeviceQuaternion,
                    upper.relativeDeviceQuaternion,
                    amount: amount
                ),
                lockVersion: upper.lockVersion
            )
        }
        return last
    }

    /// Must be called with `stateLock` held.
    private func resetStateLocked() {
        samples.removeAll(keepingCapacity: true)
        filtered = Self.identityQuaternion()
        lockedQuaternion = Self.identityQuaternion()
        gravityFiltered = SIMD3<Float>(0, -1, 0)
        horizonQuaternion = Self.identityQuaternion()
        hasSample = false
        hasGravity = false
        lastTimestamp = 0
        lockVersion = 0
        latestTransform = .identity
        horizonTiltValue = 0
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.errorMessage = message }
    }

    private func slerpShortest(_ a: simd_quatf,
                               _ b: simd_quatf,
                               amount: Float) -> simd_quatf {
        let av = SIMD4<Float>(a.imag.x, a.imag.y, a.imag.z, a.real)
        var bv = SIMD4<Float>(b.imag.x, b.imag.y, b.imag.z, b.real)
        var dot = simd_dot(av, bv)
        if dot < 0 { bv = -bv; dot = -dot }
        let t = min(max(amount, 0), 1)
        let result: SIMD4<Float>
        if dot > 0.9995 {
            result = simd_normalize(av + (bv - av) * t)
        } else {
            let theta = acos(min(max(dot, -1), 1))
            let sinTheta = max(sin(theta), 0.00001)
            let wa = sin((1 - t) * theta) / sinTheta
            let wb = sin(t * theta) / sinTheta
            result = simd_normalize(av * wa + bv * wb)
        }
        return simd_quatf(ix: result.x, iy: result.y, iz: result.z, r: result.w)
    }

    private static func identityQuaternion() -> simd_quatf {
        simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    }
}
