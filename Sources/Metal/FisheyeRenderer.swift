import CoreVideo
import CoreMedia
import Metal
import MetalKit
import SwiftUI
import simd

private struct FisheyeUniforms {
    var rotation0: SIMD4<Float>
    var rotation1: SIMD4<Float>
    var rotation2: SIMD4<Float>
    var sourceSize: SIMD2<Float>
    var destinationSize: SIMD2<Float>
    var centerNormalized: SIMD2<Float>
    var cropZoom: Float
    var focalX: Float
    var focalY: Float
    var horizontalFOVRadians: Float
    var k1: Float
    var k2: Float
    var correctionEnabled: Float
    var gimbalActive: Float
}

final class FisheyeRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?
    private let lock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestPresentationTime = CMTime.zero
    private var settings = LensCorrectionSettings.preliminary
    private var gimbal = DigitalGimbalTransform.identity
    private weak var gimbalController: GimbalLockController?
    private var videoRecorder: ProcessedVideoRecorder?

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "fisheyeVertex"),
              let fragment = library.makeFunction(name: "fisheyeFragment") else { return nil }
        commandQueue = queue

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.pipeline = pipeline

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.sampler = sampler

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        super.init()
    }

    func setFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        lock.lock()
        latestPixelBuffer = pixelBuffer
        latestPresentationTime = presentationTime
        lock.unlock()
    }

    func setSettings(_ value: LensCorrectionSettings) {
        lock.lock()
        settings = value
        lock.unlock()
    }

    func setGimbalTransform(_ value: DigitalGimbalTransform) {
        lock.lock()
        gimbal = value
        lock.unlock()
    }

    /// The controller owns the short IMU history. The renderer asks for the
    /// pose matching each camera frame instead of using whichever sensor
    /// callback happened to arrive most recently.
    func setGimbalController(_ value: GimbalLockController?) {
        lock.lock()
        gimbalController = value
        lock.unlock()
    }

    func setVideoRecorder(_ value: ProcessedVideoRecorder?) {
        lock.lock()
        videoRecorder = value
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let (pixelBuffer, presentationTime) = currentFrame(),
              let textureCache,
              let drawable = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let cameraTexture = CVMetalTextureGetTexture(cvTexture) else { return }

        let (currentSettings, fallbackGimbal, controller, recorder) = currentRenderState()
        let currentGimbal = controller?.renderTransform(forFrameAt: presentationTime.seconds)
            ?? fallbackGimbal
        let outputSize = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        let sourceSize = SIMD2(Float(width), Float(height))
        let seedFocal = Float(max(width, height)) * 772.41 / 4032.0
        let uniforms = makeUniforms(
            settings: currentSettings,
            gimbal: currentGimbal,
            sourceSize: sourceSize,
            destinationSize: outputSize,
            focalLength: seedFocal
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(cameraTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var uniformsCopy = uniforms
        encoder.setFragmentBytes(&uniformsCopy, length: MemoryLayout<FisheyeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        var recordingPixelBuffer: CVPixelBuffer?
        var recordingMetalTexture: CVMetalTexture?
        if let recorder,
           let output = recorder.makeFrameBuffer() {
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                output.pixelBuffer,
                nil,
                .bgra8Unorm,
                output.width,
                output.height,
                0,
                &recordingMetalTexture
            )
            if status == kCVReturnSuccess,
               let recordingMetalTexture,
               let targetTexture = CVMetalTextureGetTexture(recordingMetalTexture) {
                let recordPass = MTLRenderPassDescriptor()
                recordPass.colorAttachments[0].texture = targetTexture
                recordPass.colorAttachments[0].loadAction = .clear
                recordPass.colorAttachments[0].storeAction = .store
                recordPass.colorAttachments[0].clearColor = MTLClearColor(red: 0.025, green: 0.035, blue: 0.04, alpha: 1)
                if let recordEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: recordPass) {
                    let recordSize = SIMD2(Float(output.width), Float(output.height))
                    let recordUniforms = makeUniforms(
                        settings: currentSettings,
                        gimbal: currentGimbal,
                        sourceSize: sourceSize,
                        destinationSize: recordSize,
                        focalLength: seedFocal
                    )
                    recordEncoder.setRenderPipelineState(pipeline)
                    recordEncoder.setFragmentTexture(cameraTexture, index: 0)
                    recordEncoder.setFragmentSamplerState(sampler, index: 0)
                    var recordUniformsCopy = recordUniforms
                    recordEncoder.setFragmentBytes(&recordUniformsCopy, length: MemoryLayout<FisheyeUniforms>.stride, index: 0)
                    recordEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                    recordEncoder.endEncoding()
                    recordingPixelBuffer = output.pixelBuffer
                }
            }
        }

        if let recorder, let recordingPixelBuffer, let recordingMetalTexture {
            commandBuffer.addCompletedHandler { [weak recorder, pixelBuffer = recordingPixelBuffer, metalTexture = recordingMetalTexture] buffer in
                guard buffer.status == .completed else { return }
                recorder?.append(pixelBuffer, sourceTime: presentationTime)
                _ = metalTexture
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func currentFrame() -> (CVPixelBuffer, CMTime)? {
        lock.lock()
        defer { lock.unlock() }
        guard let latestPixelBuffer else { return nil }
        return (latestPixelBuffer, latestPresentationTime)
    }

    private func currentRenderState() -> (LensCorrectionSettings, DigitalGimbalTransform, GimbalLockController?, ProcessedVideoRecorder?) {
        lock.lock()
        defer { lock.unlock() }
        return (settings, gimbal, gimbalController, videoRecorder)
    }

    private func makeUniforms(
        settings: LensCorrectionSettings,
        gimbal: DigitalGimbalTransform,
        sourceSize: SIMD2<Float>,
        destinationSize: SIMD2<Float>,
        focalLength: Float
    ) -> FisheyeUniforms {
        let totalZoom = gimbal.gimbalActive ? 1.36 : 1
        let matrix = gimbal.isActive ? gimbal.cameraFromLocked : matrix_identity_float3x3
        let columns = matrix.columns
        return FisheyeUniforms(
            rotation0: SIMD4<Float>(columns.0, 0),
            rotation1: SIMD4<Float>(columns.1, 0),
            rotation2: SIMD4<Float>(columns.2, 0),
            sourceSize: sourceSize,
            destinationSize: destinationSize,
            centerNormalized: SIMD2(Float(settings.centerX), Float(settings.centerY)),
            cropZoom: Float(totalZoom),
            focalX: focalLength,
            focalY: focalLength,
            horizontalFOVRadians: Float(settings.horizontalFOV * .pi / 180.0),
            k1: settings.correctionEnabled ? Float(settings.k1) : 0,
            k2: settings.correctionEnabled ? Float(settings.k2) : 0,
            correctionEnabled: settings.correctionEnabled ? 1 : 0,
            gimbalActive: gimbal.isActive ? 1 : 0
        )
    }
}

struct FisheyeCameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraController
    @ObservedObject var gimbalLock: GimbalLockController
    @ObservedObject var recorder: ProcessedVideoRecorder
    var settings: LensCorrectionSettings

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator.renderer
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 30
        view.clearColor = MTLClearColor(red: 0.025, green: 0.035, blue: 0.04, alpha: 1)
        view.layer.cornerRadius = 22
        view.layer.masksToBounds = true

        camera.onFrame = { [weak renderer = context.coordinator.renderer] frame, presentationTime in
            renderer?.setFrame(frame, presentationTime: presentationTime)
        }
        camera.onAudioSample = { [weak recorder] sampleBuffer in
            recorder?.appendAudioSample(sampleBuffer)
        }
        gimbalLock.onGimbalUpdate = { [weak renderer = context.coordinator.renderer] transform in
            renderer?.setGimbalTransform(transform)
        }
        context.coordinator.camera = camera
        context.coordinator.gimbalLock = gimbalLock
        context.coordinator.recorder = recorder
        context.coordinator.renderer.setVideoRecorder(recorder)
        context.coordinator.renderer.setGimbalController(gimbalLock)
        camera.start()
        gimbalLock.start()
        context.coordinator.renderer.setSettings(settings)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer.setSettings(settings)
        context.coordinator.renderer.setVideoRecorder(recorder)
        context.coordinator.renderer.setGimbalController(gimbalLock)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.camera?.stop()
        if let recorder = coordinator.recorder, recorder.isRecording {
            let camera = coordinator.camera
            recorder.stop { camera?.stopAudioCapture() }
        } else {
            coordinator.camera?.stopAudioCapture()
        }
        coordinator.camera?.onFrame = nil
        coordinator.camera?.onAudioSample = nil
        coordinator.gimbalLock?.onGimbalUpdate = nil
        coordinator.renderer.setGimbalController(nil)
        coordinator.gimbalLock?.stop()
    }

    final class Coordinator {
        let device: MTLDevice
        let renderer: FisheyeRenderer
        weak var camera: CameraController?
        weak var gimbalLock: GimbalLockController?
        weak var recorder: ProcessedVideoRecorder?

        init() {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let renderer = FisheyeRenderer(device: device) else {
                fatalError("MaiLens requires a Metal-capable device.")
            }
            self.device = device
            self.renderer = renderer
        }
    }
}
