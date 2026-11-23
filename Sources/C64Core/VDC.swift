import Foundation

/// The 8563 VDC picture (C128 80-column screen): text mode with attributes, the alternate character
/// set, underline, reverse and the blinking cursor, plus bitmap mode. Rendered once per frame from
/// the VDC's own 64K RAM; the 8x8 character cells give a 640x200 picture.
extension C64 {
    public static let vdcWidth = 640
    public static let vdcHeight = 200

    /// RGBI colours of the 8563, 0xAARRGGBB.
    static let rgbi: [UInt32] = [0xFF000000, 0xFF555555, 0xFF0000AA, 0xFF5555FF, 0xFF00AA00, 0xFF55FF55,
                                 0xFF00AAAA, 0xFF55FFFF, 0xFFAA0000, 0xFFFF5555, 0xFFAA00AA, 0xFFFF55FF,
                                 0xFFAA5500, 0xFFFFFF55, 0xFFAAAAAA, 0xFFFFFFFF]

    /// True while the C128 KERNAL's active screen is the 80-column one (40/80 key at reset, ESC X).
    public var showing80Columns: Bool { c128 != nil && ram[0xD7] & 0x80 != 0 }

    /// The 40/80 DISPLAY key: down makes the C128 start in 80 columns (read at reset).
    public var key4080Down: Bool {
        get { c128?.key4080Down ?? false }
        set { c128?.key4080Down = newValue }
    }

    /// Size of the last picture drawn by `renderVDC` (640x200 with the KERNAL's settings).
    public var vdcPictureSize: (width: Int, height: Int) {
        (c128?.vdcPictureWidth ?? C64.vdcWidth, c128?.vdcPictureHeight ?? C64.vdcHeight)
    }

    /// Draws the VDC screen into `buffer` (`vdcPictureSize`, 0xAARRGGBB). Follows the character
    /// geometry registers: cell width/displayed width (R22), character height (R9, up to 32 lines;
    /// fonts use 32 bytes per character above 16 lines), displayed lines (R23), and the smooth
    /// scroll registers (R24 bits 0-4 vertical, R25 bits 0-3 horizontal; a value of cell width - 1
    /// means no horizontal shift, as the KERNAL sets it).
    public func renderVDC(into buffer: inout [UInt32]) {
        guard let m = c128 else { return }
        let r = m.vdcRegs, ram = m.vdcRAM
        let cols = min(Int(r[1]), 80), rows = min(Int(r[6]), 72)
        let cellW = max(1, min(Int(r[22] >> 4) + 1, 16))
        let shownW = max(1, min(Int(r[22] & 0x0F), 8))
        let cellH = Int(r[9] & 0x1F) + 1
        let shownH = min(Int(r[23] & 0x1F) + 1, cellH)
        let bytesPerChar = cellH > 16 ? 32 : 16
        var w = min(cols * cellW, 1024), h = min(rows * cellH, 600)
        if w == 0 || h == 0 { w = C64.vdcWidth; h = C64.vdcHeight }
        m.vdcPictureWidth = w; m.vdcPictureHeight = h
        if buffer.count != w * h { buffer = [UInt32](repeating: 0xFF000000, count: w * h) }
        let fg0 = Int(r[26] >> 4), bg = Int(r[26] & 0x0F)
        let attrsOn = r[25] & 0x40 != 0, bitmap = r[25] & 0x80 != 0, rvsAll = r[24] & 0x40 != 0
        let screen = Int(r[12]) << 8 | Int(r[13])
        let attrs = Int(r[20]) << 8 | Int(r[21])
        let charset = Int(r[28] & 0xE0) << 8
        let underline = Int(r[29] & 0x1F)
        let blinkOn = (vic.frameCount / 16) & 1 == 0
        let cursor = Int(r[14]) << 8 | Int(r[15])
        let cursorMode = (r[10] >> 5) & 3                        // 0 solid, 1 none, 2/3 blinking
        let cursorShown = cursorMode == 0 || (cursorMode >= 2 && (vic.frameCount / (cursorMode == 2 ? 8 : 16)) & 1 == 0)
        let cStart = Int(r[10] & 0x1F), cEnd = Int(r[11] & 0x1F)
        let vScroll = Int(r[24] & 0x1F)
        let xShift = (cellW - 1) - Int(r[25] & 0x0F)            // > 0 moves the picture left
        let bgColor = C64.rgbi[bg]
        for i in 0..<buffer.count { buffer[i] = bgColor }
        guard cols > 0 else { return }
        for y in 0..<h {
            let sy = y + vScroll
            let row = sy / cellH, line = sy % cellH
            guard row <= rows, line < shownH || rvsAll else { continue }   // row == rows: next row scrolling in
            let lineBase = y * w
            for col in 0...cols {                                // one extra column scrolls in from the right
                let x0 = col * cellW - xShift
                if x0 >= w || x0 + cellW <= 0 { continue }
                let cell = row * cols + col
                let a: UInt8 = attrsOn ? ram[(attrs + cell) & 0xFFFF] : UInt8(fg0)
                var bits: UInt8 = 0
                if line < shownH {
                    if bitmap {
                        bits = ram[(screen + (row * cellH + line) * cols + col) & 0xFFFF]
                    } else {
                        let code = Int(ram[(screen + cell) & 0xFFFF]) | (attrsOn && a & 0x80 != 0 ? 0x100 : 0)
                        bits = ram[(charset + code * bytesPerChar + line) & 0xFFFF]
                        if attrsOn && a & 0x20 != 0 && line == underline { bits = 0xFF }
                        if attrsOn && a & 0x10 != 0 && !blinkOn { bits = 0 }
                        if attrsOn && a & 0x40 != 0 { bits = ~bits }
                        if cursorShown && cursor == (screen + cell) & 0xFFFF && line >= cStart && line <= cEnd { bits = ~bits }
                    }
                }
                if rvsAll { bits = ~bits }
                guard bits != 0 else { continue }
                let color = C64.rgbi[Int(a & 0x0F)]
                for x in 0..<shownW where bits & (0x80 >> x) != 0 {
                    let px = x0 + x
                    if px >= 0 && px < w { buffer[lineBase + px] = color }
                }
            }
        }
    }

    /// The 80-column text screen as ASCII lines (for tests and debugging).
    public func vdcText() -> [String] {
        guard let m = c128 else { return [] }
        let r = m.vdcRegs
        let cols = max(1, min(Int(r[1]), 80)), screen = Int(r[12]) << 8 | Int(r[13])
        return (0..<min(Int(r[6]), 25)).map { row in
            String((0..<cols).map { col -> Character in
                let c = m.vdcRAM[(screen + row * cols + col) & 0xFFFF] & 0x7F
                switch c {
                case 0: return "@"
                case 1...26: return Character(UnicodeScalar(c + 64))
                case 32...63: return Character(UnicodeScalar(c))
                default: return " "
                }
            })
        }
    }
}
