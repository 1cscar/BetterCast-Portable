// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Metal
import QuartzCore

/// A second real stimulus with observable presentation timestamps. Each frame
/// redraws the entire drawable and contains a moving pattern and a serial marker.
@MainActor
final class MetalMotionView: NSView {
    // The render queue only acquires drawables. The main queue updates size
    // while holding drawableSlot, before dispatching the next acquisition.
    private struct DrawableSource: @unchecked Sendable {
        let layer: CAMetalLayer
        func nextDrawable() -> CAMetalDrawable? { layer.nextDrawable() }
    }

    private let metalLayer = CAMetalLayer()
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let scale: CGFloat
    private let trace: SessionTrace?
    private var serial: UInt32 = 0
    private let renderQueue = DispatchQueue(label: "org.bettercast.portable.test-motion")
    private let drawableSlot = DispatchSemaphore(value: 1)

    init(frame: NSRect, scale: CGFloat, trace: SessionTrace?) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CocoaError(.featureUnsupported)
        }
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.queue = queue
        self.scale = scale
        self.trace = trace
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.contentsScale = scale
        metalLayer.displaySyncEnabled = true
        layer = metalLayer
    }

    required init?(coder: NSCoder) { nil }

    func advance() {
        guard drawableSlot.wait(timeout: .now()) == .success else {
            trace?.record("metal_render_busy")
            return
        }
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        serial += 1
        let frameNumber = serial
        let source = DrawableSource(layer: metalLayer)

        // nextDrawable can wait for the compositor. Keep that wait off the
        // main queue, which also delivers encrypted transport completions.
        renderQueue.async { [source, queue, pipeline, trace, drawableSlot] in
            defer { drawableSlot.signal() }
            let begin = DispatchTime.now().uptimeNanoseconds
            guard let drawable = source.nextDrawable(), let commands = queue.makeCommandBuffer() else {
                trace?.record("metal_no_drawable")
                return
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
            var frame = frameNumber
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<UInt32>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            drawable.addPresentedHandler { [trace] frame in
                if frame.presentedTime > 0 {
                    trace?.record("metal_presented", 0, Int(frameNumber), at: UInt64(frame.presentedTime * 1e9))
                } else {
                    trace?.record("metal_not_presented", 0, Int(frameNumber))
                }
            }
            commands.present(drawable)
            commands.commit()
            let end = DispatchTime.now().uptimeNanoseconds
            trace?.record("motion", 0, Int(frameNumber), at: end)
            trace?.record("draw_duration", 0, Int(end - begin), at: end)
        }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    vertex float4 vertexMain(uint id [[vertex_id]]) {
        const float2 positions[] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
        return float4(positions[id], 0, 1);
    }
    fragment float4 fragmentMain(float4 p [[position]], constant uint &serial [[buffer(0)]]) {
        float phase = float((serial * 17u) % 360u) / 360.0;
        float3 hue = abs(fract(phase + float3(0, 0.667, 0.333)) * 6.0 - 3.0);
        float3 color = (0.12 + clamp(hue - 1.0, 0.0, 1.0) * 0.73);
        if ((uint(p.x + p.y) / 32u + serial) % 8u == 0u) color = 1.0 - color;
        if (p.y < 48 && p.x < 384) {
            uint bit = (serial >> (uint(p.x) / 24u)) & 1u;
            color = float3(bit ? 1.0 : 0.0);
        }
        return float4(color, 1);
    }
    """
}
