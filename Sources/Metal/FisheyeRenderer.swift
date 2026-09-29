import CoreVideo
import CoreMedia
import Metal
import MetalKit
import SwiftUI

private struct FisheyeUniforms {
    var sourceSize: SIMD2<Float>
    var destinationSize: SIMD2<Float>
    var centerNormalized: SIMD2<Float>
    var cropCenterNormalized: SIMD2<Float>
    var cropZoom: Float
    var horizonRadians: Float
    var focalX: Float
    var focalY: Float
    var horizontalFOVRadians: Float
    var k1: Float
    var k2: Float
    var correctionEnabled: Float
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
    private var framing = MachineAutoLockFraming.identity
    private var horizonRadians: CGFloat = 0
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

    func setFraming(_ value: MachineAutoLockFraming) {
        lock.lock()
        framing = value
        lock.unlock()
    }

    func setHorizonAngle(_ value: CGFloat) {
        lock.lock()
        horizonRadians = value
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

        let (currentSettings, currentFraming, currentHorizon, recorder) = currentRenderState()
        let outputSize = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        let sourceSize = SIMD2(Float(width), Float(height))
        let seedFocal = Float(max(width, height)) * 772.41 / 4032.0
        let uniforms = makeUniforms(
            settings: currentSettings,
            framing: currentFraming,
            horizon: currentHorizon,
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
                        framing: currentFraming,
                        horizon: currentHorizon,
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

    private func currentRenderState() -> (LensCorrectionSettings, MachineAutoLockFraming, CGFloat, ProcessedVideoRecorder?) {
        lock.lock()
        defer { lock.unlock() }
        return (settings, framing, horizonRadians, videoRecorder)
    }

    private func makeUniforms(
        settings: LensCorrectionSettings,
        framing: MachineAutoLockFraming,
        horizon: CGFloat,
        sourceSize: SIMD2<Float>,
        destinationSize: SIMD2<Float>,
        focalLength: Float
    ) -> FisheyeUniforms {
        FisheyeUniforms(
            sourceSize: sourceSize,
            destinationSize: destinationSize,
            centerNormalized: SIMD2(Float(settings.centerX), Float(settings.centerY)),
            cropCenterNormalized: SIMD2(
                Float(framing.isActive ? framing.center.x : 0.5),
                Float(framing.isActive ? framing.center.y : 0.5)
            ),
            cropZoom: Float(framing.isActive ? framing.zoom : 1),
            horizonRadians: Float(horizon),
            focalX: focalLength,
            focalY: focalLength,
            horizontalFOVRadians: Float(settings.horizontalFOV * .pi / 180.0),
            k1: settings.correctionEnabled ? Float(settings.k1) : 0,
            k2: settings.correctionEnabled ? Float(settings.k2) : 0,
            correctionEnabled: settings.correctionEnabled ? 1 : 0
        )
    }
}

struct FisheyeCameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraController
    @ObservedObject var autoLock: MachineAutoLockController
    @ObservedObject var horizonLock: HorizonLockController
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

        camera.onFrame = { [weak renderer = context.coordinator.renderer, autoLock] frame, presentationTime in
            renderer?.setFrame(frame, presentationTime: presentationTime)
            autoLock.process(frame)
        }
        camera.onAudioSample = { [weak recorder] sampleBuffer in
            recorder?.appendAudioSample(sampleBuffer)
        }
        autoLock.onFramingUpdate = { [weak renderer = context.coordinator.renderer] framing in
            renderer?.setFraming(framing)
        }
        horizonLock.onAngleUpdate = { [weak renderer = context.coordinator.renderer, autoLock] angle in
            renderer?.setHorizonAngle(angle)
            autoLock.updateHorizonAngle(angle)
        }
        context.coordinator.camera = camera
        context.coordinator.autoLock = autoLock
        context.coordinator.horizonLock = horizonLock
        context.coordinator.recorder = recorder
        context.coordinator.renderer.setVideoRecorder(recorder)
        camera.start()
        horizonLock.start()
        context.coordinator.renderer.setSettings(settings)
        autoLock.updateSettings(settings)
        autoLock.updatePreviewSize(view.bounds.size)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer.setSettings(settings)
        autoLock.updateSettings(settings)
        autoLock.updatePreviewSize(view.bounds.size)
        context.coordinator.renderer.setVideoRecorder(recorder)
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
        coordinator.autoLock?.onFramingUpdate = nil
        coordinator.horizonLock?.stop()
        coordinator.horizonLock?.onAngleUpdate = nil
    }

    final class Coordinator {
        let device: MTLDevice
        let renderer: FisheyeRenderer
        weak var camera: CameraController?
        weak var autoLock: MachineAutoLockController?
        weak var horizonLock: HorizonLockController?
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
