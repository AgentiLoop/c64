/// True Commodore 1541 emulation: its own 6502 running the original DOS ROM, two VIA 6522s
/// (VIA1 = serial bus, VIA2 = disk mechanics), the stepper head and a rotating GCR disk.
public final class Drive1541: CPUBus, IECDevice {
    public private(set) var cpu: CPU6502!
    public let via1 = VIA6522()
    public let via2 = VIA6522()
    var ram = [UInt8](repeating: 0, count: 0x800)
    let rom: [UInt8]
    unowned let iec: IECBus

    public private(set) var disk: GCRDisk?
    public private(set) var halfTrack = 36
    var headPos = 0
    var byteTimer = 0
    var sync = false
    var readLatch: UInt8 = 0
    var atnAsserted = false
    var clockAcc = 0
    var cycleDebt = 0
    public private(set) var cycles: UInt64 = 0
    /// Countdown while a disk change is being signalled through the write-protect sensor.
    var diskChangeCycles = 0

    public init(rom: [UInt8], iec: IECBus) {
        precondition(rom.count == 0x4000, "1541 ROM must be 16 KB")
        self.rom = rom
        self.iec = iec
        cpu = CPU6502(bus: self)
        via1.portBIn = { [unowned self] in
            var v: UInt8 = 0x00          // bits 5/6 = 0: device number 8
            if !self.iec.dataLine { v |= 0x01 }
            if !self.iec.clockLine { v |= 0x04 }
            if self.atnAsserted { v |= 0x80 }
            return v
        }
        via2.portAIn = { [unowned self] in self.readLatch }
        via2.portBIn = { [unowned self] in
            var v: UInt8 = self.sync ? 0x00 : 0x80
            let protected = self.diskChangeCycles > 0 ? (self.diskChangeCycles / 100_000) & 1 == 0
                                                      : (self.disk?.writeProtected ?? false)
            if !protected { v |= 0x10 }
            return v
        }
        reset()
    }

    public func reset() {
        via1.reset()
        via2.reset()
        cpu.reset()
    }

    // MARK: - Media

    public func insert(_ d: GCRDisk) {
        disk = d
        diskChangeCycles = 400_000
    }

    @discardableResult
    public func eject() -> GCRDisk? {
        let d = disk
        disk = nil
        diskChangeCycles = 200_000
        return d
    }

    public var ledOn: Bool { via2.portBOutput & 0x08 != 0 }
    public var motorOn: Bool { via2.portBOutput & 0x04 != 0 }
    public var track: Int { halfTrack / 2 }

    // MARK: - IEC

    public var pullsClock: Bool { via1.portBOutput & 0x08 != 0 }
    public var pullsData: Bool {
        let out = via1.portBOutput
        // The ATN acknowledge XOR gate pulls DATA while ATN and ATNA disagree.
        return out & 0x02 != 0 || ((out & 0x10 != 0) != atnAsserted)
    }

    public func atnChanged(_ asserted: Bool) {
        atnAsserted = asserted
        via1.setCA1(asserted)
    }

    // MARK: - Clock

    /// Called once per C64 cycle (985 248 Hz); runs the drive at its own 1 MHz.
    @inline(__always) public func clockC64Cycle() {
        clockAcc += 1_000_000
        while clockAcc >= 985_248 { clockAcc -= 985_248; cycleDebt += 1 }
        while cycleDebt > 0 { cpu.step() }
    }

    @inline(__always) private func tick() {
        via1.tick()
        via2.tick()
        if diskChangeCycles > 0 { diskChangeCycles -= 1 }
        if motorOn { rotate() }
        cpu.irqLine = via1.irq || via2.irq
        cycles &+= 1
        cycleDebt -= 1
    }

    @inline(__always) private func rotate() {
        byteTimer += 1
        let zone = Int(via2.portBOutput >> 5) & 3
        guard byteTimer >= 32 - 2 * zone else { return }
        byteTimer = 0
        guard let d = disk, halfTrack & 1 == 0, track <= d.trackCount else { sync = false; return }
        let tr = d.tracks[track]
        let n = tr.count
        headPos = (headPos + 1) % n
        if !via2.cb2High {
            // Write mode: the byte in VIA2 port A goes onto the disk.
            if !d.writeProtected { d.write(track: track, position: headPos, via2.ora) }
            sync = false
            byteReady()
        } else {
            let b = tr[headPos]
            if b == 0xFF && tr[(headPos + n - 1) % n] == 0xFF {
                sync = true
            } else {
                sync = false
                readLatch = b
                byteReady()
            }
        }
    }

    @inline(__always) private func byteReady() {
        via2.pulseCA1()
        if via2.ca2High { cpu.v = true }   // SO pin: BYTE READY sets the overflow flag
    }

    private func stepperMoved() {
        let phase = Int(via2.portBOutput & 3)
        let last = (halfTrack) & 3
        if phase == (last + 1) & 3 { halfTrack = min(halfTrack + 1, 84) }
        else if phase == (last + 3) & 3 { halfTrack = max(halfTrack - 1, 2) }
    }

    // MARK: - CPUBus

    public func read(_ address: UInt16) -> UInt8 {
        let a = Int(address)
        let v: UInt8
        switch a {
        case 0..<0x1800: v = ram[a & 0x7FF]
        case 0x1800..<0x1C00: v = via1.read(a)
        case 0x1C00..<0x2000: v = via2.read(a)
        case 0x8000...: v = rom[a & 0x3FFF]
        default: v = UInt8(a >> 8)
        }
        tick()
        return v
    }

    public func write(_ address: UInt16, _ value: UInt8) {
        let a = Int(address)
        switch a {
        case 0..<0x1800: ram[a & 0x7FF] = value
        case 0x1800..<0x1C00: via1.write(a, value)
        case 0x1C00..<0x2000:
            via2.write(a, value)
            if a & 0x0F == 0 || a & 0x0F == 2 { stepperMoved() }
        default: break
        }
        tick()
    }
}
