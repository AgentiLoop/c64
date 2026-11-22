import Foundation
import Network
import C64Core

/// Plugs the user-port modem into the internet: ATDT host:port opens a TCP (telnet) connection.
/// Modem callbacks arrive on the emulation thread; network events go back to it via `runner.perform`.
/// All connection state lives on `queue`.
final class ModemLink {
    private let runner: EmulatorRunner
    private let queue = DispatchQueue(label: "C64 modem")
    private var telnet: TelnetConnection?
    /// Called on the main thread with the host while connected, nil when not.
    var onStatus: ((String?) -> Void)?

    init(runner: EmulatorRunner) {
        self.runner = runner
        let modem = UserPortModem()
        modem.onDial = { [weak self] host, port in self?.queue.async { self?.connect(host, port) } }
        modem.onSend = { [weak self] byte in self?.queue.async { self?.telnet?.send([byte]) } }
        modem.onHangUp = { [weak self] in self?.queue.async { self?.close() } }
        runner.perform { $0.modem = modem }
    }

    /// Dials from the Mac side (phone book).
    func dial(host: String, port: UInt16) { runner.perform { $0.modem?.dial(host: host, port: port) } }
    func hangUp() { runner.perform { $0.modem?.hangUp() } }

    private func connect(_ host: String, _ port: UInt16) {
        close()
        let t = TelnetConnection(host: host, port: port, queue: queue)
        telnet = t
        t.onReady = { [weak self] in
            self?.runner.perform { $0.modem?.connected() }
            DispatchQueue.main.async { self?.onStatus?("\(host):\(port)") }
        }
        t.onData = { [weak self] bytes in self?.runner.perform { $0.modem?.receive(bytes) } }
        t.onClose = { [weak self, weak t] in
            guard let self, self.telnet === t else { return }
            self.telnet = nil
            self.runner.perform { $0.modem?.carrierLost() }
            DispatchQueue.main.async { self.onStatus?(nil) }
        }
        t.start()
    }

    private func close() {
        telnet?.close()
        telnet = nil
        DispatchQueue.main.async { self.onStatus?(nil) }
    }
}

/// A TCP connection that speaks just enough telnet: option requests are answered (binary,
/// echo and suppress-go-ahead accepted, everything else refused) and IAC bytes are escaped.
/// Boards that use raw TCP work too. Callbacks run on `queue`.
final class TelnetConnection {
    var onReady: (() -> Void)?
    var onData: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var closed = false
    private var ready = false
    // Telnet parser state.
    private enum Parse { case data, iac, option(UInt8), sub, subIAC }
    private var parse = Parse.data

    private static let IAC: UInt8 = 255, WILL: UInt8 = 251, WONT: UInt8 = 252, DO: UInt8 = 253, DONT: UInt8 = 254
    private static let SB: UInt8 = 250, SE: UInt8 = 240

    init(host: String, port: UInt16, queue: DispatchQueue) {
        self.queue = queue
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 23, using: .tcp)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready = true
                self.onReady?()
                self.receive()
            case .waiting, .failed:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            if let self, !self.ready { self.finish() }   // no answer
        }
    }

    func send(_ bytes: [UInt8]) {
        guard !closed else { return }
        var out: [UInt8] = []
        for b in bytes {
            out.append(b)
            if b == TelnetConnection.IAC { out.append(b) }
        }
        connection.send(content: Data(out), completion: .contentProcessed { _ in })
    }

    func close() {
        closed = true
        connection.cancel()
    }

    private func finish() {
        guard !closed else { return }
        close()
        onClose?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                let bytes = self.filter([UInt8](data))
                if !bytes.isEmpty { self.onData?(bytes) }
            }
            if isComplete || error != nil { self.finish() } else { self.receive() }
        }
    }

    /// Strips telnet commands from the stream and answers option negotiation.
    private func filter(_ input: [UInt8]) -> [UInt8] {
        typealias T = TelnetConnection
        var out: [UInt8] = []
        var reply: [UInt8] = []
        for b in input {
            switch parse {
            case .data:
                if b == T.IAC { parse = .iac } else { out.append(b) }
            case .iac:
                switch b {
                case T.IAC: out.append(b); parse = .data
                case T.WILL, T.WONT, T.DO, T.DONT: parse = .option(b)
                case T.SB: parse = .sub
                default: parse = .data
                }
            case .option(let verb):
                // 0 = binary, 1 = echo, 3 = suppress go-ahead.
                if verb == T.WILL { reply += [T.IAC, [0, 1, 3].contains(b) ? T.DO : T.DONT, b] }
                if verb == T.DO { reply += [T.IAC, [0, 3].contains(b) ? T.WILL : T.WONT, b] }
                parse = .data
            case .sub:
                if b == T.IAC { parse = .subIAC }
            case .subIAC:
                parse = b == T.SE ? .data : .sub
            }
        }
        if !reply.isEmpty { connection.send(content: Data(reply), completion: .contentProcessed { _ in }) }
        return out
    }
}
