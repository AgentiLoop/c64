/// True Commodore 1541 emulation: its own 6502 running the original DOS ROM, two VIA 6522s
/// (VIA1 = serial bus, VIA2 = disk mechanics), the stepper head and a rotating GCR disk.
///
/// Given the 32 KB 1571 ROM it is a 1571: the same hardware plus a 6526 CIA for the fast serial
/// (burst) bus at $4000, a second head (side select on VIA1 PA2), a 1/2 MHz switch (PA5), the fast
/// serial direction (PA1), the track 0 sensor (PA0) and BYTE READY on PA7. The WD1770 at $2000
/// (only used for MFM / CP/M disks) is not emulated.
public final class Drive1541: CPUBus, FastSerialDevice {
    public private(set) var cpu: CPU6502<Drive1541>!
    public let via1 = VIA6522()
    public let via2 = VIA6522()
    var ram = [UInt8](repeating: 0, count: 0x800)
    let rom: [UInt8]
    unowned(unsafe) let iec: IECBus

    public private(set) var disk: GCRDisk?
    /// The 1571's second side (tracks 36–70 of a D71).
    public private(set) var disk1: GCRDisk?
    /// True for a 1571 (32 KB ROM).
    public let is1571: Bool
    /// The 1571's CIA (fast serial port); unused on a 1541.
    public let cia = CIA6526()
    /// BYTE READY as seen on the 1571's VIA1 PA7: set when a byte is complete, cleared when VIA2
    /// port A or B is accessed (as in VICE's via2d.c).
    var byteReadyLevel = false
    var halfSpeed = false
    public private(set) var halfTrack = 36
    var headPos = 0
    var byteTimer = 0
    var sync = false
    var readLatch: UInt8 = 0
    var atnAsserted = false
    var clockAcc = 0
    /// Clock of the C64 driving this drive (PAL 985 248 Hz / NTSC 1 022 727 Hz).
    public var hostClock = C64.palClock
    var cycleDebt = 0
    public private(set) var cycles: UInt64 = 0
    /// Countdown while a disk change is being signalled through the write-protect sensor.
    var diskChangeCycles = 0

    public init(rom: [UInt8], iec: IECBus) {
        precondition(rom.count == 0x4000 || rom.count == 0x8000, "1541 ROM must be 16 KB, 1571 ROM 32 KB")
        self.rom = rom
        self.iec = iec
        is1571 = rom.count == 0x8000
        cpu = CPU6502(bus: self)
        if is1571 {
            via1.portAIn = { [unowned(unsafe) self] in
                (self.byteReadyLevel ? 0 : 0x80) | 0x7E | (self.halfTrack == 2 ? 0 : 1)
            }
            cia.onSerialOut = { [unowned(unsafe) self] byte in
                if self.fastSerialOut { self.iec.driveSentFast(byte) }
            }
        }
        via1.portBIn = { [unowned(unsafe) self] in
            var v: UInt8 = 0x00          // bits 5/6 = 0: device number 8
            if !self.iec.dataLine { v |= 0x01 }
            if !self.iec.clockLine { v |= 0x04 }
            if self.atnAsserted { v |= 0x80 }
            return v
        }
        via2.portAIn = { [unowned(unsafe) self] in self.readLatch }
        via2.portBIn = { [unowned(unsafe) self] in
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
        cia.reset()
        byteReadyLevel = false
        cpu.reset()
        wake()
    }

    // MARK: - Media

    public func insert(_ d: GCRDisk, side1: GCRDisk? = nil) {
        disk = d
        disk1 = side1
        diskChangeCycles = 400_000
        wake()
    }

    @discardableResult
    public func eject() -> GCRDisk? {
        let d = disk
        disk = nil
        disk1 = nil
        diskChangeCycles = 200_000
        wake()
        return d
    }

    public var ledOn: Bool { via2.portBOutput & 0x08 != 0 }
    public var motorOn: Bool { via2.portBOutput & 0x04 != 0 }
    public var track: Int { halfTrack / 2 }
    /// 1571 head 1 selected (VIA1 PA2).
    public var side1: Bool { is1571 && via1.portAOutput & 0x04 != 0 }
    /// 1571 running at 2 MHz (VIA1 PA5).
    public var twoMHz: Bool { is1571 && via1.portAOutput & 0x20 != 0 }
    /// 1571 driving the fast serial lines (VIA1 PA1).
    var fastSerialOut: Bool { is1571 && via1.portAOutput & 0x02 != 0 }

    public func fastSerialIn(_ byte: UInt8) {
        if is1571 && !fastSerialOut { cia.receiveSerial(byte) }
    }

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

    /// Called once per C64 cycle (985 248 Hz); runs the drive at its own 1 MHz (1571: 1 or 2 MHz).
    @inline(__always) public func clockC64Cycle() {
        if iec.activity != seenActivity { seenActivity = iec.activity; wake() }
        if asleep { return }
        clockAcc += twoMHz ? 2_000_000 : 1_000_000
        while clockAcc >= hostClock { clockAcc -= hostClock; cycleDebt += 1 }
        while cycleDebt > 0 { cpu.step() }
        if motorOn || ledOn || cpu.pc < (is1571 ? 0x8000 : 0xC000) {
            idleCycles = 0
        } else {
            idleCycles += 1
            if idleCycles >= Drive1541.sleepAfter { asleep = true }
        }
    }

    /// Asleep: the drive has been idling in its ROM with motor and LED off and no host bus activity
    /// for about two seconds, so its CPU isn't run (it would only spin in the idle loop). Host bus
    /// activity (ATN, clock, data, fast serial), a disk change or a reset wakes it.
    public private(set) var asleep = false
    private var idleCycles = 0
    private var seenActivity = 0
    static let sleepAfter = 2_000_000

    private func wake() { asleep = false; idleCycles = 0 }

    @inline(__always) private func tick() {
        via1.tick()
        via2.tick()
        if is1571 {
            cia.tick()
        }
        // The disk turns at the same speed whatever the CPU clock: at 2 MHz, every other cycle.
        let rotateNow: Bool
        if twoMHz { halfSpeed.toggle(); rotateNow = halfSpeed } else { rotateNow = true }
        if rotateNow {
            if diskChangeCycles > 0 { diskChangeCycles -= 1 }
            if motorOn { rotate() }
        }
        cpu.irqLine = via1.irq || via2.irq || (is1571 && cia.irq)
        cycles &+= 1
        cycleDebt -= 1
    }

    @inline(__always) private func rotate() {
        byteTimer += 1
        let zone = Int(via2.portBOutput >> 5) & 3
        guard byteTimer >= 32 - 2 * zone else { return }
        byteTimer = 0
        guard let d = side1 ? disk1 : disk, let tr = d.track(half: halfTrack) else { sync = false; return }
        let n = tr.count
        headPos = (headPos + 1) % n
        if !via2.cb2High {
            // Write mode: the byte in VIA2 port A goes onto the disk.
            if !d.writeProtected { d.write(halfTrack: halfTrack, position: headPos, via2.ora) }
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
        byteReadyLevel = true
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
        case 0x1C00..<0x2000:
            v = via2.read(a)
            if [0, 1, 15].contains(a & 0x0F) { byteReadyLevel = false }
        case 0x8000...: v = is1571 ? rom[a & 0x7FFF] : rom[a & 0x3FFF]
        case 0x2000..<0x4000 where is1571: v = 0                        // WD1770: idle
        case 0x4000..<0x8000 where is1571: v = cia.read(a)
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
            if [0, 1, 15].contains(a & 0x0F) { byteReadyLevel = false }
            if a & 0x0F == 0 || a & 0x0F == 2 { stepperMoved() }
        case 0x4000..<0x8000 where is1571: cia.write(a, value)
        default: break
        }
        tick()
    }
}
