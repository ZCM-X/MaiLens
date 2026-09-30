import Combine
import CoreMotion
import Foundation

struct DigitalGimbalTransform: Equatable {
    /// Relative rotation from the moment the virtual gimbal was enabled.
    /// Positive yaw/pitch values are converted to an opposite crop movement
    /// by the Metal renderer so the original world direction stays in frame.
    var yaw: CGFloat
    var pitch: CGFloat
    var roll: CGFloat
    var isActive: Bool

    static let identity = DigitalGimbalTransform(yaw: 0, pitch: 0, roll: 0, isActive: false)
}

/// Uses gravity, rather than magnetic heading, to level the live camera image.
/// The same motion stream also drives a digital three-axis gimbal. Motion
/// updates are sent directly to the renderer so they do not cause a SwiftUI
/// refresh for every sensor sample.
final class HorizonLockController: ObservableObject {
    @Published private(set) var isEnabled = true
    @Published private(set) var isGimbalEnabled = true
    @Published private(set) var errorMessage: String?

    var onAngleUpdate: ((CGFloat) -> Void)?
    var onGimbalUpdate: ((DigitalGimbalTransform) -> Void)?

    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.mailens.horizon-lock"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var filteredAngle: Double?
    private var filteredYaw: Double = 0
    private var filteredPitch: Double = 0
    private var filteredRoll: Double = 0
    private var referenceAttitude: CMAttitude?
    private var latestAttitude: CMAttitude?

    func start() {
        guard isEnabled || isGimbalEnabled else { return }
        guard motionManager.isDeviceMotionAvailable else {
            DispatchQueue.main.async { self.errorMessage = "此设备暂不支持地平线稳定和模拟云台。" }
            return
        }
        guard !motionManager.isDeviceMotionActive else { return }

        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self else { return }
            guard let motion, error == nil else { return }
            let gravity = motion.gravity

            self.latestAttitude = motion.attitude

            if self.isGimbalEnabled {
                if self.referenceAttitude == nil {
                    self.referenceAttitude = motion.attitude.copy() as? CMAttitude
                    self.filteredYaw = 0
                    self.filteredPitch = 0
                    self.filteredRoll = 0
                }

                if let reference = self.referenceAttitude {
                    let relative = motion.attitude.copy() as! CMAttitude
                    relative.multiply(byInverseOf: reference)
                    let yaw = self.filteredValue(
                        self.filteredYaw,
                        raw: self.limitedAngle(relative.yaw, maximum: 0.95),
                        alpha: 0.20
                    )
                    let pitch = self.filteredValue(
                        self.filteredPitch,
                        raw: self.limitedAngle(relative.pitch, maximum: 0.65),
                        alpha: 0.20
                    )
                    let roll = self.filteredValue(
                        self.filteredRoll,
                        raw: self.limitedAngle(relative.roll, maximum: 0.65),
                        alpha: 0.20
                    )
                    self.filteredYaw = yaw
                    self.filteredPitch = pitch
                    self.filteredRoll = roll
                    self.onGimbalUpdate?(DigitalGimbalTransform(
                        yaw: CGFloat(yaw),
                        pitch: CGFloat(pitch),
                        // Absolute gravity leveling is less prone to drift,
                        // so the relative roll is used only when it is enabled
                        // separately from the horizon lock.
                        roll: self.isEnabled ? 0 : CGFloat(roll),
                        isActive: true
                    ))
                }
            }

            // In the app's portrait camera orientation, gravity projected onto
            // the screen plane gives the horizon's roll around the lens axis.
            if self.isEnabled {
                let horizontalGravity = hypot(gravity.x, gravity.y)
                guard horizontalGravity > 0.20 else { return }
                let rawAngle = atan2(-gravity.x, -gravity.y)
                let limitedAngle = min(max(rawAngle, -0.35), 0.35)

                if let previous = self.filteredAngle {
                    let delta = atan2(sin(limitedAngle - previous), cos(limitedAngle - previous))
                    self.filteredAngle = previous + delta * 0.28
                } else {
                    self.filteredAngle = limitedAngle
                }
                if let filteredAngle = self.filteredAngle {
                    self.onAngleUpdate?(CGFloat(filteredAngle))
                }
            }
        }
        DispatchQueue.main.async { self.errorMessage = nil }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        motionQueue.addOperation { [weak self] in
            guard let self else { return }
            self.filteredAngle = nil
            self.referenceAttitude = nil
            self.latestAttitude = nil
            self.filteredYaw = 0
            self.filteredPitch = 0
            self.filteredRoll = 0
            self.onAngleUpdate?(0)
            self.onGimbalUpdate?(.identity)
        }
    }

    func toggle() {
        isEnabled.toggle()
        if isEnabled {
            start()
        } else {
            motionQueue.addOperation { [weak self] in
                guard let self else { return }
                self.filteredAngle = nil
                self.onAngleUpdate?(0)
                self.emitGimbalTransform()
            }
            if !isGimbalEnabled { stop() }
        }
    }

    func toggleGimbal() {
        isGimbalEnabled.toggle()
        if isGimbalEnabled {
            motionQueue.addOperation { [weak self] in
                guard let self else { return }
                self.referenceAttitude = self.latestAttitude?.copy() as? CMAttitude
                self.filteredYaw = 0
                self.filteredPitch = 0
                self.filteredRoll = 0
                self.emitGimbalTransform()
            }
            start()
        } else {
            motionQueue.addOperation { [weak self] in
                guard let self else { return }
                self.referenceAttitude = nil
                self.filteredYaw = 0
                self.filteredPitch = 0
                self.filteredRoll = 0
                self.onGimbalUpdate?(.identity)
            }
            if !isEnabled { stop() }
        }
    }

    func recenterGimbal() {
        motionQueue.addOperation { [weak self] in
            guard let self else { return }
            self.referenceAttitude = self.latestAttitude?.copy() as? CMAttitude
            self.filteredYaw = 0
            self.filteredPitch = 0
            self.filteredRoll = 0
            self.emitGimbalTransform()
        }
    }

    private func emitGimbalTransform() {
        guard isGimbalEnabled else {
            onGimbalUpdate?(.identity)
            return
        }
        onGimbalUpdate?(DigitalGimbalTransform(
            yaw: CGFloat(filteredYaw),
            pitch: CGFloat(filteredPitch),
            roll: isEnabled ? 0 : CGFloat(filteredRoll),
            isActive: true
        ))
    }

    private func filteredValue(_ previous: Double, raw: Double, alpha: Double) -> Double {
        let delta = atan2(sin(raw - previous), cos(raw - previous))
        return previous + delta * alpha
    }

    private func limitedAngle(_ value: Double, maximum: Double) -> Double {
        min(max(atan2(sin(value), cos(value)), -maximum), maximum)
    }
}
