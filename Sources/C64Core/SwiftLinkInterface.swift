import Foundation

/// A SwiftLink-232 or Turbo232 cartridge at $DE00: a 6551 ACIA whose interrupt drives the NMI,
/// with the modem plugged into its serial port. SwiftLink runs the 6551 from a 3.6864 MHz crystal,
/// so every rate in the control register is doubled (19200 → 38,400). Turbo232 adds an enhanced
/// speed register at $DE07 for 57,600 / 115,200 / 230,400 (used when the control register asks
/// for the external clock). Register behaviour follows VICE's ACIA emulation; like VICE on a C64,
/// "no carrier" is reported in the DSR bit (the cartridge swaps DCD and DSR).
///
/// Emulator-only flow control: a byte is only handed to the C64 when the previous one has been
/// read (and RTS is asserted), and no sooner than `minReadGap` cycles after that read, so the NMI
/// handler can return before the next byte arrives. A slow program never overruns (a real 6551
/// at 230,400 baud would).
final class SwiftLinkInterface {
    /// Cycles between reading a byte and the next one arriving: enough for an NMI handler to finish.
    static let minReadGap = 80
    static let bpsTable: [Double] = [10, 50, 75, 109.92, 134.58, 150, 300, 600, 1200, 1800,
                                     2400, 3600, 4800, 7200, 9600, 19200]
    static let turboTable: [Double] = [230400, 115200, 57600, 28800]

    // Status register bits.
    static let overrun: UInt8 = 0x04, rdrf: UInt8 = 0x08, tdre: UInt8 = 0x10, noCarrier: UInt8 = 0x40

    let modem: HayesModem
    let turbo232: Bool
    /// The ACIA's interrupt output (wired to NMI).
    private(set) var irq = false

    var status = SwiftLinkInterface.tdre
    var command: UInt8 = 0
    var control: UInt8 = 0
    var enhanced: UInt8 = 0
    var rxData: UInt8 = 0
    var byteCycles = 1
    var pendingTx: UInt8?
    var txFreeAt: UInt64 = 0
    var rxNextAt: UInt64 = 0
    var txIrqAt: UInt64 = 0
    var now: UInt64 = 0

    init(modem: HayesModem, turbo232: Bool) {
        self.modem = modem
        self.turbo232 = turbo232
        updateSpeed()
    }

    func reset() {
        status = SwiftLinkInterface.tdre
        command = 0; control = 0; enhanced = 0
        irq = false
        pendingTx = nil
        updateSpeed()
    }

    var dtr: Bool { command & 0x01 != 0 }
    var rts: Bool { command & 0x0C != 0 }
    var txInterrupts: Bool { command & 0x0C == 0x04 }

    var bps: Double {
        if turbo232 && control & 0x0F == 0 { return SwiftLinkInterface.turboTable[Int(enhanced & 3)] }
        return SwiftLinkInterface.bpsTable[Int(control & 0x0F)] * 2
    }
    var dataBits: Int { 8 - Int((control >> 5) & 3) }

    private func updateSpeed() {
        let bits = dataBits + 1 + (command & 0x20 != 0 ? 1 : 0) + (control & 0x80 != 0 ? 2 : 1)
        byteCycles = max(1, Int(Double(modem.clockHz) / bps * Double(bits)))
        modem.baud = Int(bps)
    }

    // MARK: - Registers ($DE00–$DE03, Turbo232 also $DE07)

    func read(_ address: Int) -> UInt8 {
        switch address & (turbo232 ? 7 : 3) {
        case 0:
            status &= ~(0x07 | SwiftLinkInterface.rdrf)
            rxNextAt = max(rxNextAt, now &+ UInt64(SwiftLinkInterface.minReadGap))
            return rxData
        case 1:
            let v = status & 0x1F | (modem.carrier ? 0 : SwiftLinkInterface.noCarrier) | (irq ? 0x80 : 0)
            irq = false
            return v
        case 2: return command
        case 3: return control
        case 7: return enhanced | (control & 0x0F == 0 ? 0x04 : 0)
        default: return 0xFF
        }
    }

    func write(_ address: Int, _ value: UInt8) {
        switch address & (turbo232 ? 7 : 3) {
        case 0:
            guard dtr else { return }
            pendingTx = value
            status &= ~SwiftLinkInterface.tdre
        case 1:
            // Programmed reset.
            let hadDTR = dtr
            status &= ~SwiftLinkInterface.overrun
            command &= 0xE0
            irq = false
            if pendingTx != nil { pendingTx = nil; status |= SwiftLinkInterface.tdre }
            if hadDTR { modem.dtrDropped() }
        case 2:
            let hadDTR = dtr, hadTxIrq = txInterrupts
            command = value
            if hadDTR && !dtr { modem.dtrDropped() }
            if txInterrupts && !hadTxIrq { txIrqAt = now &+ UInt64(byteCycles) }
            updateSpeed()
        case 3:
            control = value
            updateSpeed()
        case 7:
            if control & 0x0F == 0 { enhanced = value & 3; updateSpeed() }
        default:
            break
        }
    }

    // MARK: - Clock

    @inline(__always) func tick(now: UInt64) {
        self.now = now
        if let byte = pendingTx, now >= txFreeAt {
            pendingTx = nil
            modem.fromC64(byte)
            txFreeAt = now &+ UInt64(byteCycles)
            status |= SwiftLinkInterface.tdre
            if txInterrupts { irq = true; txIrqAt = txFreeAt }
        }
        if txInterrupts && now >= txIrqAt {
            irq = true
            txIrqAt = now &+ UInt64(byteCycles)
        }
        if status & SwiftLinkInterface.rdrf == 0 && modem.hasOutput && now >= rxNextAt && dtr && rts {
            rxData = modem.takeOutput() & UInt8(0xFF >> (8 - dataBits))
            status |= SwiftLinkInterface.rdrf
            if command & 0x02 == 0 { irq = true }
            rxNextAt = now &+ UInt64(byteCycles)
        }
    }
}
