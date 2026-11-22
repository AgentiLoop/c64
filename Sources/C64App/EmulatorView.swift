import AppKit
import C64Core

/// Displays the VIC-II frame buffer and forwards keyboard input.
final class EmulatorView: NSView {
    var runner: EmulatorRunner?
    var keyMapper: KeyMapper?
    var onFileDrop: ((URL) -> Void)?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    /// Part of the 384×272 VIC-II frame to show (lets the user trim the border).
    var crop = CGRect(x: 0, y: 0, width: VICII.screenWidth, height: VICII.screenHeight)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.magnificationFilter = .nearest
        // Fill the whole view: the window keeps the C64's (slightly narrow) pixel aspect.
        layer?.contentsGravity = .resize
        layer?.backgroundColor = NSColor.black.cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    func refresh() {
        guard let runner = runner else { return }
        let w = VICII.screenWidth, h = VICII.screenHeight
        let image: CGImage? = runner.withFrame { pixels in
            let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
            guard let provider = CGDataProvider(data: data) else { return nil }
            return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                           space: colorSpace,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        layer?.contents = image?.cropping(to: crop)
    }

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
