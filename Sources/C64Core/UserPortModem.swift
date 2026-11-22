import Foundation

/// A Hayes-compatible modem on the user port that "dials" internet hosts (telnet BBSes)
/// instead of phone numbers, like the WiFi modems people plug into real C64s today.
///
/// It is wired like the usual TTL RS-232 user-port interface the KERNAL (device 2) and terminal
/// programs expect: TXD = CIA2 PA2 (C64 → modem), RXD = CIA2 PB0 and FLAG (modem → C64),
/// DCD = PB4 (low while connected). Bytes are sent and received bit by bit, 8N1, so any program
/// that drives the user port this way works.
///
/// The host app does the networking: it handles `onDial`, `onSend` and `onHangUp`, and reports
/// back with `connected()`, `receive(_:)` and `carrierLost()`. Everything runs on the emulation thread.
public final class UserPortModem {
    public static let standardBauds = [300, 600, 1200, 2400, 4800, 9600]

    /// The C64 dialed `host:port` (ATDT); connect and answer with `connected()` or `carrierLost()`.
    public var onDial: ((String, UInt16) -> Void)?
    /// A byte from the C64 for the remote host (only while online).
    public var onSend: ((UInt8) -> Void)?
    /// The C64 hung up (ATH, ATZ, a new dial, or a key pressed while dialing).
    public var onHangUp: (() -> Void)?

    /// Line speed. The modem follows the C64: it measures the start bit of the "A" in "AT".
    public var baud = 1200 { didSet { bitCycles = max(1, clockHz / baud) } }
    var clockHz = C64.palClock { didSet { bitCycles = max(1, clockHz / baud) } }
    var bitCycles = C64.palClock / 1200

    public enum State { case command, dialing, online }
    public private(set) var state = State.command
    /// True while a call is up (also after +++ has escaped to command mode).
    public private(set) var carrier = false
    var echo = true
    var line: [UInt8] = []
    var lastCommand: [UInt8] = []
    var now: UInt64 = 0

    // Modem → C64 (RXD).
    var rxQueue: [UInt8] = []
    var rxHead = 0
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

    // "+++" escape to command mode.
    var lastTxCycle: UInt64 = 0
    var plusCount = 0
    var escapeAt: UInt64 = 0

    public init() {}

    /// Levels the modem drives onto CIA2 port B.
    var portB: UInt8 {
        var v: UInt8 = 0xFF
        if !rxd { v &= ~0x01 }
        if carrier { v &= ~0x10 }
        return v
    }

    // MARK: - Host side

    public func connected() {
        guard state == .dialing else { return }
        carrier = true
        state = .online
        plusCount = 0
        lastTxCycle = now
        respond("CONNECT \(baud)")
    }

    /// Data from the remote host, shown on the C64 while online.
    public func receive(_ bytes: [UInt8]) {
        guard state == .online else { return }
        rxQueue.append(contentsOf: bytes)
    }

    /// The connection failed or the remote host closed it.
    public func carrierLost() {
        let hadCall = carrier || state == .dialing
        carrier = false
        state = .command
        if hadCall { respond("NO CARRIER") }
    }

    /// Dials like ATDT, for a phone book on the host side.
    public func dial(host: String, port: UInt16) {
        drop()
        line = []
        send(text: "ATDT \(host):\(port)\r\n")
        state = .dialing
        onDial?(host, port)
    }

    /// Hangs up from the host side.
    public func hangUp() {
        if drop() { respond("NO CARRIER") }
    }

    // MARK: - Lines

    /// TXD (CIA2 PA2) changed.
    func setTXD(_ level: Bool, cycle: UInt64) {
        guard level != txd else { return }
        txd = level
        if !level {
            if txBit < 0 { txBit = 0; txByte = 0; txCount = bitCycles + bitCycles / 2; txFallCycle = cycle }
        } else if state != .online && line.isEmpty && txBit >= 0 && txBit <= 1 {
            // Autobaud: bit 0 of "A"/"a" is 1, so the start bit is exactly one bit long.
            let width = Int(cycle &- txFallCycle)
            if let b = UserPortModem.standardBauds.first(where: { abs(clockHz / $0 - width) * 5 < clockHz / $0 }),
               b != baud {
                baud = b
                txBit = 0
                txByte = 0
                txCount = bitCycles / 2
            }
        }
    }

    @inline(__always) func tick(_ c64: C64) {
        now = c64.cycles
        if txBit >= 0 { tickTransmit() }
        if rxBit >= 0 || rxHead < rxQueue.count { tickReceive(c64) }
        if escapeAt != 0 && now >= escapeAt {
            escapeAt = 0
            plusCount = 0
            state = .command
            respond("OK")
        }
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
            if txd { fromC64(txByte) }   // valid stop bit
        }
    }

    private func tickReceive(_ c64: C64) {
        if rxBit < 0 {
            guard roomInKernalBuffer(c64) else { return }
            rxByte = rxQueue[rxHead]
            rxHead += 1
            if rxHead == rxQueue.count { rxQueue.removeAll(keepingCapacity: true); rxHead = 0 }
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

    // MARK: - Bytes from the C64

    private func fromC64(_ byte: UInt8) {
        switch state {
        case .online:
            onSend?(byte)
            // Hayes escape: a second of quiet, "+++", a second of quiet.
            let quiet = UInt64(clockHz)
            if byte == 0x2B && plusCount < 3 && (plusCount > 0 || now &- lastTxCycle >= quiet) {
                plusCount += 1
                escapeAt = plusCount == 3 ? now + quiet : 0
            } else {
                plusCount = 0
                escapeAt = 0
            }
            lastTxCycle = now
        case .dialing:
            drop()   // any key aborts the call
            respond("NO CARRIER")
        case .command:
            commandByte(byte)
        }
    }

    private func commandByte(_ byte: UInt8) {
        if echo { rxQueue.append(byte) }
        switch byte {
        case 13:
            let l = line
            line = []
            execute(l)
        case 10:
            break
        case 0x14, 0x08, 0x7F:   // PETSCII DEL, ASCII BS/DEL
            if !line.isEmpty { line.removeLast() }
        default:
            line.append(byte)
            if line.count == 2 && UserPortModem.upper(line[0]) == 0x41 && line[1] == 0x2F {   // "A/" repeats
                line = []
                send(text: "\r\n")
                execute(lastCommand)
            } else if line.count > 80 {
                line.removeFirst()
            }
        }
    }

    /// Letters in either PETSCII case or ASCII lowercase → ASCII uppercase.
    static func upper(_ b: UInt8) -> UInt8 {
        switch b {
        case 0x61...0x7A: return b - 0x20
        case 0xC1...0xDA: return b - 0x80
        default: return b
        }
    }

    private func execute(_ raw: [UInt8]) {
        let text = String(decoding: raw.map(UserPortModem.upper).filter { $0 < 0x80 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return }
        guard text.hasPrefix("AT") else { respond("ERROR"); return }
        lastCommand = raw
        var rest = Substring(text.dropFirst(2))
        func number() -> Int? {
            let digits = rest.prefix { $0.isNumber }
            rest = rest.dropFirst(digits.count)
            return Int(digits)
        }
        while let c = rest.first {
            rest = rest.dropFirst()
            switch c {
            case "D":
                if rest.first == "T" || rest.first == "P" { rest = rest.dropFirst() }
                let target = rest.filter { $0 != " " && $0 != "\"" }.lowercased()
                var host = target
                var port: UInt16 = 23
                if let colon = target.lastIndex(of: ":"), let p = UInt16(target[target.index(after: colon)...]) {
                    host = String(target[..<colon])
                    port = p
                }
                guard !host.isEmpty else { respond("ERROR"); return }
                drop()
                state = .dialing
                onDial?(host, port)
                return
            case "O":
                _ = number()
                if carrier { state = .online; respond("CONNECT \(baud)") } else { respond("NO CARRIER") }
                return
            case "H":
                _ = number()
                drop()
            case "Z":
                _ = number()
                drop()
                echo = true
            case "E":
                echo = (number() ?? 0) != 0
            case "I":
                _ = number()
                respond("C64 USER PORT MODEM (TELNET), \(baud) BAUD")
            default:
                // Accept other settings (V1, Q0, &C1, S0=0…) so terminal init strings get an OK.
                rest = rest.drop { $0.isNumber || $0 == "=" || $0 == "?" || $0 == "&" }
            }
        }
        respond("OK")
    }

    /// Ends the call or the dialing. Returns whether there was one.
    @discardableResult
    private func drop() -> Bool {
        let hadCall = carrier || state == .dialing
        if hadCall { onHangUp?() }
        carrier = false
        state = .command
        escapeAt = 0
        plusCount = 0
        return hadCall
    }

    private func respond(_ text: String) {
        send(text: "\r\n\(text)\r\n")
    }

    /// Queues ASCII text for the C64, letters as unshifted PETSCII (upper case in the default
    /// character set, lower case in the text set, matching what the user typed).
    private func send(text: String) {
        rxQueue.append(contentsOf: text.utf8.map(UserPortModem.upper))
    }
}
