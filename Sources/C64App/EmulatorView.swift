import AppKit
import MetalKit
import C64Core

/// Displays the VIC-II (40 columns) or VDC (80 columns) picture with Metal, presenting in step
/// with the display's refresh, and forwards keyboard input.
final class EmulatorView: MTKView, MTKViewDelegate {
    var runner: EmulatorRunner?
    var keyMapper: KeyMapper?
    var onFileDrop: ((URL) -> Void)?
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
        // Drawn on demand: the runner asks for a draw when it publishes a new picture, and the layer
        // presents it at the next display refresh. An unchanged screen costs nothing.
        isPaused = true
        enableSetNeedsDisplay = true
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
    override func flagsChanged(with event: NSEvent) {
        if mouseCaptured && event.modifierFlags.contains(.command) { releaseMouse() }   // ⌘ gives the pointer back
        keyMapper?.flagsChanged(event)
    }

    // MARK: 1351 mouse

    /// The 1351 mouse in port 1 follows the Mac mouse/trackpad. A click captures the pointer (hidden,
    /// held in place so movement never stops at a screen edge); ⌘ or leaving the window releases it.
    var mouseEnabled = false { didSet { if !mouseEnabled { releaseMouse() } } }
    /// Mouse counts per point of pointer movement.
    var mouseSpeed: Double = 0.5
    private(set) var mouseCaptured = false
    /// Sub-count movement carried over to the next event, so slow movement is not lost.
    private var mouseRemainder = (x: 0.0, y: 0.0)

    private func captureMouse() {
        guard !mouseCaptured, let window else { return }
        mouseCaptured = true
        mouseRemainder = (0, 0)
        window.acceptsMouseMovedEvents = true
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    func releaseMouse() {
        guard mouseCaptured else { return }
        mouseCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        runner?.perform { $0.mouseLeft = false; $0.mouseRight = false }
    }

    private func moveMouse(_ event: NSEvent) {
        guard mouseCaptured else { return }
        mouseRemainder.x += Double(event.deltaX) * mouseSpeed
        mouseRemainder.y -= Double(event.deltaY) * mouseSpeed          // AppKit deltaY is positive downward
        let dx = Int(mouseRemainder.x.rounded(.towardZero)), dy = Int(mouseRemainder.y.rounded(.towardZero))
        guard dx != 0 || dy != 0 else { return }
        mouseRemainder.x -= Double(dx); mouseRemainder.y -= Double(dy)
        runner?.perform { $0.moveMouse(dx: dx, dy: dy) }
    }

    private func setButton(right: Bool, _ down: Bool) {
        runner?.perform { if right { $0.mouseRight = down } else { $0.mouseLeft = down } }
    }

    override func mouseDown(with event: NSEvent) {
        guard mouseEnabled else { return super.mouseDown(with: event) }
        if !mouseCaptured { captureMouse(); return }                    // the capturing click is not a C64 click
        setButton(right: false, true)
    }
    override func mouseUp(with event: NSEvent) {
        guard mouseCaptured else { return super.mouseUp(with: event) }
        setButton(right: false, false)
    }
    override func rightMouseDown(with event: NSEvent) {
        guard mouseCaptured else { return super.rightMouseDown(with: event) }
        setButton(right: true, true)
    }
    override func rightMouseUp(with event: NSEvent) {
        guard mouseCaptured else { return super.rightMouseUp(with: event) }
        setButton(right: true, false)
    }
    override func mouseMoved(with event: NSEvent) { moveMouse(event) }
    override func mouseDragged(with event: NSEvent) { moveMouse(event) }
    override func rightMouseDragged(with event: NSEvent) { moveMouse(event) }

    // MARK: Scrolling → cursor keys

    /// Scroll wheel and two-finger trackpad scrolling become CRSR key taps (up/down, left/right),
    /// one per notch or per `scrollStep` points of a trackpad swipe, sent one after another.
    private var scrollRemainder = (x: 0.0, y: 0.0)
    private var pendingTaps: [(key: C64Key, shift: Bool)] = []
    private var tapping = false

    override func scrollWheel(with event: NSEvent) {
        guard mouseEnabled else { return super.scrollWheel(with: event) }
        if event.phase == .began || event.phase == .mayBegin { scrollRemainder = (0, 0) }
        let step = event.hasPreciseScrollingDeltas ? 16.0 : 1.0
        scrollRemainder.x += Double(event.scrollingDeltaX)
        scrollRemainder.y += Double(event.scrollingDeltaY)
        // Positive deltas scroll toward the top/left of a document (the user's scroll direction applied).
        while scrollRemainder.y >= step { scrollRemainder.y -= step; queueTap(.cursorDown, shift: true) }
        while scrollRemainder.y <= -step { scrollRemainder.y += step; queueTap(.cursorDown, shift: false) }
        while scrollRemainder.x >= step { scrollRemainder.x -= step; queueTap(.cursorRight, shift: true) }
        while scrollRemainder.x <= -step { scrollRemainder.x += step; queueTap(.cursorRight, shift: false) }
    }

    private func queueTap(_ key: C64Key, shift: Bool) {
        guard pendingTaps.count < 8 else { return }                     // momentum must not pile up
        pendingTaps.append((key, shift))
        if !tapping { nextTap() }
    }

    /// Holds each key for 40 ms (two or three frames, long enough for a keyboard scan) with a 30 ms gap.
    private func nextTap() {
        guard !pendingTaps.isEmpty, let runner else { tapping = false; return }
        tapping = true
        let tap = pendingTaps.removeFirst()
        runner.perform { if tap.shift { $0.setKey(.rightShift, pressed: true) }; $0.setKey(tap.key, pressed: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            runner.perform { $0.setKey(tap.key, pressed: false); if tap.shift { $0.setKey(.rightShift, pressed: false) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self?.nextTap() }
        }
    }

    // MARK: Drag & drop media

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL else { return false }
        onFileDrop?(url)
        return true
    }
}
