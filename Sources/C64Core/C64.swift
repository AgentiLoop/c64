import Foundation

/// The complete C64: 6510 + PLA memory map, VIC-II, SID, two CIAs, keyboard, joysticks.
public final class C64: CPUBus {
    public static let palClock = 985_248
    public static let ntscClock = 1_022_727
    public static let cyclesPerFrame = VICII.cyclesPerLine * VICII.linesPerFrame

    /// PAL or NTSC machine. Changing it switches the VIC-II model and clock and resets.
    public var standard: VideoStandard {
        get { vic.standard }
        set {
            vic.setStandard(newValue)
            retuneClocks()
            connectModem()
            reset()
        }
    }
    /// Auto video standard: starts (and resets to) NTSC and lets the VIC-II switch between NTSC and
    /// PAL while running, following the program (see `VICII.autoStandard`).
    public var autoStandard: Bool {
        get { vic.autoStandard }
        set {
            vic.autoStandard = newValue
            if newValue && vic.standard != .ntsc { standard = .ntsc }
        }
    }
    /// Gives the SID, drives, modem and VDC the clock of the current standard.
    private func retuneClocks() {
        sid.clockHz = clockHz
        drive8?.hostClock = clockHz
        drive9?.hostClock = clockHz
        modem?.clockHz = clockHz
        c128?.vdc.clockHz = clockHz
    }
    /// CPU clock in Hz for the current standard.
    public var clockHz: Int { vic.standard == .pal ? C64.palClock : C64.ntscClock }
    public var frameCycles: Int { vic.cyclesPerLine * vic.linesPerFrame }
    /// Mains frequency driving the CIA time-of-day clocks.
    public var mainsHz: Int { vic.standard == .pal ? 50 : 60 }

    public private(set) var cpu: CPU6502<C64>!
    public let vic = VICII()
    public let sid = SID()
    public let cia1 = CIA6526()
    public let cia2 = CIA6526()

    public let ram = Memory(count: 0x10000)
    public let colorRAM = Memory(count: 0x400)
    let basic: Memory
    let kernal: Memory
    let chargen: Memory

    public private(set) var cycles: UInt64 = 0
    var portDDR: UInt8 = 0
    var portData: UInt8 = 0
    var loram = true, hiram = true, charen = true
    var vicBank = 0
    var todCounter = 0
    var nmiLine = false
    var irqSampled = false
    var nmiSampled = false

    /// Keyboard matrix: keyMatrix[row] has bit `col` set while that key is held.
    /// Row = CIA1 port A bit, column = CIA1 port B bit.
    var keyMatrix = [UInt8](repeating: 0, count: 8)
    public var restorePressed = false
    /// Joystick state, bits: 0 up, 1 down, 2 left, 3 right, 4 fire (1 = active).
    public var joystick1: UInt8 = 0
    public var joystick2: UInt8 = 0

    /// IEC serial bus shared with disk drives.
    public let iec = IECBus()
    /// Disk drive 8 (true 1541 emulation), if a drive ROM is available.
    public var drive8: Drive1541? {
        didSet { updateIECDevices() }
    }
    /// Disk drive 9 (true 1581 emulation), created on demand by `attach1581()`.
    public var drive9: Drive1581? {
        didSet { updateIECDevices() }
    }
    var rom1581: [UInt8]?
    var rom1541: [UInt8]?
    var rom1571: [UInt8]?

    /// Makes drive 8 a 1571 (or back a 1541), keeping the disk in it. Returns false without the ROM.
    /// Use a 1571 as drive 8 in C64 mode too (it runs in 1541 mode: 1 MHz, slow serial bus).
    public var use1571OnC64 = false {
        didSet { if c128 == nil { setDrive8Is1571(use1571OnC64) } }
    }

    @discardableResult
    public func setDrive8Is1571(_ on: Bool) -> Bool {
        guard let r = on ? rom1571 : rom1541 else { return false }
        if drive8?.is1571 == on { return true }
        let (d0, d1) = (drive8?.disk, drive8?.disk1)
        drive8 = Drive1541(rom: r, iec: iec)
        drive8?.hostClock = clockHz
        if let d = d0 { drive8?.insert(d, side1: d1) }
        return true
    }

    /// The 1581 is device 8 instead of 9 and the 1541 is unplugged (C128 boot disks in D81 format).
    public private(set) var drive8Is1581 = false

    /// Puts the 1581 on device 8 (1541 unplugged) or back on device 9. Returns the 1581.
    @discardableResult
    public func set1581AsDrive8(_ on: Bool) -> Drive1581? {
        guard let r = rom1581 else { return nil }
        let image = drive9?.image
        drive8Is1581 = on
        drive9 = Drive1581(rom: r, iec: iec, deviceNumber: on ? 8 : 9)
        drive9?.hostClock = clockHz
        if let img = image { drive9?.insert(img) }
        return drive9
    }

    func updateIECDevices() {
        var d: [IECDevice] = []
        if let d8 = drive8, !drive8Is1581 { d.append(d8) }
        if let d9 = drive9 { d.append(d9) }
        iec.devices = d
        drive8U = drive8.map(Unmanaged.passUnretained)
        drive9U = drive9.map(Unmanaged.passUnretained)
    }

    /// Creates the 1581 on device 9 if its ROM is available (and not already present).
    @discardableResult
    public func attach1581() -> Drive1581? {
        if let d = drive9 { return d }
        guard let r = rom1581 else { return nil }
        drive9 = Drive1581(rom: r, iec: iec, deviceNumber: 9)
        drive9?.hostClock = clockHz
        return drive9
    }
    /// The Datasette on the cassette port.
    public let datasette = Datasette()
    /// The modem (nil = none), plugged into `modemPort`.
    public var modem: HayesModem? {
        didSet { modem?.clockHz = clockHz; connectModem(); modemU = modem.map(Unmanaged.passUnretained) }
    }
    /// Where the modem is plugged in.
    public enum ModemPort: String, CaseIterable {
        /// User port, KERNAL RS-232 (300–2400 baud, terminals up to 9600).
        case userPort
        /// SwiftLink-232 cartridge at $DE00, NMI (up to 38,400 baud).
        case swiftLink
        /// Turbo232 cartridge at $DE00, NMI (up to 230,400 baud).
        case turbo232
    }
    public var modemPort = ModemPort.userPort {
        didSet { if modemPort != oldValue { connectModem() } }
    }
    var userPort: UserPortInterface? { didSet { userPortU = userPort.map(Unmanaged.passUnretained) } }
    var swiftLink: SwiftLinkInterface? { didSet { swiftLinkU = swiftLink.map(Unmanaged.passUnretained) } }

    private func connectModem() {
        userPort = nil
        swiftLink = nil
        guard let m = modem else { return }
        switch modemPort {
        case .userPort: userPort = UserPortInterface(modem: m)
        case .swiftLink: swiftLink = SwiftLinkInterface(modem: m, turbo232: false)
        case .turbo232: swiftLink = SwiftLinkInterface(modem: m, turbo232: true)
        }
    }
    var lastWriteLine = false
    /// Cassette motor control output (true = motor on).
    public var cassetteMotor: Bool { (portData & portDDR & 0x20) == 0 && portDDR & 0x20 != 0 }
    /// Extra devices clocked with the machine (drives, datasette).
    public var clockedDevices: [(C64) -> Void] = []
    /// Cycle count at the last reset.
    public private(set) var resetCycle: UInt64 = 0
    /// PETSCII bytes waiting to be fed into the keyboard buffer.
    var typeQueue: [UInt8] = []
    /// C128 mode (MMU, 128K, C128 ROMs) when set; see `setC128`.
    var c128: C128Memory? { didSet { c128U = c128.map(Unmanaged.passUnretained) } }
    // Non-retaining copies of the optional parts that are looked at every cycle: reading a strong
    // (or unowned) optional property retains and releases it, which costs more than the work itself.
    private var c128U: Unmanaged<C128Memory>?
    private var drive8U: Unmanaged<Drive1541>?
    private var drive9U: Unmanaged<Drive1581>?
    private var modemU: Unmanaged<HayesModem>?
    private var userPortU: Unmanaged<UserPortInterface>?
    private var swiftLinkU: Unmanaged<SwiftLinkInterface>?
    private var cpuU: Unmanaged<CPU6502<C64>>!
    private var c128Fast: Bool { c128U?._withUnsafeGuaranteedRef { $0.fast } ?? false }
    /// Called on the emulation thread when the program switched the machine (GO64).
    public var onModelChanged: (() -> Void)?
    /// KERNAL keyboard buffer and its length (C64: $0277/$C6, C128: $034A/$D0).
    var keyBuffer: Int { c128 == nil ? 0x277 : 0x34A }
    var keyCount: Int { c128 == nil ? 0xC6 : 0xD0 }

    public init(basic: [UInt8], kernal: [UInt8], chargen: [UInt8]) {
        self.basic = Memory(basic)
        self.kernal = Memory(kernal)
        self.chargen = Memory(chargen)
        cpu = CPU6502(bus: self)
        cpuU = Unmanaged.passUnretained(cpu)
        wire()
        reset()
    }

    deinit {
        for m in [ram, colorRAM, basic, kernal, chargen] { m.deallocate() }
    }

    public convenience init(roms: ROMSet) {
        self.init(basic: roms.basic, kernal: roms.kernal, chargen: roms.chargen)
        rom1541 = roms.drive1541
        rom1571 = roms.drive1571
        if let r = roms.drive1541 {
            drive8 = Drive1541(rom: r, iec: iec)
            drive8?.hostClock = clockHz
        }
        rom1581 = roms.drive1581
        updateIECDevices()   // didSet does not fire inside an initializer
    }

    private func wire() {
        vic.memRead = { [unowned(unsafe) self] a in self.vicFetch(a) }
        vic.colorRead = { [unowned(unsafe) self] o in self.colorRAM[o & 0x3FF] }
        vic.host = Unmanaged.passUnretained(self)
        vic.onStandardChange = { [unowned(unsafe) self] in self.retuneClocks(); self.todCounter = 0 }
        cia1.portAIn = { [unowned(unsafe) self] in self.keyboardPortA() }
        cia1.portBIn = { [unowned(unsafe) self] in self.keyboardPortB() }
        cia2.portAChanged = { [unowned(unsafe) self] in
            let pa = self.cia2.portAOutput
            self.vicBank = Int(3 - (pa & 3))
            self.iec.setC64Lines(atn: pa & 0x08 != 0, clock: pa & 0x10 != 0, data: pa & 0x20 != 0)
            self.userPort?.setTXD(pa & 0x04 != 0, cycle: self.cycles)
        }
        cia2.portAIn = { [unowned(unsafe) self] in
            var v: UInt8 = 0x3F
            if self.iec.clockLine { v |= 0x40 }
            if self.iec.dataLine { v |= 0x80 }
            return v
        }
        cia2.portBIn = { [unowned(unsafe) self] in self.userPort?.portB ?? 0xFF }
    }

    /// A VIC-II memory fetch (14-bit address in the current bank).
    @inline(__always) func vicFetch(_ a: UInt16) -> UInt8 {
        let addr = Int(a)
        if let m = c128U { return m._withUnsafeGuaranteedRef { vicRead128($0, addr) } }
        if vicBank & 1 == 0 && addr & 0x3000 == 0x1000 { return chargen[addr & 0x0FFF] }
        return ram[vicBank << 14 | addr]
    }

    public func reset() {
        // Auto: every reset starts as NTSC again; the program decides whether it needs PAL.
        if vic.autoStandard && vic.standard != .ntsc { vic.setStandard(.ntsc); retuneClocks() }
        for i in 0..<ram.count { ram[i] = (i & 0x40) != 0 ? 0xFF : 0x00 }
        portDDR = 0; portData = 0
        updatePort()
        vic.reset()
        sid.reset()
        cia1.reset()
        cia2.reset()
        iec.reset()
        drive8?.reset()
        drive9?.reset()
        swiftLink?.reset()
        c128?.reset()
        cpu.reset()
        irqSampled = false; nmiSampled = false
        resetCycle = cycles
        typeQueue.removeAll()
    }

    // MARK: - Running

    /// Runs one full video frame.
    public func runFrame() {
        let start = vic.frameCount
        let cpu = self.cpu!
        while vic.frameCount == start {
            cpu.step()
            if let m = c128U, m._withUnsafeGuaranteedRef({ $0.go64Requested }) { checkGo64() }
        }
        feedTypeQueue()
    }

    /// Runs at least the given number of CPU cycles.
    public func run(cycles n: Int) {
        let end = cycles + UInt64(n)
        let cpu = self.cpu!
        while cycles < end {
            let frame = vic.frameCount
            cpu.step()
            if let m = c128U, m._withUnsafeGuaranteedRef({ $0.go64Requested }) { checkGo64() }
            if vic.frameCount != frame { feedTypeQueue() }
        }
    }

    @inline(__always) func clock() {
        if let u = c128U, u._withUnsafeGuaranteedRef({ m in   // 2 MHz: every other CPU cycle is free
            guard m.fast else { return false }
            m.halfCycle.toggle()
            return m.halfCycle
        }) { return }
        vic.tick()
        cia1.tick()
        cia2.tick()
        sid.tick()
        if !clockedDevices.isEmpty { for d in clockedDevices { d(self) } }
        if let d = drive8U, !drive8Is1581 { d._withUnsafeGuaranteedRef { $0.clockC64Cycle() } }
        if let d = drive9U { d._withUnsafeGuaranteedRef { $0.clockC64Cycle() } }
        if datasette.mode == .playing { datasette.tick(motor: cassetteMotor, cia: cia1) }
        cycles &+= 1
        todCounter += 1
        if todCounter >= (vic.standard == .pal ? C64.palClock / 50 : C64.ntscClock / 60) {
            todCounter = 0
            cia1.tickTOD()
            cia2.tickTOD()
        }
        if let m = c128U { m._withUnsafeGuaranteedRef { $0.vdc.tick(cycle: cycles) } }
        if let m = modemU {
            m._withUnsafeGuaranteedRef { $0.tick(now: cycles) }
            userPortU?._withUnsafeGuaranteedRef { $0.tick(self) }
            swiftLinkU?._withUnsafeGuaranteedRef { $0.tick(now: cycles) }
        }
        // The 6510 samples its interrupt inputs one cycle before an instruction ends, so a line
        // that changes in this cycle is seen by the CPU one cycle later.
        let pendingNMI = nmiSampled
        cpuU._withUnsafeGuaranteedRef { cpu in
            cpu.irqLine = irqSampled
            if pendingNMI { cpu.nmiPending = true }
        }
        irqSampled = vic.irq || cia1.irq
        nmiSampled = false
        let nmi = cia2.irq || restorePressed || (swiftLinkU?._withUnsafeGuaranteedRef { $0.irq } ?? false)
        if nmi && !nmiLine { nmiSampled = true }
        nmiLine = nmi
    }

    // MARK: - CPUBus

    public func read(_ address: UInt16) -> UInt8 {
        while vic.blocksCPU(write: false) && !c128Fast { clock() }
        let v = peek(address)
        clock()
        return v
    }

    public func write(_ address: UInt16, _ value: UInt8) {
        while vic.blocksCPU(write: true) && !c128Fast { clock() }
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
        if a >= 2, let m = c128U { return m._withUnsafeGuaranteedRef { peek128($0, a) } }
        switch a >> 12 {
        case 0x0:
            if a == 0 { return portDDR }
            if a == 1 {
                var input: UInt8 = 0xDF
                if datasette.mode != .stopped { input &= ~0x10 }
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
            let writeLine = (portData & portDDR & 0x08) != 0
            if writeLine && !lastWriteLine { datasette.writeEdge(at: cycles, motor: cassetteMotor) }
            lastWriteLine = writeLine
            ram[a] = value
            return
        }
        if let m = c128U { m._withUnsafeGuaranteedRef { poke128($0, a, value) }; return }
        if a >> 12 == 0xD && (loram || hiram) && charen {
            writeIO(a, value)
            return
        }
        ram[a] = value
    }

    func readIO(_ a: Int) -> UInt8 {
        switch a >> 8 {
        case 0xD0...0xD3: return vic.read(a)
        case 0xD4...0xD7: return sid.read(a & 0x1F)
        case 0xD8...0xDB: return colorRAM[a & 0x3FF] | 0xF0
        case 0xDC: return cia1.read(a)
        case 0xDD: return cia2.read(a)
        case 0xDE: return swiftLink?.read(a) ?? 0xFF
        default: return 0xFF
        }
    }

    func writeIO(_ a: Int, _ v: UInt8) {
        switch a >> 8 {
        case 0xD0...0xD3: vic.write(a, v)
        case 0xD4...0xD7: sid.write(a & 0x1F, v)
        case 0xD8...0xDB: colorRAM[a & 0x3FF] = v & 0x0F
        case 0xDC: cia1.write(a, v)
        case 0xDD: cia2.write(a, v)
        case 0xDE: swiftLink?.write(a, v)
        default: break
        }
    }

    // MARK: - Keyboard / joysticks

    /// Live keyboard state is applied immediately on the emulation thread.
    /// Automated text uses queueTyping instead of delaying gameplay keys.
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
        var n = Int(ram[keyCount])
        for ch in text.uppercased().unicodeScalars where n < 10 {
            let code: UInt8 = ch == "\n" ? 13 : UInt8(truncatingIfNeeded: ch.value)
            ram[keyBuffer + n] = code
            n += 1
        }
        ram[keyCount] = UInt8(n)
    }

    /// Queues text to be typed (ASCII; converted to PETSCII), fed as the buffer empties.
    public func queueTyping(_ text: String) {
        for ch in text.unicodeScalars {
            switch ch.value {
            case 10, 13: typeQueue.append(13)
            case 0x61...0x7A: typeQueue.append(UInt8(ch.value - 0x20))
            case 0x41...0x5A: typeQueue.append(UInt8(ch.value))   // both cases → unshifted letters
            case 0x20...0x40, 0x5B...0x5D: typeQueue.append(UInt8(ch.value))
            default: break
            }
        }
    }

    private func feedTypeQueue() {
        guard !typeQueue.isEmpty, ram[keyCount] == 0 else { return }
        let n = min(9, typeQueue.count)
        for i in 0..<n { ram[keyBuffer + i] = typeQueue[i] }
        ram[keyCount] = UInt8(n)
        typeQueue.removeFirst(n)
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
