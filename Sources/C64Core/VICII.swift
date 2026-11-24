// MOS 6569 (PAL) / 6567R8 (NTSC) VIC-II. Cycle-stepped: badlines, sprite DMA, border flip-flops, raster IRQ,
// all graphics modes, sprites with collisions. Draws 8 pixels per cycle so mid-line register
// changes (raster bars, tape loading stripes) show up.

/// TV standard of the machine: PAL (UK/Europe/Australia) or NTSC (USA/Canada/Japan).
public enum VideoStandard: String, CaseIterable {
    case pal, ntsc
}

public final class VICII {
    /// PAL timing (the default machine).
    public static let cyclesPerLine = 63
    public static let linesPerFrame = 312
    public static let screenWidth = 384
    public static let screenHeight = 272
    static let firstVisibleLine = 15
    static let firstVisibleCycle = 13   // X = -8 (sprite coordinate 0x1F8)

    /// Colodore palette, 0xAARRGGBB.
    public static let palette: [UInt32] = [
        0xFF000000, 0xFFFFFFFF, 0xFF813338, 0xFF75CEC8, 0xFF8E3C97, 0xFF56AC4D, 0xFF2E2C9B, 0xFFEDF171,
        0xFF8E5029, 0xFF553800, 0xFFC46C71, 0xFF4A4A4A, 0xFF7B7B7B, 0xFFA9FF9F, 0xFF706DEB, 0xFFB2B2B2,
    ]

    /// The picture being drawn, in fixed storage so the per-pixel writes skip array copy-on-write checks.
    private let pixels: UnsafeMutablePointer<UInt32> = {
        let p = UnsafeMutablePointer<UInt32>.allocate(capacity: screenWidth * screenHeight)
        p.initialize(repeating: 0xFF000000, count: screenWidth * screenHeight)
        return p
    }()
    /// A copy of the current picture (384×272, 0xAARRGGBB).
    public var frameBuffer: [UInt32] { Array(UnsafeBufferPointer(start: pixels, count: VICII.screenWidth * VICII.screenHeight)) }
    public var frameCount = 0
    public var onFrame: (() -> Void)?

    /// 14-bit VIC address read (bank + char ROM mapping done by the machine).
    public var memRead: (UInt16) -> UInt8 = { _ in 0 }
    /// Color RAM read (10-bit offset, low nibble valid).
    public var colorRead: (Int) -> UInt8 = { _ in 0 }
    /// The machine, called directly for fetches (calling the closures above retains their context).
    var host: Unmanaged<C64>?

    @inline(__always) private func fetch(_ a: UInt16) -> UInt8 {
        if let h = host { return h._withUnsafeGuaranteedRef { $0.vicFetch(a) } }
        return memRead(a)
    }

    @inline(__always) private func fetchColor(_ o: Int) -> UInt8 {
        if let h = host { return h._withUnsafeGuaranteedRef { $0.colorRAM[o & 0x3FF] } }
        return colorRead(o)
    }

    let regs = FixedBuffer<UInt8>(count: 0x40, repeating: 0)
    public private(set) var raster = 0
    public private(set) var cycle = 1
    public private(set) var irq = false

    var irr: UInt8 = 0
    var imr: UInt8 = 0
    var rasterCompare = 0

    var vc = 0, vcbase = 0, rc = 0, vmli = 0
    var displayState = false
    var badline = false
    var denLatch = false
    var d011Written = false
    var verticalBorder = true
    var mainBorder = true

    let lineChars = FixedBuffer<UInt8>(count: 40, repeating: 0)
    let lineColors = FixedBuffer<UInt8>(count: 40, repeating: 0)
    let lineGfx = FixedBuffer<UInt8>(count: 40, repeating: 0)
    let lineGfxValid = FixedBuffer<Bool>(count: 40, repeating: false)
    var idleGfx: UInt8 = 0

    // Sprites
    let spriteDMA = FixedBuffer<Bool>(count: 8, repeating: false)
    let spriteDisplay = FixedBuffer<Bool>(count: 8, repeating: false)
    let mc = FixedBuffer<Int>(count: 8, repeating: 0)
    let mcbase = FixedBuffer<Int>(count: 8, repeating: 0)
    let expFF = FixedBuffer<Bool>(count: 8, repeating: true)
    let spriteFetch = FixedBuffer<UInt32>(count: 8, repeating: 0)
    let spriteData = FixedBuffer<UInt32>(count: 8, repeating: 0)
    let spriteShown = FixedBuffer<Bool>(count: 8, repeating: false)
    var spriteCollisionSS: UInt8 = 0
    var spriteCollisionSB: UInt8 = 0

    public private(set) var standard = VideoStandard.pal
    public private(set) var cyclesPerLine = 63
    public private(set) var linesPerFrame = 312

    /// Auto video standard: at the end of each frame the chip may change between NTSC and PAL
    /// (without a reset) depending on what the running program expects; see `autoSwitchStandard`.
    public var autoStandard = false
    /// Called after an automatic change, so the machine can retune its clocks.
    public var onStandardChange: (() -> Void)?
    /// Set when, at the start of a line in this frame, a raster IRQ was armed for line 263 or later —
    /// a line only PAL has.
    private var palHint = false
    private var palFrames = 0
    private var ntscFrames = 0
    private var quietFrames = 0
    /// Frames in a row with PAL (NTSC) evidence before switching; PAL also returns to NTSC after
    /// `framesToNTSCQuiet` frames with no PAL evidence at all.
    static let framesToSwitch = 2
    static let framesToNTSCQuiet = 150

    /// Cycles since power-on, for the register-write timing signature below.
    private var ticks = 0
    private let lastWrite = FixedBuffer<Int>(count: 0x40, repeating: Int.min / 2)
    /// Per register, this frame: writes that came within two lines of the previous write to the same
    /// register (raster-bar loops), and which cycle positions they took on a 63- and a 65-cycle line.
    private let loopWrites = FixedBuffer<Int>(count: 0x40, repeating: 0)
    private let pos63 = FixedBuffer<UInt64>(count: 0x40, repeating: 0)
    private let pos65 = FixedBuffer<UInt64>(count: 0x40, repeating: 0)
    private let pos65Last = FixedBuffer<Bool>(count: 0x40, repeating: false)

    private func noteWriteTiming(_ r: Int) {
        let gap = ticks - lastWrite[r]
        lastWrite[r] = ticks
        guard gap < 2 * cyclesPerLine else { return }
        loopWrites[r] += 1
        pos63[r] |= 1 << UInt64(ticks % 63)
        let p65 = ticks % 65
        if p65 == 64 { pos65Last[r] = true } else { pos65[r] |= 1 << UInt64(p65) }
    }

    /// Smallest number of consecutive cycle positions (on a circular line of `length`) holding all set bits.
    private static func spread(_ bits: UInt64, last: Bool, length: Int) -> Int {
        var set: [Int] = (0..<min(length, 64)).filter { bits & (1 << UInt64($0)) != 0 }
        if last { set.append(64) }
        guard set.count > 1 else { return set.count }
        var widestGap = length - set[set.count - 1] + set[0]
        for i in 1..<set.count { widestGap = max(widestGap, set[i] - set[i - 1]) }
        return length - widestGap + 1
    }

    /// Raster-bar code is cycle-counted for one machine: its writes stay at the same place on every
    /// line of that machine's length (63 PAL, 65 NTSC) and drift across the line on the other.
    /// Returns, for this frame, how many registers look PAL-timed and how many NTSC-timed.
    private func timingVotes() -> (pal: Int, ntsc: Int) {
        var pal = 0, ntsc = 0
        for r in 0..<0x40 where loopWrites[r] >= 16 {
            let s63 = VICII.spread(pos63[r], last: false, length: 63)
            let s65 = VICII.spread(pos65[r], last: pos65Last[r], length: 65)
            if s63 + 16 <= s65 { pal += 1 } else if s65 + 16 <= s63 { ntsc += 1 }
        }
        for r in 0..<0x40 { loopWrites[r] = 0; pos63[r] = 0; pos65[r] = 0; pos65Last[r] = false }
        return (pal, ntsc)
    }

    public init() {}
    deinit {
        pixels.deallocate()
        regs.deallocate(); lineChars.deallocate(); lineColors.deallocate(); lineGfx.deallocate()
        lineGfxValid.deallocate(); spriteDMA.deallocate(); spriteDisplay.deallocate(); mc.deallocate()
        mcbase.deallocate(); expFF.deallocate(); spriteFetch.deallocate(); spriteData.deallocate()
        spriteShown.deallocate(); lastWrite.deallocate(); loopWrites.deallocate(); pos63.deallocate()
        pos65.deallocate(); pos65Last.deallocate()
    }

    /// Switches between the PAL 6569 (63 cycles × 312 lines) and NTSC 6567R8 (65 × 263).
    public func setStandard(_ s: VideoStandard) {
        setGeometry(s)
        reset()
    }

    private func setGeometry(_ s: VideoStandard) {
        standard = s
        cyclesPerLine = s == .pal ? 63 : 65
        linesPerFrame = s == .pal ? 312 : 263
    }

    /// Auto mode, at a frame boundary. PAL evidence: a raster IRQ waiting for line 263+ (never fires
    /// on NTSC), or raster-bar writes locked to 63-cycle lines (PAL cracktros). NTSC evidence: writes
    /// locked to 65-cycle lines. Two frames of evidence for the other standard switch to it; PAL also
    /// goes back to NTSC after about three seconds with no PAL evidence (the program moved on).
    private func autoSwitchStandard() {
        let votes = timingVotes()
        let pal = palHint || votes.pal > votes.ntsc
        let ntsc = !palHint && votes.ntsc > votes.pal
        palHint = false
        palFrames = pal ? palFrames + 1 : 0
        ntscFrames = ntsc ? ntscFrames + 1 : 0
        quietFrames = pal ? 0 : quietFrames + 1
        let target: VideoStandard
        if standard == .ntsc && palFrames >= VICII.framesToSwitch { target = .pal }
        else if standard == .pal && (ntscFrames >= VICII.framesToSwitch || quietFrames >= VICII.framesToNTSCQuiet) {
            target = .ntsc
        } else { return }
        palFrames = 0; ntscFrames = 0; quietFrames = 0
        setGeometry(target)
        onStandardChange?()
    }

    public func reset() {
        regs.fill(0)
        raster = 0; cycle = 1; irr = 0; imr = 0; irq = false; rasterCompare = 0
        vc = 0; vcbase = 0; rc = 0; displayState = false
        for n in 0..<8 { spriteDMA[n] = false; spriteDisplay[n] = false; expFF[n] = true }
        palHint = false; palFrames = 0; ntscFrames = 0; quietFrames = 0
    }

    // MARK: - Bus arbitration

    /// Sprite n pointer fetch cycle (PAL).
    @inline(__always) func spriteCycle(_ n: Int) -> Int {
        let c = cyclesPerLine - 5 + 2 * n
        return c > cyclesPerLine ? c - cyclesPerLine : c
    }

    /// True when the VIC holds the bus in the current cycle, so a CPU access of the given
    /// kind must wait (BA low; writes may continue for the first three cycles).
    @inline(__always) public func blocksCPU(write: Bool) -> Bool {
        if badline && cycle >= (write ? 15 : 12) && cycle <= 54 { return true }
        for n in 0..<8 where spriteDMA[n] {
            let sc = spriteCycle(n)
            var d = cycle - sc
            if d < -10 { d += cyclesPerLine } else if d > 10 { d -= cyclesPerLine }
            if d >= (write ? 0 : -3) && d <= 1 { return true }
        }
        return false
    }

    // MARK: - Registers

    @inline(__always) var den: Bool { regs[0x11] & 0x10 != 0 }
    @inline(__always) var yscroll: Int { Int(regs[0x11] & 7) }
    @inline(__always) var xscroll: Int { Int(regs[0x16] & 7) }

    private func updateIRQ() {
        irq = irr & imr & 0x0F != 0
    }

    private func checkRasterIRQ() {
        if raster == rasterCompare {
            irr |= 0x01
            updateIRQ()
        }
    }

    public func read(_ reg: Int) -> UInt8 {
        let r = reg & 0x3F
        switch r {
        case 0x11: return (regs[0x11] & 0x7F) | (raster > 0xFF ? 0x80 : 0)
        case 0x12: return UInt8(raster & 0xFF)
        case 0x16: return regs[0x16] | 0xC0
        case 0x18: return regs[0x18] | 0x01
        case 0x19: return irr | (irq ? 0x80 : 0) | 0x70
        case 0x1A: return imr | 0xF0
        case 0x1E: let v = spriteCollisionSS; spriteCollisionSS = 0; return v
        case 0x1F: let v = spriteCollisionSB; spriteCollisionSB = 0; return v
        case 0x20...0x2E: return regs[r] | 0xF0
        case 0x2F...0x3F: return 0xFF
        default: return regs[r]
        }
    }

    public func write(_ reg: Int, _ value: UInt8) {
        let r = reg & 0x3F
        if autoStandard { noteWriteTiming(r) }
        switch r {
        case 0x11:
            regs[0x11] = value
            let old = rasterCompare
            rasterCompare = (rasterCompare & 0xFF) | (Int(value & 0x80) << 1)
            if old != rasterCompare { checkRasterIRQ() }
            if raster == 0x30 && den { denLatch = true }
            d011Written = true
        case 0x12:
            let old = rasterCompare
            rasterCompare = (rasterCompare & 0x100) | Int(value)
            if old != rasterCompare { checkRasterIRQ() }
        case 0x19:
            irr &= ~(value & 0x0F)
            updateIRQ()
        case 0x1A:
            imr = value & 0x0F
            updateIRQ()
        case 0x1E, 0x1F: break
        case 0x2F...0x3F: break
        default: regs[r] = value
        }
    }

    @inline(__always) private func updateBadline() {
        badline = raster >= 0x30 && raster <= 0xF7 && (raster & 7) == yscroll && denLatch
        if badline { displayState = true }
    }

    // MARK: - Memory accesses

    @inline(__always) private var videoMatrix: Int { Int(regs[0x18] & 0xF0) << 6 }
    @inline(__always) private var charBase: Int { Int(regs[0x18] & 0x0E) << 10 }

    private func cAccess() {
        lineChars[vmli] = fetch(UInt16((videoMatrix | vc) & 0x3FFF))
        lineColors[vmli] = fetchColor(vc) & 0x0F
    }

    private func gAccess() {
        let ecm = regs[0x11] & 0x40 != 0
        let bmm = regs[0x11] & 0x20 != 0
        if displayState {
            var addr: Int
            if bmm {
                addr = (charBase & 0x2000) | (vc << 3) | rc
            } else {
                addr = charBase | (Int(lineChars[vmli]) << 3) | rc
            }
            if ecm { addr &= ~0x0600 }
            lineGfx[vmli] = fetch(UInt16(addr & 0x3FFF))
            lineGfxValid[vmli] = true
            vc = (vc + 1) & 0x3FF
            vmli = (vmli + 1) & 0x3F
        } else {
            idleGfx = fetch(ecm ? 0x39FF : 0x3FFF)
            if vmli < 40 { lineGfxValid[vmli] = false; lineGfx[vmli] = idleGfx }
            vmli = (vmli + 1) & 0x3F
        }
    }

    private func spriteFetchCycle(_ n: Int) {
        let ptr = Int(fetch(UInt16((videoMatrix | 0x3F8 | n) & 0x3FFF))) << 6
        if spriteDMA[n] {
            var d: UInt32 = 0
            for _ in 0..<3 {
                d = d << 8 | UInt32(fetch(UInt16((ptr | mc[n]) & 0x3FFF)))
                mc[n] = (mc[n] + 1) & 0x3F
            }
            spriteFetch[n] = d
        }
    }

    // MARK: - Clock

    /// Advances one PHI2 cycle.
    public func tick() {
        switch cycle {
        case 1:
            if raster == 0x30 { denLatch = den }
            if raster == 0 { /* raster compare for line 0 handled at cycle 2 */ } else { checkRasterIRQ() }
            updateBadline()
        case 2:
            if raster == 0 { checkRasterIRQ() }
        case 12:
            // All sprite data for this line has been fetched; latch it for display.
            for n in 0..<8 {
                spriteData[n] = spriteFetch[n]
                spriteShown[n] = spriteDisplay[n]
            }
        case 14:
            vc = vcbase
            vmli = 0
            if badline { rc = 0 }
        case 15:
            for n in 0..<8 where expFF[n] { mcbase[n] = (mcbase[n] + 2) & 0x3F }
        case 16:
            for n in 0..<8 where expFF[n] {
                mcbase[n] = (mcbase[n] + 1) & 0x3F
                if mcbase[n] == 63 { spriteDMA[n] = false; spriteDisplay[n] = false }
            }
        case 55:
            let yexp = regs[0x17]
            for n in 0..<8 where yexp & (1 << n) != 0 { expFF[n].toggle() }
            checkSpriteDMAStart()
        case 56:
            checkSpriteDMAStart()
        case 58:
            if rc == 7 {
                vcbase = vc
                if !badline { displayState = false }
            }
            if displayState { rc = (rc + 1) & 7 }
            for n in 0..<8 {
                mc[n] = mcbase[n]
                if spriteDMA[n] && Int(regs[1 + 2 * n]) == raster & 0xFF { spriteDisplay[n] = true }
                if !spriteDMA[n] { spriteDisplay[n] = false }
            }
        default: break
        }

        if cycle == cyclesPerLine {
            let rsel = regs[0x11] & 0x08 != 0
            if raster == (rsel ? 251 : 247) { verticalBorder = true }
            if raster == (rsel ? 51 : 55) && den { verticalBorder = false }
        }

        // Memory accesses for this cycle
        // g-access of column i-1 precedes the c-access of column i in the same cycle.
        if cycle >= 16 && cycle <= 55 { gAccess() }
        if badline && cycle >= 15 && cycle <= 54 && vmli < 40 { cAccess() }
        for n in 0..<8 where spriteCycle(n) == cycle { spriteFetchCycle(n) }
        // The CPU writes in the second half of a cycle, after the VIC's own accesses: a new
        // $D011 changes the badline condition from the next cycle on (DMA delay / VSP scrolling).
        if d011Written { d011Written = false; updateBadline() }

        // Pixel output
        let line = raster - VICII.firstVisibleLine
        if line >= 0 && line < VICII.screenHeight && cycle >= VICII.firstVisibleCycle
            && cycle < VICII.firstVisibleCycle + VICII.screenWidth / 8 {
            drawCycle(line: line)
        }

        ticks &+= 1
        cycle += 1
        if cycle > cyclesPerLine {
            cycle = 1
            raster += 1
            if autoStandard && imr & 0x01 != 0 && rasterCompare >= 263 { palHint = true }
            if raster >= linesPerFrame {
                if standard == .ntsc { fillUnusedLines() }
                raster = 0
                vcbase = 0
                if autoStandard { autoSwitchStandard() }
                frameCount += 1
                onFrame?()
            }
        }
    }

    /// NTSC frames have fewer lines than the 272-line picture; the rows below the last
    /// raster line show the border colour (the TV's bottom overscan).
    private func fillUnusedLines() {
        let firstUnused = linesPerFrame - VICII.firstVisibleLine
        guard firstUnused < VICII.screenHeight else { return }
        let color = VICII.palette[Int(regs[0x20] & 0x0F)]
        for i in firstUnused * VICII.screenWidth..<VICII.screenHeight * VICII.screenWidth { pixels[i] = color }
    }

    private func checkSpriteDMAStart() {
        let enable = regs[0x15]
        let yexp = regs[0x17]
        for n in 0..<8 where enable & (1 << n) != 0 && !spriteDMA[n] {
            if Int(regs[1 + 2 * n]) == raster & 0xFF {
                spriteDMA[n] = true
                mcbase[n] = 0
                if yexp & (1 << n) != 0 { expFF[n] = false }
            }
        }
        for n in 0..<8 where yexp & (1 << n) == 0 { expFF[n] = true }
    }

    // MARK: - Rendering

    private func drawCycle(line: Int) {
        let x0 = (cycle - 17) * 8 + 24
        let rowBase = line * VICII.screenWidth + (cycle - VICII.firstVisibleCycle) * 8
        let csel = regs[0x16] & 0x08 != 0
        let rsel = regs[0x11] & 0x08 != 0
        let leftCmp = csel ? 24 : 31
        let rightCmp = csel ? 344 : 335
        let topCmp = rsel ? 51 : 55
        let bottomCmp = rsel ? 251 : 247
        let ecm = regs[0x11] & 0x40 != 0
        let bmm = regs[0x11] & 0x20 != 0
        let mcm = regs[0x16] & 0x10 != 0
        let xs = xscroll
        let borderColor = VICII.palette[Int(regs[0x20] & 0x0F)]
        let anySprites = spriteShown.contains(true)

        // Fast paths for the common blocks without sprites where no border flip-flop can change
        // within these 8 pixels: solid border, or standard text mode fully inside the screen.
        if !anySprites && !(x0...x0 + 7).contains(leftCmp) && !(x0...x0 + 7).contains(rightCmp) {
            if mainBorder || verticalBorder {
                for p in 0..<8 { pixels[rowBase + p] = borderColor }
                return
            }
            let gx0 = x0 - 24 - xs
            if !ecm && !bmm && !mcm && gx0 >= 0 && gx0 + 7 < 320 {
                let bg = VICII.palette[Int(regs[0x21] & 0x0F)]
                var col = gx0 >> 3, bit = gx0 & 7
                for p in 0..<8 {
                    let on = lineGfx[col] >> (7 - bit) & 1 != 0
                    pixels[rowBase + p] = on ? VICII.palette[lineGfxValid[col] ? Int(lineColors[col]) : 0] : bg
                    bit += 1
                    if bit == 8 { bit = 0; col += 1 }
                }
                return
            }
        }

        for p in 0..<8 {
            let x = x0 + p
            // Border flip-flops
            if x == rightCmp { mainBorder = true }
            if x == leftCmp {
                if raster == bottomCmp { verticalBorder = true }
                if raster == topCmp && den { verticalBorder = false }
                if !verticalBorder { mainBorder = false }
            }

            // Graphics
            var colorIndex = Int(regs[0x21] & 0x0F)
            var foreground = false
            let gx = x - 24 - xs
            if gx >= 0 && gx < 320 {
                let col = gx >> 3
                let bit = gx & 7
                let g = lineGfx[col]
                let valid = lineGfxValid[col]
                let ch = valid ? Int(lineChars[col]) : 0
                let cl = valid ? Int(lineColors[col]) : 0
                switch (ecm, bmm, mcm) {
                case (false, false, false):
                    if (g >> (7 - bit)) & 1 != 0 { colorIndex = cl; foreground = true }
                case (false, false, true):
                    if cl & 8 != 0 {
                        let pair = Int(g >> (6 - (bit & 6))) & 3
                        switch pair {
                        case 0: colorIndex = Int(regs[0x21] & 0x0F)
                        case 1: colorIndex = Int(regs[0x22] & 0x0F)
                        case 2: colorIndex = Int(regs[0x23] & 0x0F); foreground = true
                        default: colorIndex = cl & 7; foreground = true
                        }
                    } else if (g >> (7 - bit)) & 1 != 0 { colorIndex = cl & 7; foreground = true }
                case (false, true, false):
                    if (g >> (7 - bit)) & 1 != 0 { colorIndex = ch >> 4; foreground = true } else { colorIndex = ch & 0x0F }
                case (false, true, true):
                    let pair = Int(g >> (6 - (bit & 6))) & 3
                    switch pair {
                    case 0: colorIndex = Int(regs[0x21] & 0x0F)
                    case 1: colorIndex = ch >> 4
                    case 2: colorIndex = ch & 0x0F; foreground = true
                    default: colorIndex = cl; foreground = true
                    }
                case (true, false, false):
                    if (g >> (7 - bit)) & 1 != 0 { colorIndex = cl; foreground = true }
                    else { colorIndex = Int(regs[0x21 + (ch >> 6)] & 0x0F) }
                default:
                    // Invalid modes: black, but foreground still counts for collisions.
                    if mcm && (!bmm ? cl & 8 != 0 : true) {
                        foreground = (g >> (6 - (bit & 6))) & 2 != 0
                    } else {
                        foreground = (g >> (7 - bit)) & 1 != 0
                    }
                    colorIndex = 0
                }
            }
            var color = VICII.palette[colorIndex]

            // Sprites
            if anySprites {
                let sx = x < 0 ? x + 504 : x
                var spriteColor: UInt32 = 0
                var spriteHit = -1
                var hits: UInt8 = 0
                for n in 0..<8 where spriteShown[n] {
                    let px0 = Int(regs[2 * n]) | (regs[0x10] & (1 << n) != 0 ? 0x100 : 0)
                    var dx = sx - px0
                    if dx < 0 { dx += 504 }
                    let xexp = regs[0x1D] & (1 << n) != 0
                    let width = xexp ? 48 : 24
                    if dx >= width { continue }
                    let px = xexp ? dx >> 1 : dx
                    let d = spriteData[n]
                    var ci = -1
                    if regs[0x1C] & (1 << n) != 0 {
                        let pair = Int(d >> UInt32(22 - (px & ~1))) & 3
                        switch pair {
                        case 1: ci = Int(regs[0x25] & 0x0F)
                        case 2: ci = Int(regs[0x27 + n] & 0x0F)
                        case 3: ci = Int(regs[0x26] & 0x0F)
                        default: break
                        }
                    } else if (d >> UInt32(23 - px)) & 1 != 0 {
                        ci = Int(regs[0x27 + n] & 0x0F)
                    }
                    if ci < 0 { continue }
                    hits |= 1 << n
                    if spriteHit < 0 { spriteHit = n; spriteColor = VICII.palette[ci] }
                }
                if hits != 0 {
                    if hits & (hits - 1) != 0 {
                        if spriteCollisionSS == 0 { irr |= 0x04; updateIRQ() }
                        spriteCollisionSS |= hits
                    }
                    if foreground && !mainBorder {
                        if spriteCollisionSB == 0 { irr |= 0x02; updateIRQ() }
                        spriteCollisionSB |= hits
                    }
                    let behind = regs[0x1B] & (1 << spriteHit) != 0
                    if !(behind && foreground) { color = spriteColor }
                }
            }

            if mainBorder || verticalBorder { color = borderColor }
            pixels[rowBase + p] = color
        }
    }
}
