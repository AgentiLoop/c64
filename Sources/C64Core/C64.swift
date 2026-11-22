import Foundation

/// The complete C64: 6510 + PLA memory map, VIC-II, SID, two CIAs, keyboard, joysticks.
public final class C64: CPUBus {
    public static let palClock = 985_248
    public static let cyclesPerFrame = VICII.cyclesPerLine * VICII.linesPerFrame

    public private(set) var cpu: CPU6502!
    public let vic = VICII()
    public let sid = SID()
    public let cia1 = CIA6526()
    public let cia2 = CIA6526()

    public var ram = [UInt8](repeating: 0, count: 0x10000)
    public var colorRAM = [UInt8](repeating: 0, count: 0x400)
    let basic: [UInt8]
    let kernal: [UInt8]
    let chargen: [UInt8]

    public private(set) var cycles: UInt64 = 0
    var portDDR: UInt8 = 0
    var portData: UInt8 = 0
    var loram = true, hiram = true, charen = true
    var vicBank = 0
    var todCounter = 0
    var nmiLine = false

    /// Keyboard matrix: keyMatrix[row] has bit `col` set while that key is held.
    /// Row = CIA1 port A bit, column = CIA1 port B bit.
    var keyMatrix = [UInt8](repeating: 0, count: 8)
    public var restorePressed = false
    /// Joystick state, bits: 0 up, 1 down, 2 left, 3 right, 4 fire (1 = active).
    public var joystick1: UInt8 = 0
    public var joystick2: UInt8 = 0

    /// IEC serial bus shared with disk drives.
    public let iec = IECBus()
    /// Cassette sense line (true = PLAY pressed).
    public var cassetteSense = false
    /// Cassette motor control output (true = motor on).
    public var cassetteMotor: Bool { (portData & portDDR & 0x20) == 0 && portDDR & 0x20 != 0 }
    /// Extra devices clocked with the machine (drives, datasette).
    public var clockedDevices: [(C64) -> Void] = []

    public init(basic: [UInt8], kernal: [UInt8], chargen: [UInt8]) {
        self.basic = basic
        self.kernal = kernal
        self.chargen = chargen
        cpu = CPU6502(bus: self)
        wire()
        reset()
    }

    public convenience init(roms: ROMSet) {
        self.init(basic: roms.basic, kernal: roms.kernal, chargen: roms.chargen)
    }

    private func wire() {
        vic.memRead = { [unowned self] a in
            let addr = Int(a)
            if vicBank & 1 == 0 && addr & 0x3000 == 0x1000 { return self.chargen[addr & 0x0FFF] }
            return self.ram[vicBank << 14 | addr]
        }
        vic.colorRead = { [unowned self] o in self.colorRAM[o & 0x3FF] }
        cia1.portAIn = { [unowned self] in self.keyboardPortA() }
        cia1.portBIn = { [unowned self] in self.keyboardPortB() }
        cia2.portAChanged = { [unowned self] in
            let pa = self.cia2.portAOutput
            self.vicBank = Int(3 - (pa & 3))
            self.iec.setC64Lines(atn: pa & 0x08 != 0, clock: pa & 0x10 != 0, data: pa & 0x20 != 0)
        }
        cia2.portAIn = { [unowned self] in
            var v: UInt8 = 0x3F
            if self.iec.clockLine { v |= 0x40 }
            if self.iec.dataLine { v |= 0x80 }
            return v
        }
    }

    public func reset() {
        for i in 0..<ram.count { ram[i] = (i & 0x40) != 0 ? 0xFF : 0x00 }
        portDDR = 0; portData = 0
        updatePort()
        vic.reset()
        sid.reset()
        cia1.reset()
        cia2.reset()
        iec.reset()
        cpu.reset()
    }

    // MARK: - Running

    /// Runs one full video frame.
    public func runFrame() {
        let start = vic.frameCount
        while vic.frameCount == start { cpu.step() }
    }

    /// Runs at least the given number of CPU cycles.
    public func run(cycles n: Int) {
        let end = cycles + UInt64(n)
        while cycles < end { cpu.step() }
    }

    @inline(__always) func clock() {
        vic.tick()
        cia1.tick()
        cia2.tick()
        sid.tick()
        for d in clockedDevices { d(self) }
        cycles &+= 1
        todCounter += 1
        if todCounter >= C64.palClock / 50 {
            todCounter = 0
            cia1.tickTOD()
            cia2.tickTOD()
        }
        cpu.irqLine = vic.irq || cia1.irq
        let nmi = cia2.irq || restorePressed
        if nmi && !nmiLine { cpu.nmiPending = true }
        nmiLine = nmi
    }

    // MARK: - CPUBus

    public func read(_ address: UInt16) -> UInt8 {
        while vic.blocksCPU(write: false) { clock() }
        let v = peek(address)
        clock()
        return v
    }

    public func write(_ address: UInt16, _ value: UInt8) {
        while vic.blocksCPU(write: true) { clock() }
        poke(address, value)
        clock()
    }

    // MARK: - Memory map

    private func updatePort() {
        let lines = portData | ~portDDR
        loram = lines & 1 != 0
        hiram = lines & 2 != 0
        charen = lines & 4 != 0
    }

    /// CPU-visible read with I/O side effects.
    public func peek(_ address: UInt16) -> UInt8 {
        let a = Int(address)
        switch a >> 12 {
        case 0x0:
            if a == 0 { return portDDR }
            if a == 1 {
                var input: UInt8 = 0xDF
                if cassetteSense { input &= ~0x10 }
                return (portData & portDDR) | (input & ~portDDR)
            }
            return ram[a]
        case 0xA, 0xB:
            return loram && hiram ? basic[a & 0x1FFF] : ram[a]
        case 0xD:
            if !(loram || hiram) { return ram[a] }
            if !charen { return chargen[a & 0x0FFF] }
            return readIO(a)
        case 0xE, 0xF:
            return hiram ? kernal[a & 0x1FFF] : ram[a]
        default:
            return ram[a]
        }
    }

    public func poke(_ address: UInt16, _ value: UInt8) {
        let a = Int(address)
        if a < 2 {
            if a == 0 { portDDR = value } else { portData = value }
            updatePort()
            ram[a] = value
            return
        }
        if a >> 12 == 0xD && (loram || hiram) && charen {
            writeIO(a, value)
            return
        }
        ram[a] = value
    }

    private func readIO(_ a: Int) -> UInt8 {
        switch a >> 8 {
        case 0xD0...0xD3: return vic.read(a)
        case 0xD4...0xD7: return sid.read(a & 0x1F)
        case 0xD8...0xDB: return colorRAM[a & 0x3FF] | 0xF0
        case 0xDC: return cia1.read(a)
        case 0xDD: return cia2.read(a)
        default: return 0xFF
        }
    }

    private func writeIO(_ a: Int, _ v: UInt8) {
        switch a >> 8 {
        case 0xD0...0xD3: vic.write(a, v)
        case 0xD4...0xD7: sid.write(a & 0x1F, v)
        case 0xD8...0xDB: colorRAM[a & 0x3FF] = v & 0x0F
        case 0xDC: cia1.write(a, v)
        case 0xDD: cia2.write(a, v)
        default: break
        }
    }

    // MARK: - Keyboard / joysticks

    public func setKey(_ key: C64Key, pressed: Bool) {
        if key == .restore { restorePressed = pressed; return }
        let (row, col) = key.matrix
        if pressed { keyMatrix[row] |= 1 << col } else { keyMatrix[row] &= ~(1 << col) }
    }

    public func releaseAllKeys() {
        for i in 0..<8 { keyMatrix[i] = 0 }
        restorePressed = false
    }

    private func keyboardPortB() -> UInt8 {
        let pa = cia1.portAOutput & ~joystick2
        var v: UInt8 = 0xFF
        for row in 0..<8 where pa & (1 << row) == 0 { v &= ~keyMatrix[row] }
        return v & ~joystick1
    }

    private func keyboardPortA() -> UInt8 {
        let pb = cia1.portBOutput & ~joystick1
        var v: UInt8 = 0xFF
        for row in 0..<8 where keyMatrix[row] & ~pb != 0 { v &= ~(1 << row) }
        return v & ~joystick2
    }

    // MARK: - Program injection

    /// Places a PRG (2-byte load address + data) into memory, like LOAD"X",8,1 followed by
    /// fixing up BASIC's end-of-program pointers. Returns the load address.
    @discardableResult
    public func loadPRG(_ data: [UInt8]) -> UInt16 {
        guard data.count > 2 else { return 0 }
        let start = Int(data[0]) | Int(data[1]) << 8
        var end = start
        for b in data.dropFirst(2) where end < 0x10000 {
            ram[end] = b
            end += 1
        }
        if start == 0x0801 {
            ram[0x2D] = UInt8(end & 0xFF); ram[0x2E] = UInt8(end >> 8)
            ram[0x2F] = UInt8(end & 0xFF); ram[0x30] = UInt8(end >> 8)
            ram[0x31] = UInt8(end & 0xFF); ram[0x32] = UInt8(end >> 8)
            ram[0xAE] = UInt8(end & 0xFF); ram[0xAF] = UInt8(end >> 8)
        }
        return UInt16(start)
    }

    /// Puts text into the KERNAL keyboard buffer (max 10 chars at a time).
    public func typeIntoBuffer(_ text: String) {
        var n = Int(ram[0xC6])
        for ch in text.uppercased().unicodeScalars where n < 10 {
            let code: UInt8 = ch == "\n" ? 13 : UInt8(truncatingIfNeeded: ch.value)
            ram[0x277 + n] = code
            n += 1
        }
        ram[0xC6] = UInt8(n)
    }

    /// Reads the text screen at $0400 as ASCII lines (for tests and debugging).
    public func screenText() -> [String] {
        let base = Int(vic.read(0x18) & 0xF0) << 6 | vicBank << 14
        return (0..<25).map { row in
            String((0..<40).map { col -> Character in
                let c = ram[base + row * 40 + col] & 0x7F
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
