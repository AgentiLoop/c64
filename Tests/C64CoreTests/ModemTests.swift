import XCTest
@testable import C64Core

/// Runs the bundled BASIC terminal (KERNAL RS-232 on the user port) against the modem.
final class ModemTests: XCTestCase {
    var dialed: (String, UInt16)?
    var sent: [UInt8] = []
    var hungUp = 0

    func makeMachine() throws -> (C64, UserPortModem) {
        guard let roms = ROMSet.load() else { throw XCTSkip("C64 ROMs not installed") }
        let c64 = C64(roms: roms)
        let modem = UserPortModem()
        modem.baud = 2400   // the terminal runs at 1200; the modem must pick that up from "AT"
        modem.onDial = { [unowned self] in self.dialed = ($0, $1) }
        modem.onSend = { [unowned self] in self.sent.append($0) }
        modem.onHangUp = { [unowned self] in self.hungUp += 1 }
        c64.modem = modem
        for _ in 0..<150 { c64.runFrame() }
        let prg = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../Resources/TERM.PRG"))
        c64.loadPRG([UInt8](prg))
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

    func testTerminalDialsAndTalks() throws {
        let (c64, modem) = try makeMachine()
        // The terminal sends "AT" on start: the modem switches to 1200 baud and answers OK.
        XCTAssertTrue(run(c64, until: "OK"), screen(c64))
        XCTAssertEqual(modem.baud, 1200)

        c64.queueTyping("ATDT bbs.example.com:6400\n")
        for _ in 0..<200 where dialed == nil { c64.runFrame() }
        XCTAssertEqual(dialed?.0, "bbs.example.com")
        XCTAssertEqual(dialed?.1, 6400)
        XCTAssertTrue(screen(c64).contains("ATDT BBS.EXAMPLE.COM:6400"), screen(c64))   // echo

        modem.connected()
        XCTAssertTrue(run(c64, until: "CONNECT 1200"), screen(c64))

        // A long burst from the "BBS": flow control must keep the BASIC terminal from losing bytes.
        let lines = (1...12).map { "LINE \($0) OF THE WELCOME SCREEN.........." }
        modem.receive(Array((lines.joined(separator: "\r") + "\r").utf8))
        XCTAssertTrue(run(c64, until: lines.last!, frames: 1500), screen(c64))
        for l in lines.suffix(8) { XCTAssertTrue(screen(c64).contains(l), "missing \(l)\n" + screen(c64)) }

        c64.queueTyping("HI\n")
        for _ in 0..<100 where sent.count < 3 { c64.runFrame() }
        XCTAssertEqual(sent, [0x48, 0x49, 13])

        modem.carrierLost()
        XCTAssertTrue(run(c64, until: "NO CARRIER"), screen(c64))
        XCTAssertEqual(modem.state, .command)
    }

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
