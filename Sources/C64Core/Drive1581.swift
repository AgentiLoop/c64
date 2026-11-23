/// True Commodore 1581 emulation: a 2 MHz 6502 running the original DOS ROM, an 8520 CIA
/// (serial bus, LEDs, motor, side select), a WD1772 controller and an 80-track 3.5" disk.
public final class Drive1581: CPUBus, FastSerialDevice {
    public private(set) var cpu: CPU6502!
    public let cia = CIA6526()
    public let wd = WD1772()
    var ram = [UInt8](repeating: 0, count: 0x2000)
    let rom: [UInt8]
    unowned let iec: IECBus
    public let deviceNumber: Int

    public private(set) var image: D81Image?
    public var writeProtected = false
    var diskChanged = true
    var atnAsserted = false
    var clockAcc = 0
    /// Clock of the C64 driving this drive (PAL 985 248 Hz / NTSC 1 022 727 Hz).
    public var hostClock = C64.palClock
    var cycleDebt = 0
    public private(set) var cycles: UInt64 = 0

    /// Logical sectors 0–19 of a track are on the head selected with CIA PA0 = 0.
    static func sideIndex(_ paBit: Int) -> Int { paBit }

    public init(rom: [UInt8], iec: IECBus, deviceNumber: Int = 9) {
        precondition(rom.count == 0x8000, "1581 ROM must be 32 KB")
        self.rom = rom
        self.iec = iec
        self.deviceNumber = deviceNumber
        cpu = CPU6502(bus: self)
        cia.portAIn = { [unowned self] in
            var v: UInt8 = 0xFF
            if self.image != nil { v &= ~0x02 }                    // /READY
            v &= ~0x18
            v |= UInt8((self.deviceNumber - 8) & 3) << 3            // device switches
            if self.diskChanged { v &= ~0x80 }                      // /DISK CHANGE
            return v
        }
        cia.portBIn = { [unowned self] in
            var v: UInt8 = 0x7A
            if !self.iec.dataLine { v |= 0x01 }
            if !self.iec.clockLine { v |= 0x04 }
            if self.writeProtected { v &= ~0x40 }
            if self.atnAsserted { v |= 0x80 }
            return v
        }
        cia.onSerialOut = { [unowned self] byte in
            if self.fastSerialOut { self.iec.driveSentFast(byte) }
        }
        wd.hasDisk = { [unowned self] in self.image != nil }
        wd.spinning = { [unowned self] in self.motorOn }
        wd.writeProtected = { [unowned self] in self.writeProtected }
        wd.side = { [unowned self] in Drive1581.sideIndex(Int(self.cia.pra & self.cia.ddra & 1)) }
        wd.stepped = { [unowned self] in if self.image != nil { self.diskChanged = false } }
        wd.readSector = { [unowned self] cyl, side, n in
            guard let img = self.image, cyl < 80, (1...10).contains(n) else { return nil }
            let s = side * 20 + (n - 1) * 2
            return img.sector(cyl + 1, s) + img.sector(cyl + 1, s + 1)
        }
        wd.writeSector = { [unowned self] cyl, side, n, data in
            guard let img = self.image, cyl < 80, (1...10).contains(n), data.count == 512 else { return }
            let s = side * 20 + (n - 1) * 2
            img.setSector(cyl + 1, s, Array(data[0..<256]))
            img.setSector(cyl + 1, s + 1, Array(data[256..<512]))
        }
        reset()
    }

    public func reset() {
        cia.reset()
        wd.reset()
        cpu.reset()
    }

    // MARK: - Media

    public func insert(_ d: D81Image) {
        image = d
        diskChanged = true
    }

    @discardableResult
    public func eject() -> D81Image? {
        let d = image
        image = nil
        diskChanged = true
        return d
    }

    public var ledOn: Bool { cia.pra & cia.ddra & 0x40 != 0 }
    public var motorOn: Bool { cia.ddra & 0x04 != 0 && cia.pra & 0x04 == 0 }

    // MARK: - IEC

    @inline(__always) var portBDriven: UInt8 { cia.prb & cia.ddrb }
    public var pullsClock: Bool { portBDriven & 0x08 != 0 }
    public var pullsData: Bool {
        let out = portBDriven
        // ATN acknowledge: unlike the 1541, PB4 = 1 arms the automatic ATN response.
        return out & 0x02 != 0 || ((out & 0x10 != 0) == atnAsserted)
    }

    /// PB5 = fast serial direction (1 = the drive drives SP/CNT).
    var fastSerialOut: Bool { portBDriven & 0x20 != 0 }

    public func fastSerialIn(_ byte: UInt8) {
        if !fastSerialOut { cia.receiveSerial(byte) }
    }

    public func atnChanged(_ asserted: Bool) {
        atnAsserted = asserted
        if asserted { cia.triggerFlag() }
    }

    // MARK: - Clock

    /// Called once per C64 cycle; runs the drive at 2 MHz.
    @inline(__always) public func clockC64Cycle() {
        clockAcc += 2_000_000
        while clockAcc >= hostClock { clockAcc -= hostClock; cycleDebt += 1 }
        while cycleDebt > 0 { cpu.step() }
    }

    @inline(__always) private func tick() {
        cia.tick()
        wd.tick()
        cpu.irqLine = cia.irq
        cycles &+= 1
        cycleDebt -= 1
    }

    // MARK: - CPUBus

    public func read(_ address: UInt16) -> UInt8 {
        let a = Int(address)
        let v: UInt8
        switch a {
        case 0..<0x2000: v = ram[a]
        case 0x4000..<0x6000: v = cia.read(a)
        case 0x6000..<0x8000: v = wd.read(a)
        case 0x8000...: v = rom[a & 0x7FFF]
        default: v = UInt8(a >> 8)
        }
        tick()
        return v
    }

    public func write(_ address: UInt16, _ value: UInt8) {
        let a = Int(address)
        switch a {
        case 0..<0x2000: ram[a] = value
        case 0x4000..<0x6000: cia.write(a, value)
        case 0x6000..<0x8000: wd.write(a, value)
        default: break
        }
        tick()
    }
}
