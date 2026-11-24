import AppKit
import MetalKit
import C64Core

/// Displays the VIC-II (40 columns) or VDC (80 columns) picture with Metal, presenting in step
/// with the display's refresh, and forwards keyboard input.
final class EmulatorView: MTKView, MTKViewDelegate {
    var runner: EmulatorRunner?
    var keyMapper: KeyMapper?
    var onFileDrop: ((URL) -> Void)?
    /// Called on the main thread at every display refresh (status updates).
    var onDisplay: (() -> Void)?
    /// Part of the 384×272 VIC-II frame to show (lets the user trim the border).
    var crop = CGRect(x: 0, y: 0, width: VICII.screenWidth, height: VICII.screenHeight) { didSet { needsRedraw = true } }
    /// Set when the picture must be drawn again although no new frame arrived (resize, crop).
    private var needsRedraw = true

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var frameSerial = -1
    private var showing80 = false

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vmain(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 t = float2(vid & 1, vid >> 1);
        VOut o;
        o.pos = float4(t.x * 2 - 1, 1 - t.y * 2, 0, 1);
        o.uv = rect.xy + t * rect.zw;
        return o;
    }
    fragment float4 fmain(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        return float4(tex.sample(s, in.uv).rgb, 1);
    }
    """

    override init(frame: NSRect, device: MTLDevice?) {
        guard let device = device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { fatalError("Metal is not available") }
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: EmulatorView.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vmain")
            desc.fragmentFunction = library.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("Metal pipeline: \(error)")
        }
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        framebufferOnly = true
        // Draw in step with the display at 60 Hz (the C64's rate); a frame is uploaded only when new.
        preferredFramesPerSecond = 60
        isPaused = false
        enableSetNeedsDisplay = false
        delegate = self
        registerForDraggedTypes([.fileURL])
    }

    convenience init(frame: NSRect) { self.init(frame: frame, device: nil) }

    required init(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: Rendering

    /// Copies the runner's latest picture into the texture if it changed since the last upload.
    /// Returns true if a new picture was uploaded.
    @discardableResult
    private func uploadFrame() -> Bool {
        guard let runner = runner, let device = device else { return false }
        var uploaded = false
        runner.withFrame(newerThan: &frameSerial) { bytes, w, h, eighty in
            showing80 = eighty
            if texture?.width != w || texture?.height != h {
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                    width: w, height: h, mipmapped: false)
                desc.usage = .shaderRead
                texture = device.makeTexture(descriptor: desc)
            }
            guard let base = bytes.baseAddress, bytes.count >= w * h * 4 else { return }
            texture?.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                             withBytes: base, bytesPerRow: w * 4)
            uploaded = true
        }
        return uploaded
    }

    func draw(in view: MTKView) {
        onDisplay?()
        // Nothing new: leave the last presented picture on screen instead of drawing it again.
        guard uploadFrame() || needsRedraw else { return }
        needsRedraw = false
        guard let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let texture {
            // The VDC picture has no border to trim.
            let r = showing80 ? CGRect(x: 0, y: 0, width: texture.width, height: texture.height) : crop
            var rect = SIMD4<Float>(Float(r.minX) / Float(texture.width), Float(r.minY) / Float(texture.height),
                                    Float(r.width) / Float(texture.width), Float(r.height) / Float(texture.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsRedraw = true }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        if keyMapper?.keyDown(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) { keyMapper?.keyUp(event) }
    override func flagsChanged(with event: NSEvent) { keyMapper?.flagsChanged(event) }

    // MARK: Drag & drop media

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL else { return false }
        onFileDrop?(url)
        return true
    }
}
