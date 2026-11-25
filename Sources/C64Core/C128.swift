import Foundation

/// The C128's own ROMs (C128 mode): 16K KERNAL + screen editor at $C000, BASIC 7.0 low ($4000) and
/// high ($8000), and the 8K character ROM.
public struct C128ROMs {
    public var kernal: [UInt8]
    public var basicLo: [UInt8]
    public var basicHi: [UInt8]
    public var chargen: [UInt8]
    public init(kernal: [UInt8], basicLo: [UInt8], basicHi: [UInt8], chargen: [UInt8]) {
        self.kernal = kernal; self.basicLo = basicLo; self.basicHi = basicHi; self.chargen = chargen
    }
}

/// C128 mode: the 8722 MMU with 128K RAM (two 64K banks), common RAM and page-0/1 relocation,
/// the C128 ROMs, and just enough of the 8563 VDC for the KERNAL to initialise it (no 80-column
/// picture: the machine boots in 40-column mode on the VIC-II). As on the real machine the Z80
/// starts first, runs its boot BIOS and hands the bus to the 8502 through MMU $D505 bit 0.
final class C128Memory {
    let roms: C128ROMs
    /// RAM bank 1 and the ROMs in fixed storage (read on nearly every cycle).
    let ram1 = Memory(count: 0x10000)
    let kernal: Memory, basicLo: Memory, basicHi: Memory, chargen: Memory
    /// Configuration register ($D500 / $FF00) and the four preconfiguration registers.
    var cr: UInt8 = 0
    var pcr = [UInt8](repeating: 0, count: 4)
    var mcr: UInt8 = 0
    var rcr: UInt8 = 0
    var p0l: UInt8 = 0, p0h: UInt8 = 0, p1l: UInt8 = 1, p1h: UInt8 = 0
    var p0hLatch: UInt8 = 0, p1hLatch: UInt8 = 0
    /// Set when the MMU mode register selects C64 mode; the machine then restarts as a C64.
    var go64Requested = false
    /// The 40/80 DISPLAY key (down = start in 80 columns).
    var key4080Down = false
    /// 2 MHz mode (VIC-II register $D030 bit 0, BASIC's FAST): the CPU gets two cycles per VIC cycle.
    var fast = false
    var halfCycle = false
    /// The Z80 (CP/M and the power-on code). It has the bus while MMU $D505 bit 0 is 0.
    public let z80 = Z80()
    var z80Debt = 0
    /// The 8502 has not run since reset: its reset vector is fetched when the Z80 first hands over.
    var needs8502Reset = true
    public var z80Active: Bool { mcr & 1 == 0 }
    /// GAME (bit 4) and EXROM (bit 5) from the expansion port as read in $D505 (1 = not pulled low).
    var cartLines: UInt8 = 0x30
    /// VIC-IIe $D02F: K0–K2 drive the extra keyboard lines (0 = scanned).
    var keyLines: UInt8 = 0xFF
    /// The 8563 VDC (80-column chip).
    public let vdc = VDC8563()
    /// The KERNAL's active screen is the 80-column one: bit 7 of MODE ($D7) as the ROMs last wrote
    /// it. A program running from RAM may use $D7 for its own data, so its writes are not followed.
    var mode80 = false
    /// A program running from RAM has written to the VDC ($D601).
    var programUsesVDC = false
    /// The 32K ROM in the internal function ROM socket (U36), seen at $8000–$FFFF; nil = empty socket.
    private(set) var functionROM: Memory?

    init(roms: C128ROMs) {
        self.roms = roms
        kernal = Memory(roms.kernal); basicLo = Memory(roms.basicLo)
        basicHi = Memory(roms.basicHi); chargen = Memory(roms.chargen)
    }

    deinit {
        for m in [ram1, kernal, basicLo, basicHi, chargen] { m.deallocate() }
        functionROM?.deallocate()
    }

    func setFunctionROM(_ bytes: [UInt8]?) {
        functionROM?.deallocate()
        functionROM = bytes.map { Memory($0) }
    }

    func reset() {
        cr = 0; pcr = [0, 0, 0, 0]; mcr = 0; rcr = 0; fast = false; halfCycle = false; keyLines = 0xFF
        z80.reset(); z80Debt = 0; needs8502Reset = true
        mode80 = false; programUsesVDC = false
        vdc.reset()
        p0l = 0; p0h = 0; p1l = 1; p1h = 0; p0hLatch = 0; p1hLatch = 0
        for i in 0..<ram1.count { ram1[i] = (i & 0x40) != 0 ? 0xFF : 0x00 }
    }

    /// Physical RAM location (bank, address) of a CPU address, after relocation and common RAM.
    @inline(__always) func locate(_ a: Int) -> (Int, Int) {
        let page = a >> 8
        if page == 0 { return (Int(p0h & 1), Int(p0l) << 8 | (a & 0xFF)) }
        if page == 1 { return (Int(p1h & 1), Int(p1l) << 8 | (a & 0xFF)) }
        var bank = Int(cr >> 6) & 1
        if bank == Int(p0h & 1) && page == Int(p0l) { return (0, a & 0xFF) }          // swapped with page 0
        if bank == Int(p1h & 1) && page == Int(p1l) { return (0, 0x100 | (a & 0xFF)) }  // swapped with page 1
        let size: Int
        switch rcr & 3 { case 0: size = 0x400; case 1: size = 0x1000; case 2: size = 0x2000; default: size = 0x4000 }
        if (rcr & 4 != 0 && a < size) || (rcr & 8 != 0 && a >= 0x10000 - size) { bank = 0 }
        return (bank, a)
    }

    func mmuRead(_ reg: Int) -> UInt8 {
        switch reg {
        case 0: return cr
        case 1...4: return pcr[reg - 1]
        case 5: return (mcr & 0x09) | (key4080Down ? 0 : 0x80) | cartLines | 0x06   // C64 cartridge lines
        case 6: return rcr | 0x30
        case 7: return p0l
        case 8: return p0h | 0xF0
        case 9: return p1l
        case 10: return p1h | 0xF0
        case 11: return 0x20                                 // 128K, MMU revision 0
        default: return 0xFF
        }
    }

    func mmuWrite(_ reg: Int, _ v: UInt8) {
        switch reg {
        case 0: cr = v
        case 1...4: pcr[reg - 1] = v
        case 5:
            mcr = v
            if v & 0x40 != 0 { go64Requested = true }          // GO64: switch to C64 mode
        case 6: rcr = v
        case 7: p0l = v; p0h = p0hLatch
        case 8: p0hLatch = v & 0x0F
        case 9: p1l = v; p1h = p1hLatch
        case 10: p1hLatch = v & 0x0F
        default: break
        }
    }

}

extension C64 {
    /// Commodore 128 (C128 mode) when its ROMs are given, the C64 when nil. Resets the machine.
    public func setC128(_ roms: C128ROMs?) {
        c128 = roms.map(C128Memory.init)
        c128?.setFunctionROM(functionROM)
        if let m = c128 { wireZ80(m) }
        c128?.vdc.clockHz = clockHz
        wireFastSerial()
        setDrive8Is1571(c128 != nil || use1571OnC64)          // a C128 has a 1571 (C128D); a C64 a 1541
        reset()
    }

    public var isC128: Bool { c128 != nil }

    /// Puts a 32K ROM into the C128's internal function ROM socket (nil empties it) and resets the
    /// machine. At power-on the KERNAL finds it by the "CBM" signature and starts it.
    public func setFunctionROM(_ rom: [UInt8]?) {
        functionROM = rom
        c128?.setFunctionROM(rom)
        reset()
    }

    /// A 32K image with the "CBM" signature the C128 KERNAL looks for at $8007 or $C007.
    public static func isFunctionROM(_ bytes: [UInt8]) -> Bool {
        bytes.count == 0x8000 && [0x0007, 0x4007].contains { Array(bytes[$0..<$0 + 3]) == [0x43, 0x42, 0x4D] }
    }

    /// C128 fast serial: CIA1's serial port is connected to the bus (SP = DATA, CNT = SRQ), its
    /// direction set by MMU $D505 bit 3 (FSDIR, 1 = output). The C64 has no such connection.
    func wireFastSerial() {
        if let m = c128 {
            cia1.onSerialOut = { [unowned(unsafe) self, unowned(unsafe) m] byte in
                if m.mcr & 0x08 != 0 { self.iec.hostSentFast(byte) }
            }
            iec.hostFastSerialIn = { [unowned(unsafe) self, unowned(unsafe) m] byte in
                if m.mcr & 0x08 == 0 { self.cia1.receiveSerial(byte) }
            }
        } else {
            cia1.onSerialOut = nil
            iec.hostFastSerialIn = nil
        }
    }

    /// Finishes a GO64: the C128 ROMs and MMU go away and the machine restarts as a C64.
    func checkGo64() {
        guard let m = c128, m.go64Requested else { return }
        c128 = nil
        wireFastSerial()
        // Drive 8 stays as it is: a C128D's 1571 is still a 1571 in C64 mode (the disk stays in too).
        reset()
        onModelChanged?()
    }

    @inline(__always) func ramRead128(_ m: C128Memory, _ a: Int) -> UInt8 {
        let (bank, addr) = m.locate(a)
        return bank == 0 ? ram[addr] : m.ram1[addr]
    }

    func peek128(_ m: C128Memory, _ a: Int) -> UInt8 {
        if a >= 0xFF00 && a <= 0xFF04 { return m.mmuRead(a & 0xFF) }
        if a >= 0xD000 && a < 0xE000 && m.cr & 1 == 0 { return ioRead128(m, a) }
        return memRead128(m, a)
    }

    /// The I/O chips at $D000–$DFFF (8502 with I/O banked in, or Z80 IN).
    func ioRead128(_ m: C128Memory, _ a: Int) -> UInt8 {
        switch a >> 8 {
        case 0xD4: return sid.read(a & 0x1F)
        case 0xD5: return m.mmuRead(a & 0xFF)
        case 0xD6: return m.vdc.read(a)
        case 0xD7: return 0xFF
        case 0xD0 where a & 0x3F == 0x30: return 0xFC | (m.fast ? 1 : 0)
        case 0xD0 where a & 0x3F == 0x2F: return 0xF8 | m.keyLines
        default: return readIO(a)
        }
    }

    /// ROM or RAM as selected by the configuration register (no I/O).
    func memRead128(_ m: C128Memory, _ a: Int) -> UInt8 {
        let cr = m.cr
        switch a {
        case 0x4000..<0x8000:
            if cr & 0x02 == 0 { return m.basicLo[a - 0x4000] }
        case 0x8000..<0xC000:
            switch (cr >> 2) & 3 {
            case 0: return m.basicHi[a - 0x8000]
            case 1: return m.functionROM?[a - 0x8000] ?? 0xFF  // internal function ROM
            case 3: break
            default: return 0xFF                              // no external function ROM
            }
        case 0xC000...0xFFFF:
            switch (cr >> 4) & 3 {
            case 0:
                if a >> 12 == 0xD { return m.chargen[a & 0x0FFF] }
                return m.kernal[a - 0xC000]
            case 1: return m.functionROM?[a - 0x8000] ?? 0xFF
            case 3: break
            default: return 0xFF
            }
        default:
            break
        }
        return ramRead128(m, a)
    }

    func poke128(_ m: C128Memory, _ a: Int, _ v: UInt8) {
        if a == 0xFF00 { m.cr = v; return }
        if a >= 0xFF01 && a <= 0xFF04 { m.cr = m.pcr[a - 0xFF01]; return }   // load a preset
        if a >= 0xD000 && a < 0xE000 && m.cr & 1 == 0 { ioWrite128(m, a, v); return }
        let (bank, addr) = m.locate(a)                         // writes always reach RAM
        if bank == 0 {
            ram[addr] = v
            if addr == 0xD7 && runningROM128(m) { m.mode80 = v & 0x80 != 0 }
        } else {
            m.ram1[addr] = v
        }
    }

    func ioWrite128(_ m: C128Memory, _ a: Int, _ v: UInt8) {
        switch a >> 8 {
        case 0xD4: sid.write(a & 0x1F, v)
        case 0xD5: m.mmuWrite(a & 0xFF, v)
        case 0xD6:
            if a & 1 != 0 && !runningROM128(m) { m.programUsesVDC = true }
            m.vdc.write(a, v)
        case 0xD7: break
        case 0xD0 where a & 0x3F == 0x30: m.fast = v & 1 != 0
        case 0xD0 where a & 0x3F == 0x2F: m.keyLines = v | 0xF8
        default: writeIO(a, v)
        }
    }

    @inline(__always) func ramWrite128(_ m: C128Memory, _ a: Int, _ v: UInt8) {
        let (bank, addr) = m.locate(a)
        if bank == 0 { ram[addr] = v } else { m.ram1[addr] = v }
    }

    // MARK: - Z80 bus

    /// Z80 memory: in bank 0 the boot BIOS (KERNAL ROM $D000–$DFFF) at $0000–$0FFF, colour RAM at
    /// $1000–$13FF while I/O is on, RAM (never I/O or character ROM) at $D000–$DFFF, otherwise the
    /// same ROMs and RAM the 8502 sees.
    func z80Read(_ m: C128Memory, _ a: Int) -> UInt8 {
        if a >= 0xFF00 && a <= 0xFF04 { return m.mmuRead(a & 0xFF) }
        if a < 0x1000 && m.cr & 0x40 == 0 { return m.kernal[0x1000 + a] }
        if a & 0xFC00 == 0x1000 && m.cr & 1 == 0 { return readIO(0xD800 | (a & 0x3FF)) & 0x0F }
        if a >> 12 == 0xD { return ramRead128(m, a) }
        return memRead128(m, a)
    }

    func z80Write(_ m: C128Memory, _ a: Int, _ v: UInt8) {
        if a >= 0xFF00 && a <= 0xFF04 { poke128(m, a, v); return }
        if a < 0x1000 && m.cr & 0x40 == 0 { ramWrite128(m, 0xD000 | a, v); return }
        if a & 0xFC00 == 0x1000 && m.cr & 1 == 0 { writeIO(0xD800 | (a & 0x3FF), v); return }
        ramWrite128(m, a, v)
    }

    /// Z80 I/O space: the chips at $D000–$DFFF (the MMU only while its I/O bit is on), RAM
    /// $D000–$DFFF through ports $0000–$0FFF in bank 0; anything else reads memory.
    func z80In(_ m: C128Memory, _ port: Int) -> UInt8 {
        if port < 0x1000 {
            return m.cr & 0x40 != 0 ? z80Read(m, port) : ramRead128(m, 0xD000 | port)
        }
        if port >> 8 == 0xD5 { return m.cr & 1 != 0 ? 0 : m.mmuRead(port & 0xFF) }
        if port >> 12 == 0xD { return ioRead128(m, port) }
        return z80Read(m, port)
    }

    func z80Out(_ m: C128Memory, _ port: Int, _ v: UInt8) {
        if port < 0x1000 {
            if m.cr & 0x40 != 0 { z80Write(m, port, v) } else { ramWrite128(m, 0xD000 | port, v) }
            return
        }
        if port >> 8 == 0xD5 { if m.cr & 1 == 0 { m.mmuWrite(port & 0xFF, v) }; return }
        if port >> 12 == 0xD { ioWrite128(m, port, v); return }
        z80Write(m, port, v)
    }

    /// Runs one Z80 instruction while the Z80 has the bus (MMU $D505 bit 0 = 0). The Z80 gets two
    /// T-states per 1 MHz system cycle (its 4 MHz clock is stretched on every bus access) and,
    /// like the 8502, stops while the VIC-II takes the bus.
    func stepZ80(_ m: C128Memory) {
        let z = m.z80
        while vic.blocksCPU(write: false) { clock() }
        z.intLine = vic.irq || cia1.irq
        m.z80Debt += z.step()
        while m.z80Debt >= 2 { m.z80Debt -= 2; clock() }
    }

    /// Hooks the Z80 up to the C128 bus.
    func wireZ80(_ m: C128Memory) {
        let z = m.z80
        z.readMem = { [unowned(unsafe) self, unowned(unsafe) m] a in self.z80Read(m, Int(a)) }
        z.writeMem = { [unowned(unsafe) self, unowned(unsafe) m] a, v in self.z80Write(m, Int(a), v) }
        z.readIO = { [unowned(unsafe) self, unowned(unsafe) m] a in self.z80In(m, Int(a)) }
        z.writeIO = { [unowned(unsafe) self, unowned(unsafe) m] a, v in self.z80Out(m, Int(a), v) }
    }

    /// True while the 8502 is executing ROM (KERNAL, screen editor or BASIC), not a program in RAM.
    func runningROM128(_ m: C128Memory) -> Bool {
        switch Int(cpu.pc) {
        case 0x4000..<0x8000: return m.cr & 0x02 == 0
        case 0x8000..<0xC000: return m.cr & 0x0C == 0
        case 0xC000...0xFFFF: return m.cr & 0x30 == 0
        default: return false
        }
    }

    /// What the VIC-II sees: the RAM bank chosen in the MMU's RAM configuration register, and the
    /// character ROM at $1000 in VIC banks 0 and 2 while port bit 2 is LOW,
    /// the opposite polarity to the C64. The US ROM's lower 4K (with CAPS LOCK up) is the standard set.
    func vicRead128(_ m: C128Memory, _ addr: Int) -> UInt8 {
        if !charen && vicBank & 1 == 0 && addr & 0x3000 == 0x1000 { return m.chargen[addr & 0x0FFF] }
        let full = vicBank << 14 | addr
        return m.rcr & 0x40 == 0 ? ram[full] : m.ram1[full]
    }
}
