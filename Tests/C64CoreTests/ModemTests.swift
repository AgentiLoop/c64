import XCTest
@testable import C64Core

/// Runs the bundled terminal (Resources/TERM.PRG) against the modem on each interface.
final class ModemTests: XCTestCase {
    var dialed: (String, UInt16)?
    var sent: [UInt8] = []
    var hungUp = 0

    func makeMachine(_ port: C64.ModemPort = .userPort) throws -> (C64, HayesModem) {
        guard let roms = ROMSet.load() else { throw XCTSkip("C64 ROMs not installed") }
        let c64 = C64(roms: roms)
        let modem = HayesModem()
        modem.baud = 2400   // on the user port the terminal runs at 1200; the modem must pick that up from "AT"
        modem.onDial = { [unowned self] in self.dialed = ($0, $1) }
        modem.onSend = { [unowned self] in self.sent.append($0) }
        modem.onHangUp = { [unowned self] in self.hungUp += 1 }
        c64.modemPort = port
        c64.modem = modem
        for _ in 0..<150 { c64.runFrame() }
        let prg = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../Resources/TERM.PRG"))
        c64.loadPRG([UInt8](prg))
        c64.ram[0x0810] = [.userPort: 0, .swiftLink: 1, .turbo232: 2][port] ?? 0   // what the app does
        c64.typeIntoBuffer("RUN\n")
        return (c64, modem)
    }

    func screen(_ c64: C64) -> String { c64.screenText().joined(separator: "\n") }

    func run(_ c64: C64, until text: String, frames: Int = 300) -> Bool {
        for _ in 0..<frames {
            c64.runFrame()
            if screen(c64).contains(text) { return true }
        }
        return false
    }

    /// Greeting, dialing, a long burst with nothing lost, typing, F7 hang-up, carrier loss.
    func callBBS(_ port: C64.ModemPort, baud: Int) throws {
        let (c64, modem) = try makeMachine(port)
        XCTAssertTrue(run(c64, until: "OK"), screen(c64))
        XCTAssertEqual(modem.baud, baud)

        c64.queueTyping("ATDT bbs.example.com:6400\n")
        for _ in 0..<200 where dialed == nil { c64.runFrame() }
        XCTAssertEqual(dialed?.0, "bbs.example.com")
        XCTAssertEqual(dialed?.1, 6400)
        XCTAssertTrue(run(c64, until: "ATDT BBS.EXAMPLE.COM:6400"), screen(c64))   // echo

        modem.connected()
        XCTAssertTrue(run(c64, until: "CONNECT \(baud)"), screen(c64))

        // A long burst from the "BBS" (PETSCII clear screen first): flow control must keep it intact.
        let lines = (1...20).map { "LINE \($0) OF THE WELCOME SCREEN.........." }
        modem.receive([0x93] + Array((lines.joined(separator: "\r") + "\r").utf8))
        XCTAssertTrue(run(c64, until: lines.last!, frames: 2000), screen(c64))
        for l in lines.suffix(15) { XCTAssertTrue(screen(c64).contains(l), "missing \(l)\n" + screen(c64)) }

        sent = []
        c64.queueTyping("HI\n")
        for _ in 0..<100 where sent.count < 3 { c64.runFrame() }
        XCTAssertEqual(sent, [0x48, 0x49, 13])

        // F7: a second of quiet, "+++", a second of quiet, "ATH".
        c64.setKey(.f7, pressed: true)
        for _ in 0..<4 { c64.runFrame() }
        c64.setKey(.f7, pressed: false)
        for _ in 0..<300 where hungUp == 0 { c64.runFrame() }
        XCTAssertEqual(hungUp, 1)
        XCTAssertFalse(modem.carrier)
        XCTAssertEqual(modem.state, .command)

        // Calling again and losing the carrier shows NO CARRIER.
        modem.dial(host: "bbs.example.com", port: 6400)
        modem.connected()
        for _ in 0..<20 { c64.runFrame() }
        modem.carrierLost()
        XCTAssertTrue(run(c64, until: "NO CARRIER"), screen(c64))
    }

    func testTerminalOnUserPort() throws { try callBBS(.userPort, baud: 1200) }
    func testTerminalOnSwiftLink() throws { try callBBS(.swiftLink, baud: 38400) }
    func testTerminalOnTurbo232() throws { try callBBS(.turbo232, baud: 230400) }

    func testEscapeAndHangUp() throws {
        let (c64, modem) = try makeMachine()
        XCTAssertTrue(run(c64, until: "OK"), screen(c64))
        c64.queueTyping("ATD host\n")
        for _ in 0..<200 where dialed == nil { c64.runFrame() }
        XCTAssertEqual(dialed?.0, "host")
        XCTAssertEqual(dialed?.1, 23)
        modem.connected()
        for _ in 0..<100 { c64.runFrame() }   // more than a second of quiet
        c64.queueTyping("+++")
        for _ in 0..<150 { c64.runFrame() }
        XCTAssertEqual(modem.state, .command)
        XCTAssertTrue(modem.carrier)
        c64.queueTyping("ATH\n")
        for _ in 0..<100 where hungUp == 0 { c64.runFrame() }
        XCTAssertEqual(hungUp, 1)
        XCTAssertFalse(modem.carrier)
    }
}
