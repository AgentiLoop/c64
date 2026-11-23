import Foundation

/// The MOS 8563 VDC (C128 80-column video). It runs on its own 16 MHz dot clock in step with the
/// CPU and draws each raster line as the beam reaches it, so register changes take effect on the
/// line they happen, the way programs rely on.
///
/// Behaviour follows VICE's vdc.c / vdc-mem.c / vdc-draw.c:
/// - geometry from the registers: R0 total characters per line, R1 displayed characters, R4 total
///   rows, R5 vertical fine adjust, R6 displayed rows, R9 lines per character row, R22 character
///   width (double-pixel mode R25 bit 4: R22 high nibble pixels of 2 dots, otherwise high nibble + 1
///   dots) and displayed pixels, R23 displayed character lines, R24/R25 smooth scroll;
/// - text mode with attributes (alternate set, reverse, underline, blink, RGBI colour), cursor
///   (R10/R11/R14/R15), screen reverse (R24 bit 6), semigraphics (R25 bit 5);
/// - bitmap mode (R25 bit 7) from the display start address (R12/R13), coloured by attributes (high
///   nibble background, low foreground) or R26;
/// - display enable begin/end (R34/R35): the picture is blanked while R34 lies past R0;
/// - the address increment per row (R27), character set address and 16K/64K addressing (R28);
/// - interlace sync and video (R8 = 3): fields alternate and fill the odd/even picture lines;
/// - the status register: busy after memory accesses and block copy/fill (R30), with VICE's timings,
///   and the vertical blank flag while the beam is outside the displayed rows.
///
/// RAM: 64 KB (4464 chips, as in the C128DCR). In 16K addressing mode (R28 bit 4 = 0) addresses are
/// mapped onto the 64K chips the way the real wiring does.
public final class VDC8563 {
    public static let dotClock = 16_000_000

    public var regs = [UInt8](repeating: 0, count: 64)
    public var ram = [UInt8](repeating: 0, count: 0x10000)
    var select: UInt8 = 0
    /// CPU clock, for converting CPU cycles to VDC dots.
    var clockHz = C64.palClock

    // Beam.
    var dotAcc = 0
    var rowCounter = 0           // character row of the beam
    var rowLine = 0              // line within the character row
    var inFineAdjust = false
    var displayLine = 0          // index of the displayed line being drawn
    public private(set) var frameCount = 0
    var field = 0
    var displayEnable = true

    // Address counters (latched at the start of each frame).
    var screenRowAddr = 0
    var attrRowAddr = 0
    var screenStart = 0          // R12/R13 as latched; bitmap data is read from screenStart + bitmapAddr
    var bitmapAddr = 0

    // Status.
    var busyUntil: UInt64 = 0
    var now: UInt64 = 0

    // Picture: the frame being drawn and the last completed one.
    var drawBuffer: [UInt32] = []
    public private(set) var picture: [UInt32] = [UInt32](repeating: 0xFF000000, count: 640 * 200)
    public private(set) var pictureWidth = 640
    public private(set) var pictureHeight = 200
    /// Advances only when a complete picture (both fields in interlace) is ready.
    public private(set) var pictureCount: UInt64 = 0
    var drawWidth = 640, drawHeight = 200

    /// RGBI colours of the 8563, 0xAARRGGBB.
    public static let rgbi: [UInt32] = [0xFF000000, 0xFF555555, 0xFF0000AA, 0xFF5555FF, 0xFF00AA00, 0xFF55FF55,
                                        0xFF00AAAA, 0xFF55FFFF, 0xFFAA0000, 0xFFFF5555, 0xFFAA00AA, 0xFFFF55FF,
                                        0xFFAA5500, 0xFFFFFF55, 0xFFAAAAAA, 0xFFFFFFFF]

    public init() { reset() }

    public func reset() {
        regs = [UInt8](repeating: 0, count: 64)
        // Power-on values VICE uses (the KERNAL programs all of them anyway).
        regs[0] = 126; regs[1] = 80; regs[4] = 38; regs[6] = 25; regs[9] = 7; regs[22] = 0x78; regs[23] = 8
        regs[25] = 0x47; regs[26] = 0xF0; regs[28] = 0x20; regs[34] = 0x7D; regs[35] = 0x64
        select = 0
        dotAcc = 0; rowCounter = 0; rowLine = 0; inFineAdjust = false; displayLine = 0
        busyUntil = 0
        startFrame()
    }

    // MARK: - Memory (with 16K/64K addressing)

    /// Physical RAM index of a VDC address (R28 bit 4 = 64K addressing).
    @inline(__always) func phys(_ address: Int) -> Int {
        let a = address & 0xFFFF
        if regs[28] & 0x10 != 0 { return a }
        // 16K addressing on 4464 (64K) chips: VICE vdc_16k_to_64k_map.
        return (a & 0x80FF) | ((a & 0x3F00) << 1) | (a & 0x0100)
    }

    @inline(__always) public func peek(_ address: Int) -> UInt8 { ram[phys(address)] }
    @inline(__always) public func poke(_ address: Int, _ value: UInt8) { ram[phys(address)] = value }

    var updateAddress: Int {
        get { Int(regs[18]) << 8 | Int(regs[19]) }
        set { regs[18] = UInt8((newValue >> 8) & 0xFF); regs[19] = UInt8(newValue & 0xFF) }
    }

    // MARK: - CPU interface ($D600 / $D601)

    public func read(_ address: Int) -> UInt8 {
        if address & 1 == 0 {
            var v: UInt8 = 0x02                                    // revision 2 (8563 R2)
            if now >= busyUntil { v |= 0x80 }
            if !displayEnable { v |= 0x20 }                         // beam outside the displayed rows
            return v
        }
        let r = Int(select & 0x3F)
        switch r {
        case 31:
            let v = peek(updateAddress)
            updateAddress = (updateAddress + 1) & 0xFFFF
            busyUntil = now + (displayEnable ? 43 : 4)
            return v
        case 16, 17: return regs[r]                                // light pen (no pen attached)
        case 37...63: return 0xFF
        default: return regs[r]
        }
    }

    public func write(_ address: Int, _ value: UInt8) {
        if address & 1 == 0 { select = value; return }
        let r = Int(select & 0x3F)
        guard r < 37 else { return }
        if r == 16 || r == 17 { return }                            // light pen registers are read-only
        regs[r] = value
        switch r {
        case 18, 19:
            busyUntil = now + (displayEnable ? 43 : 4)
        case 31:
            poke(updateAddress, value)
            updateAddress = (updateAddress + 1) & 0xFFFF
            busyUntil = now + (displayEnable ? 43 : 4)
        case 30:                                                     // block copy (R24 bit 7) or fill
            let count = value == 0 ? 256 : Int(value)
            var src = Int(regs[32]) << 8 | Int(regs[33])
            let copy = regs[24] & 0x80 != 0
            var dst = updateAddress
            for _ in 0..<count {
                if copy {
                    regs[31] = peek(src)
                    poke(dst, regs[31])
                    src = (src + 1) & 0xFFFF
                } else {
                    poke(dst, regs[31])
                }
                dst = (dst + 1) & 0xFFFF
            }
            updateAddress = dst
            if copy { regs[32] = UInt8(src >> 8); regs[33] = UInt8(src & 0xFF) }
            busyUntil = now + UInt64(copy ? count * 120 / 100 : count * 66 / 100)
        default:
            break
        }
    }

    // MARK: - Geometry

    var doublePixel: Bool { regs[25] & 0x10 != 0 }
    var interlaced: Bool { regs[8] & 0x03 == 3 }
    /// Dots per character cell.
    var charDots: Int { doublePixel ? max(1, 2 * Int(regs[22] >> 4)) : Int(regs[22] >> 4) + 1 }
    var lineDots: Int { (Int(regs[0]) + 1) * charDots }
    var linesPerRow: Int { Int(regs[9] & 0x1F) + 1 }

    // MARK: - Beam

    /// Advances the VDC by one CPU cycle (`cycle` = the machine's cycle counter).
    @inline(__always) func tick(cycle: UInt64) {
        now = cycle
        dotAcc += VDC8563.dotClock
        let threshold = lineDots * clockHz
        if dotAcc >= threshold {
            dotAcc -= threshold
            endOfLine()
        }
    }

    private func startFrame() {
        // Picture size from the registers at the start of the frame.
        let w = min(max(Int(regs[1]), 1) * charDots, 2048)
        let h = min(max(Int(regs[6]), 1) * linesPerRow, 1024)
        if w != drawWidth || h != drawHeight || drawBuffer.count != w * h {
            drawWidth = w; drawHeight = h
            drawBuffer = [UInt32](repeating: 0xFF000000, count: w * h)
        }
        screenStart = Int(regs[12]) << 8 | Int(regs[13])
        screenRowAddr = screenStart
        attrRowAddr = Int(regs[20]) << 8 | Int(regs[21])
        if !(interlaced && regs[25] & 0x80 != 0 && field == 1) { bitmapAddr = 0 }   // odd bitmap field continues
        rowCounter = 0
        rowLine = interlaced ? field : 0
        rowLine += Int(regs[24] & 0x1F)                               // vertical smooth scroll
        displayLine = 0
        inFineAdjust = false
        displayEnable = true
    }

    private func endOfLine() {
        let step = interlaced ? 2 : 1
        if !inFineAdjust && rowCounter < Int(regs[6]) {
            drawLine()
            // Bitmap data is a linear array: one line of R1 bytes (+ R27 skipped) per raster line.
            bitmapAddr += Int(regs[1]) + Int(regs[27])
        }
        rowLine += step
        let lastLine = inFineAdjust ? Int(regs[5] & 0x1F) : Int(regs[9] & 0x1F)
        if rowLine > lastLine {
            rowLine = interlaced ? field : 0
            if inFineAdjust {
                finishFrame()
                return
            }
            if rowCounter < Int(regs[6]) {
                screenRowAddr += Int(regs[1]) + Int(regs[27])
                attrRowAddr += Int(regs[1]) + Int(regs[27])
            }
            rowCounter += 1
            if rowCounter >= Int(regs[6]) { displayEnable = false }
            if rowCounter > Int(regs[4]) {
                if regs[5] & 0x1F != 0 { inFineAdjust = true; rowLine = 0 } else { finishFrame() }
            }
        }
    }

    private func finishFrame() {
        // Hand over the completed picture. In interlace both fields together make the picture.
        if !interlaced || field == 1 {
            picture = drawBuffer
            pictureWidth = drawWidth
            pictureHeight = drawHeight
            pictureCount &+= 1
        }
        frameCount += 1
        field = interlaced ? frameCount & 1 : 0
        startFrame()
    }

    // MARK: - Drawing

    /// Pixels displayed per character and semigraphics, as VICE's calculate_draw_masks().
    private func cellShape() -> (shown: Int, semiTest: UInt8, semiGap: Bool, gapPixels: Int) {
        let r22 = regs[22], r25 = regs[25]
        let i = Int(doublePixel && r22 & 0x08 == 0 && r22 >= 0x10 ? r22 - 0x10 : r22)
        var shown = max(0, VDC8563.displayedWidth[i])
        var semiTest: UInt8 = 0
        var semiGap = false
        let hiEqualsLo = r22 >> 4 == r22 & 0x0F
        if r25 & 0x20 != 0 || (doublePixel && hiEqualsLo) {
            if doublePixel && hiEqualsLo {
                if r22 & 0x0F <= 8 { shown = 1 }
            } else if shown == 0 {
                shown = 8
            }
            if shown > 0 { semiTest = 0x80 >> UInt8(shown - 1) }
            semiGap = VDC8563.semiGfxType[i]
        }
        let cellPixels = doublePixel ? Int(r22 >> 4) : Int(r22 >> 4) + 1
        return (shown, semiTest, semiGap, max(0, cellPixels - 8))
    }

    private func drawLine() {
        let y = interlaced ? displayLine * 2 + field : displayLine
        displayLine += 1
        guard y < drawHeight else { return }
        let w = drawWidth
        let base = y * w
        // Display enable (R34 begin, R35 end), as VICE: when the character counter (0...R0) never
        // reaches R34 the line stays blanked. Programs set R34 past R0 to hide the screen while
        // they set up a new one.
        if (regs[34] > regs[0] && regs[35] <= regs[0]) || (regs[34] == regs[35] && regs[35] <= regs[0]) {
            for i in base..<base + w { drawBuffer[i] = 0xFF000000 }
            return
        }
        let bitmap = regs[25] & 0x80 != 0
        let attrsOn = regs[25] & 0x40 != 0
        let px = doublePixel ? 2 : 1
        let cellPixels = doublePixel ? Int(regs[22] >> 4) : Int(regs[22] >> 4) + 1
        let cellDots = cellPixels * px
        let shape = cellShape()
        let line = rowLine
        let displayedLines = Int(regs[23] & 0x1F)
        let bytesPerChar = Int(regs[9] & 0x1F) > 15 ? 32 : 16
        let charset = Int(regs[28] & 0xE0) << 8
        let underline = Int(regs[29] & 0x1F)
        let blinkRate = regs[24] & 0x20 != 0 ? 32 : 16
        let blinkOn = (frameCount / blinkRate) & 1 == 0
        let cursor = Int(regs[14]) << 8 | Int(regs[15])
        let cursorMode = (regs[10] >> 5) & 3                             // 0 solid, 1 off, 2 1/16, 3 1/32
        let cursorOn = cursorMode == 0 || (cursorMode >= 2 && (frameCount / (cursorMode == 2 ? 16 : 32)) & 1 == 0)
        let cursorStart = Int(regs[10] & 0x1F), cursorEnd = Int(regs[11] & 0x1F)
        let reverseScreen = regs[24] & 0x40 != 0
        // Horizontal smooth scroll, as VICE's draw offset: positive moves the picture right.
        let xOffset = (doublePixel ? 2 : 0) + (Int(regs[25] & 0x0F) - Int(regs[22] >> 4)) * px
        let fg0 = Int(regs[26] >> 4), bg0 = Int(regs[26] & 0x0F)
        let cols = Int(regs[1])

        // Background: text mode uses R26; bitmap with attributes colours per cell below.
        let fill = VDC8563.rgbi[bg0]
        for i in base..<base + w { drawBuffer[i] = fill }

        for col in -1...cols {                                           // one cell each side for scrolling
            let x0 = col * cellDots + xOffset
            if x0 >= w || x0 + cellDots <= 0 { continue }
            let c = max(0, min(col, cols - 1))
            let attr: UInt8 = attrsOn ? peek(attrRowAddr + c) : UInt8(fg0)
            var fg = Int(attr & 0x0F)
            var bg = bg0
            var bits: UInt8 = 0
            if line <= displayedLines {
                if bitmap {
                    bits = peek(screenStart + bitmapAddr + c)
                    if attrsOn { bg = Int(attr >> 4) } else { fg = fg0 }
                } else {
                    let code = Int(peek(screenRowAddr + c)) | (attrsOn && attr & 0x80 != 0 ? 0x100 : 0)
                    if line < bytesPerChar { bits = peek(charset + code * bytesPerChar + line) }
                    if attrsOn {
                        if attr & 0x20 != 0 && line == underline { bits = 0xFF }
                        if attr & 0x10 != 0 && !blinkOn { bits = 0 }
                        if attr & 0x40 != 0 { bits = ~bits }
                    }
                    if cursorOn && (screenRowAddr + c) & 0xFFFF == cursor && line >= cursorStart && line <= cursorEnd {
                        bits = ~bits
                    }
                }
            } else if bitmap && attrsOn {
                bg = Int(attr >> 4)
            }
            if shape.shown < 8 { bits &= ~(0xFF >> UInt8(shape.shown)) }
            var gapOn = false
            if shape.semiTest != 0 && bits & shape.semiTest != 0 {
                bits |= shape.semiTest &- 1
                gapOn = shape.semiGap
            }
            if reverseScreen { bits = ~bits; gapOn = !gapOn }
            let fgc = VDC8563.rgbi[fg], bgc = VDC8563.rgbi[bg]
            for p in 0..<cellPixels {
                let on = p < 8 ? bits & (0x80 >> UInt8(p)) != 0 : gapOn
                let color = on ? fgc : bgc
                for d in 0..<px {
                    let x = x0 + p * px + d
                    if x >= 0 && x < w { drawBuffer[base + x] = color }
                }
            }
        }
    }

    /// The text screen as ASCII lines (for tests and debugging).
    public func text() -> [String] {
        let cols = max(1, min(Int(regs[1]), 80)), screen = Int(regs[12]) << 8 | Int(regs[13])
        return (0..<min(Int(regs[6]), 25)).map { row in
            String((0..<cols).map { col -> Character in
                let c = peek(screen + row * (cols + Int(regs[27])) + col) & 0x7F
                switch c {
                case 0: return "@"
                case 1...26: return Character(UnicodeScalar(c + 64))
                case 32...63: return Character(UnicodeScalar(c))
                default: return " "
                }
            })
        }
    }

    /// VICE's vdc-draw.c tables: pixels displayed per character for R22, and whether semigraphics
    /// extends into the inter-character gap.
    static let displayedWidth: [Int] = [
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        1, 2, 0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        1, 2, 3, 0, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        1, 2, 3, 4, 0, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        1, 2, 3, 4, 5, 0, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
        1, 2, 3, 4, 5, 6, 0, 7, 7, 7, 7, 7, 7, 7, 7, 7,
        1, 2, 3, 4, 5, 6, 7, 0, 8, 8, 8, 8, 8, 8, 8, 8,
        2, 3, 4, 5, 6, 7, 8, 0, 1, 8, 8, 8, 8, 8, 8, 8,
        3, 4, 5, 6, 7, 8, 8, 0, 1, 2, 8, 8, 8, 8, 8, 8,
        4, 5, 6, 7, 8, 8, 8, 0, 1, 2, 3, 8, 8, 8, 8, 8,
        5, 6, 7, 8, 8, 8, 8, 0, 1, 2, 3, 4, 8, 8, 8, 8,
        6, 7, 8, 8, 8, 8, 8, 0, 1, 2, 3, 4, 5, 8, 8, 8,
        7, 8, 8, 8, 8, 8, 8, 0, 1, 2, 3, 4, 5, 6, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 0, 1, 2, 3, 4, 5, 6, 7, 8,
        8, 8, 8, 8, 8, 8, 8, 0, 1, 2, 3, 4, 5, 6, 7, 8,
    ]

    static let semiGfxType: [Bool] = {
        var t = [Bool](repeating: false, count: 256)
        for hi in 7...15 {
            for lo in 0..<16 {
                let i = hi << 4 | lo
                if hi == 7 { t[i] = lo < 8 }
                else if hi == 15 { t[i] = lo >= 8 }
                else { t[i] = lo < 15 - hi || (lo >= 8 && lo < 8 + hi - 7) }
            }
        }
        return t
    }()
}
