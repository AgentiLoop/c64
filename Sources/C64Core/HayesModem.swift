import Foundation

/// A Hayes-compatible modem that "dials" internet hosts (telnet BBSes) instead of phone numbers,
/// like the WiFi modems people plug into real C64s today. It only deals in bytes; the interface
/// it is plugged into moves them to and from the C64: `UserPortInterface` (bit by bit on the user
/// port, 300–9600 baud) or `SwiftLinkInterface` (a 6551 ACIA cartridge, up to 38,400 / 230,400).
///
/// The host app does the networking: it handles `onDial`, `onSend` and `onHangUp`, and reports
/// back with `connected()`, `receive(_:)` and `carrierLost()`. Everything runs on the emulation thread.
public final class HayesModem {
    /// The C64 dialed `host:port` (ATDT); connect and answer with `connected()` or `carrierLost()`.
    public var onDial: ((String, UInt16) -> Void)?
    /// A byte from the C64 for the remote host (only while online).
    public var onSend: ((UInt8) -> Void)?
    /// The C64 hung up (ATH, ATZ, DTR dropped, a new dial, or a key pressed while dialing).
    public var onHangUp: (() -> Void)?

    /// Line speed, set by the interface (shown in CONNECT).
    public var baud = 1200
    var clockHz = C64.palClock

    public enum State { case command, dialing, online }
    public private(set) var state = State.command
    /// True while a call is up (also after +++ has escaped to command mode).
    public private(set) var carrier = false
    var echo = true
    var line: [UInt8] = []
    var lastCommand: [UInt8] = []
    var now: UInt64 = 0

    /// Bytes waiting to go to the C64.
    var output: [UInt8] = []
    var outputHead = 0

    // "+++" escape to command mode.
    var lastTxCycle: UInt64 = 0
    var plusCount = 0
    var escapeAt: UInt64 = 0

    public init() {}

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
        output.append(contentsOf: bytes)
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

    // MARK: - Interface side

    var hasOutput: Bool { outputHead < output.count }

    /// Takes the next byte for the C64 (check `hasOutput` first).
    func takeOutput() -> UInt8 {
        let b = output[outputHead]
        outputHead += 1
        if outputHead == output.count { output.removeAll(keepingCapacity: true); outputHead = 0 }
        return b
    }

    @inline(__always) func tick(now: UInt64) {
        self.now = now
        if escapeAt != 0 && now >= escapeAt {
            escapeAt = 0
            plusCount = 0
            state = .command
            respond("OK")
        }
    }

    /// The C64 dropped DTR (how SwiftLink terminals hang up).
    func dtrDropped() {
        if drop() { respond("NO CARRIER") }
    }

    /// A byte from the C64.
    func fromC64(_ byte: UInt8) {
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

    // MARK: - Commands

    private func commandByte(_ byte: UInt8) {
        if echo { output.append(byte) }
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
            if line.count == 2 && HayesModem.upper(line[0]) == 0x41 && line[1] == 0x2F {   // "A/" repeats
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
        let text = String(decoding: raw.map(HayesModem.upper).filter { $0 < 0x80 }, as: UTF8.self)
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
                respond("C64 MODEM (TELNET), \(baud) BAUD")
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
        output.append(contentsOf: text.utf8.map(HayesModem.upper))
    }
}
