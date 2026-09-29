import Combine
import CoreMotion
import Foundation

/// Uses gravity, rather than magnetic heading, to level the live camera image.
/// The filtered angle is sent directly to the renderer so motion updates do not
/// cause a SwiftUI refresh for every sensor sample.
final class HorizonLockController: ObservableObject {
    @Published private(set) var isEnabled = true
    @Published private(set) var errorMessage: String?

    var onAngleUpdate: ((CGFloat) -> Void)?

    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.mailens.horizon-lock"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var filteredAngle: Double?

    func start() {
        guard isEnabled else { return }
        guard motionManager.isDeviceMotionAvailable else {
            DispatchQueue.main.async { self.errorMessage = "此设备暂不支持地平线稳定。" }
            return
        }
        guard !motionManager.isDeviceMotionActive else { return }

        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self else { return }
            guard let gravity = motion?.gravity, error == nil else { return }

            // In the app's portrait camera orientation, gravity projected onto
            // the screen plane gives the horizon's roll around the lens axis.
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
        DispatchQueue.main.async { self.errorMessage = nil }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        motionQueue.addOperation { [weak self] in
            guard let self else { return }
            self.filteredAngle = nil
            self.onAngleUpdate?(0)
        }
    }

    func toggle() {
        isEnabled.toggle()
        if isEnabled {
            start()
        } else {
            stop()
        }
    }
}
