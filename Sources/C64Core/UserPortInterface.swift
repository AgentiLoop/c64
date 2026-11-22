import Foundation

/// The modem on the user port, wired like the usual TTL RS-232 interface the KERNAL (device 2) and
/// terminal programs expect: TXD = CIA2 PA2 (C64 → modem), RXD = CIA2 PB0 and FLAG (modem → C64),
/// DCD = PB4 (low while connected). Bytes are sent and received bit by bit, 8N1, so any program that
/// drives the user port this way works. The speed follows the C64: the start bit of the "A" in "AT"
/// is measured.
final class UserPortInterface {
    static let standardBauds = [300, 600, 1200, 2400, 4800, 9600]

    let modem: HayesModem
    var bitCycles: Int { max(1, modem.clockHz / modem.baud) }

    // Modem → C64 (RXD).
    var rxd = true
    var rxBit = -1
    var rxCount = 0
    var rxByte: UInt8 = 0

    // C64 → modem (TXD).
    var txd = true
    var txBit = -1
    var txCount = 0
    var txByte: UInt8 = 0
    var txFallCycle: UInt64 = 0

    init(modem: HayesModem) { self.modem = modem }

    /// Levels the modem drives onto CIA2 port B.
    var portB: UInt8 {
        var v: UInt8 = 0xFF
        if !rxd { v &= ~0x01 }
        if modem.carrier { v &= ~0x10 }
        return v
    }

    /// TXD (CIA2 PA2) changed.
    func setTXD(_ level: Bool, cycle: UInt64) {
        guard level != txd else { return }
        txd = level
        if !level {
            if txBit < 0 { txBit = 0; txByte = 0; txCount = bitCycles + bitCycles / 2; txFallCycle = cycle }
        } else if modem.state != .online && modem.line.isEmpty && txBit >= 0 && txBit <= 1 {
            // Autobaud: bit 0 of "A"/"a" is 1, so the start bit is exactly one bit long.
            let width = Int(cycle &- txFallCycle)
            let hz = modem.clockHz
            if let b = UserPortInterface.standardBauds.first(where: { abs(hz / $0 - width) * 5 < hz / $0 }),
               b != modem.baud {
                modem.baud = b
                txBit = 0
                txByte = 0
                txCount = bitCycles / 2
            }
        }
    }

    @inline(__always) func tick(_ c64: C64) {
        if txBit >= 0 { tickTransmit() }
        if rxBit >= 0 || modem.hasOutput { tickReceive(c64) }
    }

    private func tickTransmit() {
        txCount -= 1
        guard txCount <= 0 else { return }
        if txBit < 8 {
            if txd { txByte |= 1 << txBit }
            txBit += 1
            txCount = bitCycles
        } else {
            txBit = -1
            if txd { modem.fromC64(txByte) }   // valid stop bit
        }
    }

    private func tickReceive(_ c64: C64) {
        if rxBit < 0 {
            guard roomInKernalBuffer(c64) else { return }
            rxByte = modem.takeOutput()
            setRXD(false, c64)   // start bit
            rxBit = 0
            rxCount = bitCycles
            return
        }
        rxCount -= 1
        guard rxCount <= 0 else { return }
        if rxBit < 8 {
            setRXD(rxByte & (1 << rxBit) != 0, c64)
            rxBit += 1
            rxCount = bitCycles
        } else if rxBit == 8 {
            setRXD(true, c64)   // stop bit, plus one bit of idle line
            rxBit = 9
            rxCount = bitCycles * 2
        } else {
            rxBit = -1
        }
    }

    /// RXD is also wired to FLAG, so every falling edge sets the CIA's FLAG interrupt, as on the real port.
    private func setRXD(_ level: Bool, _ c64: C64) {
        if rxd && !level { c64.cia2.triggerFlag() }
        rxd = level
    }

    /// Emulator-only flow control: waits while the KERNAL's 256-byte RS-232 input buffer is nearly
    /// full (a BASIC terminal can't keep up with 1200 baud), instead of letting it overflow.
    private func roomInKernalBuffer(_ c64: C64) -> Bool {
        guard c64.ram[0xF7] != 0 || c64.ram[0xF8] != 0 else { return true }   // RIBUF not set up
        let used = (Int(c64.ram[0x29B]) - Int(c64.ram[0x29C])) & 0xFF        // RIDBE - RIDBS
        return used < 200
    }
}
