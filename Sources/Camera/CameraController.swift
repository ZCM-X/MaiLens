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
                // Let AVFoundation remove high-frequency sensor shake before
                // the Metal crop applies the larger virtual-gimbal movement.
                // Turning this off makes the preview visibly smear during a
                // quick hand movement, especially behind an external fisheye.
                connection.preferredVideoStabilizationMode = .standard
            }
        }
        isConfigured = true
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
