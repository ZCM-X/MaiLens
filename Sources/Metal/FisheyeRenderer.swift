import CoreVideo
import Metal
import MetalKit
import SwiftUI

private struct FisheyeUniforms {
    var sourceSize: SIMD2<Float>
    var destinationSize: SIMD2<Float>
    var centerNormalized: SIMD2<Float>
    var cropCenterNormalized: SIMD2<Float>
    var cropZoom: Float
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
    private var settings = LensCorrectionSettings.preliminary
    private var framing = MachineAutoLockFraming.identity

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

    func setFrame(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        latestPixelBuffer = pixelBuffer
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pixelBuffer = currentPixelBuffer(),
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

        let (currentSettings, currentFraming) = currentRenderState()
        let outputSize = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        let sourceSize = SIMD2(Float(width), Float(height))
        // Video is 16:9 while the calibration stills are 4:3. The camera
        // video is center-cropped before its long edge is scaled to this size.
        let seedFocal = Float(max(width, height)) * 772.41 / 4032.0
        let correctionEnabled: Float = currentSettings.correctionEnabled ? 1.0 : 0.0
        let uniforms = FisheyeUniforms(
            sourceSize: sourceSize,
            destinationSize: outputSize,
            centerNormalized: SIMD2(Float(currentSettings.centerX), Float(currentSettings.centerY)),
            cropCenterNormalized: SIMD2(
                Float(currentFraming.isActive ? currentFraming.center.x : 0.5),
                Float(currentFraming.isActive ? currentFraming.center.y : 0.5)
            ),
            cropZoom: Float(currentFraming.isActive ? currentFraming.zoom : 1),
            focalX: seedFocal,
            focalY: seedFocal,
            horizontalFOVRadians: Float(currentSettings.horizontalFOV * .pi / 180.0),
            k1: currentSettings.correctionEnabled ? Float(currentSettings.k1) : 0,
            k2: currentSettings.correctionEnabled ? Float(currentSettings.k2) : 0,
            correctionEnabled: correctionEnabled
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(cameraTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var uniformsCopy = uniforms
        encoder.setFragmentBytes(&uniformsCopy, length: MemoryLayout<FisheyeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func currentPixelBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestPixelBuffer
    }

    private func currentRenderState() -> (LensCorrectionSettings, MachineAutoLockFraming) {
        lock.lock()
        defer { lock.unlock() }
        return (settings, framing)
    }
}

struct FisheyeCameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraController
    @ObservedObject var autoLock: MachineAutoLockController
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

        camera.onFrame = { [weak renderer = context.coordinator.renderer, autoLock] frame in
            renderer?.setFrame(frame)
            autoLock.process(frame)
        }
        autoLock.onFramingUpdate = { [weak renderer = context.coordinator.renderer] framing in
            renderer?.setFraming(framing)
        }
        context.coordinator.camera = camera
        context.coordinator.autoLock = autoLock
        camera.start()
        context.coordinator.renderer.setSettings(settings)
        autoLock.updateSettings(settings)
        autoLock.updatePreviewSize(view.bounds.size)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer.setSettings(settings)
        autoLock.updateSettings(settings)
        autoLock.updatePreviewSize(view.bounds.size)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.camera?.stop()
        coordinator.camera?.onFrame = nil
        coordinator.autoLock?.onFramingUpdate = nil
    }

    final class Coordinator {
        let device: MTLDevice
        let renderer: FisheyeRenderer
        weak var camera: CameraController?
        weak var autoLock: MachineAutoLockController?

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
