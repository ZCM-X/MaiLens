import AVFoundation
import AudioToolbox
import Combine
import CoreVideo
import Foundation

/// Writes frames after lens correction and virtual-gimbal locking.
final class ProcessedVideoRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var savedURL: URL?
    @Published private(set) var errorMessage: String?

    private let writerQueue = DispatchQueue(label: "com.mailens.processed-video-writer", qos: .userInitiated)
    private let stateLock = NSLock()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelBufferPool: CVPixelBufferPool?
    private var acceptingFrames = false
    private var videoWidth = 1080
    private var videoHeight = 1920
    private var firstSourceTime: CMTime?
    private var lastWrittenTime: CMTime?

    func start(
        width requestedWidth: Int = 1080,
        height requestedHeight: Int = 1920,
        includeAudio: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let alreadyWriting = self.writer != nil
            self.stateLock.unlock()
            guard !alreadyWriting else {
                DispatchQueue.main.async { completion?(true) }
                return
            }
            do {
                let width = max(requestedWidth / 2 * 2, 2)
                let height = max(requestedHeight / 2 * 2, 2)
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("MaiLens Recordings", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let url = directory.appendingPathComponent("MaiLens-\(formatter.string(from: Date())).mp4")
                try? FileManager.default.removeItem(at: url)

                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: 12_000_000,
                        AVVideoExpectedSourceFrameRateKey: 30,
                        AVVideoMaxKeyFrameIntervalKey: 60
                    ]
                ])
                input.expectsMediaDataInRealTime = true
                var audioInput: AVAssetWriterInput?
                if includeAudio {
                    let track = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 44_100,
                        AVNumberOfChannelsKey: 2,
                        AVEncoderBitRateKey: 128_000
                    ])
                    track.expectsMediaDataInRealTime = true
                    guard writer.canAdd(track) else { throw RecorderError.cannotAddAudioTrack }
                    writer.add(track)
                    audioInput = track
                }
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ])

                guard writer.canAdd(input) else { throw RecorderError.cannotAddVideoTrack }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? RecorderError.cannotStartWriter }
                writer.startSession(atSourceTime: .zero)

                self.stateLock.lock()
                self.writer = writer
                self.videoInput = input
                self.audioInput = audioInput
                self.adaptor = adaptor
                self.pixelBufferPool = adaptor.pixelBufferPool
                self.videoWidth = width
                self.videoHeight = height
                self.acceptingFrames = true
                self.firstSourceTime = nil
                self.lastWrittenTime = nil
                self.stateLock.unlock()

                DispatchQueue.main.async {
                    self.savedURL = nil
                    self.errorMessage = nil
                    self.isFinishing = false
                    self.isRecording = true
                    completion?(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "无法开始录像：\(error.localizedDescription)"
                    completion?(false)
                }
            }
        }
    }

    func makeFrameBuffer() -> (pixelBuffer: CVPixelBuffer, width: Int, height: Int)? {
        stateLock.lock()
        let pool = pixelBufferPool
        let width = videoWidth
        let height = videoHeight
        let shouldAccept = acceptingFrames
        stateLock.unlock()

        guard shouldAccept, let pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        return (pixelBuffer, width, height)
    }

    func append(_ pixelBuffer: CVPixelBuffer, sourceTime: CMTime) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let writer = self.writer
            let input = self.videoInput
            let adaptor = self.adaptor
            let accepting = self.acceptingFrames
            self.stateLock.unlock()

            guard accepting, writer?.status == .writing,
                  let input, let adaptor, input.isReadyForMoreMediaData else { return }
            let validSourceTime = sourceTime.isValid && sourceTime.isNumeric
                ? sourceTime
                : CMTime(value: CMTimeValue(self.lastWrittenTime.map { $0.value + 1 } ?? 0), timescale: 30)
            if self.firstSourceTime == nil { self.firstSourceTime = validSourceTime }
            let outputTime = CMTimeSubtract(validSourceTime, self.firstSourceTime ?? validSourceTime)
            if let lastWrittenTime = self.lastWrittenTime, CMTimeCompare(outputTime, lastWrittenTime) <= 0 { return }
            guard adaptor.append(pixelBuffer, withPresentationTime: outputTime) else {
                DispatchQueue.main.async { self.errorMessage = "录像写入遇到问题，请结束当前录像后重试。" }
                return
            }
            self.lastWrittenTime = outputTime
        }
    }

    func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let writer = self.writer
            let input = self.audioInput
            let accepting = self.acceptingFrames
            self.stateLock.unlock()

            guard accepting, writer?.status == .writing,
                  let input, input.isReadyForMoreMediaData,
                  let firstSourceTime = self.firstSourceTime else { return }

            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
            guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr,
                  timing.presentationTimeStamp.isValid,
                  timing.presentationTimeStamp.isNumeric,
                  CMTimeCompare(timing.presentationTimeStamp, firstSourceTime) >= 0 else { return }
            timing.presentationTimeStamp = CMTimeSubtract(timing.presentationTimeStamp, firstSourceTime)
            if timing.decodeTimeStamp.isValid && timing.decodeTimeStamp.isNumeric {
                timing.decodeTimeStamp = CMTimeSubtract(timing.decodeTimeStamp, firstSourceTime)
            }

            var adjustedSample: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleBufferOut: &adjustedSample
            ) == noErr, let adjustedSample else { return }
            _ = input.append(adjustedSample)
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        stateLock.lock()
        guard writer != nil, acceptingFrames else {
            stateLock.unlock()
            return
        }
        acceptingFrames = false
        stateLock.unlock()
        DispatchQueue.main.async { self.isFinishing = true }

        writerQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let writer = self.writer
            let input = self.videoInput
            let audioInput = self.audioInput
            let url = writer?.outputURL
            self.stateLock.unlock()
            guard let writer, let input else { return }
            input.markAsFinished()
            audioInput?.markAsFinished()
            writer.finishWriting {
                let completed = writer.status == .completed
                self.stateLock.lock()
                self.writer = nil
                self.videoInput = nil
                self.audioInput = nil
                self.adaptor = nil
                self.pixelBufferPool = nil
                self.firstSourceTime = nil
                self.lastWrittenTime = nil
                self.stateLock.unlock()

                DispatchQueue.main.async {
                    self.isRecording = false
                    self.isFinishing = false
                    if completed {
                        self.savedURL = url
                    } else {
                        self.errorMessage = "录像未能保存：\(writer.error?.localizedDescription ?? "未知错误")"
                    }
                    completion?()
                }
            }
        }
    }

    private enum RecorderError: LocalizedError {
        case cannotAddVideoTrack
        case cannotAddAudioTrack
        case cannotStartWriter

        var errorDescription: String? {
            switch self {
            case .cannotAddVideoTrack: return "无法创建视频轨道。"
            case .cannotAddAudioTrack: return "无法创建音频轨道。"
            case .cannotStartWriter: return "无法启动视频编码器。"
            }
        }
    }
}
