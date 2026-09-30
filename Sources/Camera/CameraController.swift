import AVFoundation
import Combine
import CoreVideo
import Foundation
import CoreMedia

final class CameraController: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var cameraName = "等待摄像头"
    @Published private(set) var errorMessage: String?
    @Published private(set) var audioWarning: String?
    @Published private(set) var focusLocked = false
    @Published private(set) var exposureLocked = false
    @Published private(set) var exposureBias: Double = 0
    @Published private(set) var focusExposureError: String?

    let session = AVCaptureSession()
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudioSample: ((CMSampleBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.mailens.camera-session")
    private let outputQueue = DispatchQueue(label: "com.mailens.camera-frames", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let audioOutputQueue = DispatchQueue(label: "com.mailens.camera-audio", qos: .userInitiated)
    private var isConfigured = false
    private var isAudioConfigured = false
    private var audioInput: AVCaptureDeviceInput?
    private var videoDevice: AVCaptureDevice?
    private var lockedExposureDuration: CMTime?
    private var lockedExposureISO: Float?
    // These mirrors are accessed only on sessionQueue. The @Published values
    // above are UI snapshots and are updated on the main queue.
    private var focusLockedValue = false
    private var exposureLockedValue = false
    private var exposureBiasValue = 0.0

    private let exposureBiasRange = -3.0...3.0

    func prepareAudioForRecording(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            configureAudioInput(completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAudioInput(completion: completion)
                } else {
                    DispatchQueue.main.async {
                        self.audioWarning = "麦克风权限未开启，录像将不含声音。"
                        completion(false)
                    }
                }
            }
        case .denied, .restricted:
            audioWarning = "麦克风权限未开启，录像将不含声音。"
            completion(false)
        @unknown default:
            audioWarning = "无法使用麦克风，录像将不含声音。"
            completion(false)
        }
    }

    func stopAudioCapture() {
        sessionQueue.async { [weak self] in
            guard let self, self.isAudioConfigured else { return }
            self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
            self.session.beginConfiguration()
            if self.session.outputs.contains(self.audioOutput) { self.session.removeOutput(self.audioOutput) }
            if let input = self.audioInput { self.session.removeInput(input) }
            self.session.commitConfiguration()
            self.audioInput = nil
            self.isAudioConfigured = false
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStart()
                } else {
                    DispatchQueue.main.async {
                        self.errorMessage = "需要允许相机权限，才能预览鱼眼矫正效果。"
                    }
                }
            }
        case .denied, .restricted:
            errorMessage = "相机权限未开启。请在 iPhone 设置中允许 MaiLens 使用相机。"
        @unknown default:
            errorMessage = "无法确认相机权限状态。"
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    /// Locks the current lens position. The call is made on the capture queue
    /// because AVCaptureDevice configuration is not thread-safe.
    func toggleFocusLock() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let shouldLock = !self.focusLockedValue
                try self.applyFocusLock(shouldLock, to: device)
                self.focusLockedValue = shouldLock
                self.publishFocusExposureState(focusLocked: shouldLock,
                                               exposureLocked: nil,
                                               error: nil)
            } catch {
                self.publishFocusExposureState(focusLocked: nil,
                                               exposureLocked: nil,
                                               error: error.localizedDescription)
            }
        }
    }

    /// Locks the current exposure duration/ISO. While locked, the exposure
    /// slider changes those custom values instead of re-enabling auto exposure.
    func toggleExposureLock() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let shouldLock = !self.exposureLockedValue
                try self.applyExposureLock(shouldLock, to: device)
                self.exposureLockedValue = shouldLock
                self.publishFocusExposureState(focusLocked: nil,
                                               exposureLocked: shouldLock,
                                               error: nil)
            } catch {
                self.publishFocusExposureState(focusLocked: nil,
                                               exposureLocked: nil,
                                               error: error.localizedDescription)
            }
        }
    }

    /// Convenience action used by the primary camera-controls button. If
    /// either control is currently automatic, both are latched together.
    func toggleFocusAndExposureLock() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            let shouldLock = !(self.focusLockedValue && self.exposureLockedValue)
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                try self.applyFocusLock(shouldLock, to: device)
                try self.applyExposureLock(shouldLock, to: device)
                self.focusLockedValue = shouldLock
                self.exposureLockedValue = shouldLock
                self.publishFocusExposureState(focusLocked: shouldLock,
                                               exposureLocked: shouldLock,
                                               error: nil)
            } catch {
                self.publishFocusExposureState(focusLocked: nil,
                                               exposureLocked: nil,
                                               error: error.localizedDescription)
            }
        }
    }

    /// Applies exposure compensation in EV. It works in both modes: while
    /// automatic, it changes the camera's target bias; while locked, it scales
    /// the latched ISO and shutter without giving control back to AE.
    func setExposureBias(_ value: Double) {
        let clamped = min(max(value, exposureBiasRange.lowerBound), exposureBiasRange.upperBound)
        DispatchQueue.main.async { [weak self] in
            self?.exposureBias = clamped
        }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            self.exposureBiasValue = clamped
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if self.exposureLockedValue {
                    try self.applyLockedExposureBias(clamped, to: device)
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.setExposureTargetBias(Float(clamped), completionHandler: nil)
                } else if device.isExposureModeSupported(.autoExpose) {
                    device.setExposureTargetBias(Float(clamped), completionHandler: nil)
                } else {
                    throw CameraControlError.exposureUnsupported
                }
                self.publishFocusExposureState(focusLocked: nil,
                                               exposureLocked: nil,
                                               error: nil)
            } catch {
                self.publishFocusExposureState(focusLocked: nil,
                                               exposureLocked: nil,
                                               error: error.localizedDescription)
            }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.session.isRunning else { return }
            do {
                if !self.isConfigured {
                    try self.configureSession()
                }
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.cameraName = "后置超广角 · 0.5×"
                    self.errorMessage = nil
                }
                // Let auto focus/exposure settle on the live lens before
                // taking the first lock. This keeps the default shot stable
                // without freezing the camera during its warm-up frame.
                self.sessionQueue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, self.session.isRunning,
                          let device = self.videoDevice else { return }
                    self.lockFocusAndExposureOnQueue(device)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isRunning = false
                }
            }
        }
    }

    private func configureAudioInput(completion: @escaping (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.isAudioConfigured {
                DispatchQueue.main.async { completion(true) }
                return
            }
            guard let microphone = AVCaptureDevice.default(for: .audio) else {
                DispatchQueue.main.async {
                    self.audioWarning = "未找到麦克风，录像将不含声音。"
                    completion(false)
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: microphone)
                self.session.beginConfiguration()
                defer { self.session.commitConfiguration() }
                guard self.session.canAddInput(input), self.session.canAddOutput(self.audioOutput) else {
                    DispatchQueue.main.async {
                        self.audioWarning = "无法连接麦克风，录像将不含声音。"
                        completion(false)
                    }
                    return
                }
                self.session.addInput(input)
                self.audioOutput.setSampleBufferDelegate(self, queue: self.audioOutputQueue)
                self.session.addOutput(self.audioOutput)
                self.audioInput = input
                self.isAudioConfigured = true
                DispatchQueue.main.async {
                    self.audioWarning = nil
                    completion(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.audioWarning = "无法启动麦克风：\(error.localizedDescription)"
                    completion(false)
                }
            }
        }
    }

    private func configureSession() throws {
        guard let camera = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) else {
            throw CameraError.ultraWideUnavailable
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw CameraError.cannotAddCamera }
        session.addInput(input)
        videoDevice = camera
        exposureBiasValue = min(max(Double(camera.exposureTargetBias),
                                    exposureBiasRange.lowerBound),
                                exposureBiasRange.upperBound)
        let initialExposureBias = exposureBiasValue
        DispatchQueue.main.async { [weak self] in
            self?.exposureBias = initialExposureBias
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraError.cannotAddVideoOutput }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoStabilizationSupported {
                // The virtual gimbal below owns the full 3D correction. A
                // second AVFoundation crop would fight that matrix and make
                // the locked world direction drift during a quick move.
                connection.preferredVideoStabilizationMode = .off
            }
        }
        isConfigured = true
    }

    private func lockFocusAndExposureOnQueue(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            try applyFocusLock(true, to: device)
            try applyExposureLock(true, to: device)
            focusLockedValue = true
            exposureLockedValue = true
            publishFocusExposureState(focusLocked: true,
                                      exposureLocked: true,
                                      error: nil)
        } catch {
            publishFocusExposureState(focusLocked: nil,
                                      exposureLocked: nil,
                                      error: error.localizedDescription)
        }
    }

    private func applyFocusLock(_ locked: Bool, to device: AVCaptureDevice) throws {
        if locked {
            guard device.isFocusModeSupported(.locked) else {
                throw CameraControlError.focusUnsupported
            }
            device.setFocusModeLocked(lensPosition: device.lensPosition, completionHandler: nil)
            device.isSubjectAreaChangeMonitoringEnabled = false
        } else {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            } else {
                throw CameraControlError.focusUnsupported
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
        }
    }

    private func applyExposureLock(_ locked: Bool, to device: AVCaptureDevice) throws {
        if locked {
            guard device.isExposureModeSupported(.custom)
                    || device.isExposureModeSupported(.locked) else {
                throw CameraControlError.exposureUnsupported
            }
            lockedExposureDuration = device.exposureDuration
            lockedExposureISO = device.iso
            if device.isExposureModeSupported(.custom) {
                try applyLockedExposureBias(exposureBiasValue, to: device)
            } else {
                device.exposureMode = .locked
            }
        } else {
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
                device.setExposureTargetBias(Float(exposureBiasValue), completionHandler: nil)
            } else if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
                device.setExposureTargetBias(Float(exposureBiasValue), completionHandler: nil)
            } else {
                throw CameraControlError.exposureUnsupported
            }
            lockedExposureDuration = nil
            lockedExposureISO = nil
        }
    }

    private func applyLockedExposureBias(_ bias: Double, to device: AVCaptureDevice) throws {
        guard let baseDuration = lockedExposureDuration,
              let baseISO = lockedExposureISO,
              device.isExposureModeSupported(.custom) else {
            if device.isExposureModeSupported(.locked) { return }
            throw CameraControlError.exposureUnsupported
        }

        let baseSeconds = CMTimeGetSeconds(baseDuration)
        guard baseSeconds.isFinite, baseSeconds > 0 else {
            throw CameraControlError.exposureUnsupported
        }

        let format = device.activeFormat
        let minISO = format.minISO
        let maxISO = format.maxISO
        let minSeconds = max(CMTimeGetSeconds(format.minExposureDuration), 0.000001)
        let maxSeconds = max(CMTimeGetSeconds(format.maxExposureDuration), minSeconds)
        let factor = pow(2.0, bias)
        let desiredISO = min(max(baseISO * Float(factor), minISO), maxISO)
        let isoFactor = max(Double(desiredISO / max(baseISO, 0.001)), 0.001)
        let desiredSeconds = min(max(baseSeconds * factor / isoFactor, minSeconds), maxSeconds)
        let duration = CMTimeMakeWithSeconds(desiredSeconds, preferredTimescale: 1_000_000_000)
        device.setExposureModeCustom(duration: duration,
                                     iso: desiredISO,
                                     completionHandler: nil)
    }

    private func publishFocusExposureState(focusLocked: Bool?,
                                           exposureLocked: Bool?,
                                           error: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let focusLocked { self.focusLocked = focusLocked }
            if let exposureLocked { self.exposureLocked = exposureLocked }
            self.focusExposureError = error
        }
    }

    private enum CameraError: LocalizedError {
        case ultraWideUnavailable
        case cannotAddCamera
        case cannotAddVideoOutput

        var errorDescription: String? {
            switch self {
            case .ultraWideUnavailable:
                return "没有找到后置 0.5× 超广角摄像头。请在 iPhone 15 Pro Max 真机上运行。"
            case .cannotAddCamera:
                return "无法连接后置超广角摄像头。"
            case .cannotAddVideoOutput:
                return "无法建立相机视频输出。"
            }
        }
    }

    private enum CameraControlError: LocalizedError {
        case focusUnsupported
        case exposureUnsupported

        var errorDescription: String? {
            switch self {
            case .focusUnsupported:
                return "当前超广角摄像头不支持锁定对焦。"
            case .exposureUnsupported:
                return "当前超广角摄像头不支持锁定曝光或曝光补偿。"
            }
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        } else if output === audioOutput {
            onAudioSample?(sampleBuffer)
        }
    }
}
