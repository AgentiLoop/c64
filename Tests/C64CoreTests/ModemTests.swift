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
    /// F1 switches to ASCII/ANSI: ANSI clear screen, colours and cursor positioning, case translation both ways.
    func testASCIIANSIMode() throws {
        let (c64, modem) = try makeMachine(.swiftLink)
        XCTAssertTrue(run(c64, until: "OK"), screen(c64))
        c64.setKey(.f1, pressed: true)
        for _ in 0..<4 { c64.runFrame() }
        c64.setKey(.f1, pressed: false)
        XCTAssertTrue(run(c64, until: "MODE,"), screen(c64))   // "(ASCII/ANSI mode, F1 = PETSCII)"

        modem.dial(host: "ansi.example.com", port: 23)
        modem.connected()
        for _ in 0..<20 { c64.runFrame() }
        let ansi = "\u{1B}[2J\u{1B}[1;31mhello world\u{1B}[0m\r\n\u{1B}[5;10Hx\u{1B}[?25l\u{1B}[0;36mz{|}"
        modem.receive(Array(ansi.utf8) + [0xC4, 0xB3])   // CP437 ─ │
        for _ in 0..<30 { c64.runFrame() }
        let rows = c64.screenText()
        XCTAssertEqual(String(rows[0].prefix(11)), "HELLO WORLD", rows.joined(separator: "\n"))   // screen cleared
        XCTAssertEqual(c64.colorRAM[0] & 0x0F, 10)   // bold red = light red
        let row4 = Array(rows[4])
        XCTAssertEqual(row4[9], "X", rows.joined(separator: "\n"))   // ESC[5;10H
        XCTAssertEqual(row4[10], "Z")
        XCTAssertEqual(c64.colorRAM[4 * 40 + 10] & 0x0F, 3)           // cyan
        XCTAssertFalse(rows.joined().contains("25L"), rows.joined(separator: "\n"))   // ESC[?25l swallowed
        let screenBase = 0x0400 + 4 * 40
        XCTAssertEqual(c64.ram[screenBase + 11], 0x1B)   // { → [
        XCTAssertEqual(c64.ram[screenBase + 12], 0x5D)   // | → vertical line
        XCTAssertEqual(c64.ram[screenBase + 13], 0x1D)   // } → ]
        XCTAssertEqual(c64.ram[screenBase + 14], 0x40)   // ─
        XCTAssertEqual(c64.ram[screenBase + 15], 0x5D)   // │

        sent = []
        c64.queueTyping("hi\n")
        for _ in 0..<100 where sent.count < 3 { c64.runFrame() }
        XCTAssertEqual(sent, [0x68, 0x69, 13])   // lower case ASCII

        // ANSI detection: ESC[6n is answered with the cursor position.
        sent = []
        modem.receive(Array("\u{1B}[12;34H\u{1B}[6n".utf8))
        for _ in 0..<30 where sent.count < 8 { c64.runFrame() }
        XCTAssertEqual(String(decoding: sent, as: UTF8.self), "\u{1B}[12;34R")
    }
    /// F3 downloads a file with XMODEM (checksum) from the "BBS" to a PRG file on drive 8,
    /// recovering from a corrupted block and dropping the $1A padding of the last block.
    func xmodemDownload(_ port: C64.ModemPort, frames: Int) throws {
        let (c64, modem) = try makeMachine(port)
        guard let drive = c64.drive8 else { throw XCTSkip("1541 ROM not installed") }
        let disk = GCRDisk(d64: D64Image.blank(name: "DOWNLOADS", id: "01"))
        drive.insert(disk)
        XCTAssertTrue(run(c64, until: "OK"), screen(c64))
        modem.dial(host: "bbs.example.com", port: 6400)
        modem.connected()
        for _ in 0..<30 { c64.runFrame() }

        let file: [UInt8] = [0x01, 0x08] + (0..<298).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        var blocks: [[UInt8]] = stride(from: 0, to: file.count, by: 128).map { Array(file[$0..<min($0 + 128, file.count)]) }
        blocks[blocks.count - 1] += [UInt8](repeating: 0x1A, count: 128 - blocks[blocks.count - 1].count)
        var current = 0, started = false, eotSent = false, finished = false, corrupt = true, naks = 0
        func send(_ i: Int) {
            let n = UInt8(i + 1)
            var sum = blocks[i].reduce(UInt8(0), &+)
            if corrupt && i == 1 { sum = ~sum; corrupt = false }
            modem.receive([0x01, n, ~n] + blocks[i] + [sum])
        }
        modem.onSend = { byte in
            switch byte {
            case 0x15:
                naks += 1
                if !started { started = true; send(0) } else if eotSent { modem.receive([0x04]) } else { send(current) }
            case 0x06:
                if eotSent { finished = true; return }
                current += 1
                if current < blocks.count { send(current) } else { eotSent = true; modem.receive([0x04]) }
            default:
                break
            }
        }

        c64.setKey(.f3, pressed: true)
        for _ in 0..<4 { c64.runFrame() }
        c64.setKey(.f3, pressed: false)
        XCTAssertTrue(run(c64, until: "FILE NAME"), screen(c64))
        c64.queueTyping("testfile\n")
        XCTAssertTrue(run(c64, until: "COMPLETE", frames: frames), screen(c64))
        XCTAssertTrue(finished)
        XCTAssertEqual(naks, 2)   // the start and the corrupted block
        let img = disk.toD64()
        let entry = img.directory().first { $0.name == "TESTFILE" }
        XCTAssertEqual(entry?.type, 0x82, "\(img.directory())")
        if let e = entry { XCTAssertEqual(img.readFile(e), file) }
    }

    func testXMODEMDownloadSwiftLink() throws { try xmodemDownload(.swiftLink, frames: 6000) }
    func testXMODEMDownloadUserPort() throws { try xmodemDownload(.userPort, frames: 9000) }
    /// F5 uploads a PRG from drive 8 with XMODEM (checksum); the "BBS" rejects one block once.
    func xmodemUpload(_ port: C64.ModemPort, frames: Int) throws {
        let (c64, modem) = try makeMachine(port)
        guard let drive = c64.drive8 else { throw XCTSkip("1541 ROM not installed") }
        let file: [UInt8] = [0x01, 0x08] + (0..<298).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 1) }
        let d64 = D64Image.blank(name: "UPLOADS", id: "01")
        XCTAssertTrue(d64.addFile(name: "UPFILE", contents: file))
        drive.insert(GCRDisk(d64: d64))
        XCTAssertTrue(run(c64, until: "OK"), screen(c64))
        modem.dial(host: "bbs.example.com", port: 6400)
        modem.connected()
        for _ in 0..<30 { c64.runFrame() }

        var incoming: [UInt8] = [], received: [UInt8] = [], expected: UInt8 = 1
        var rejected = false, finished = false, badBlocks = 0
        modem.onSend = { byte in
            if incoming.isEmpty && byte == 0x04 { finished = true; modem.receive([0x06]); return }
            incoming.append(byte)
            guard incoming.count == 132 else { return }
            let block = incoming
            incoming = []
            let data = Array(block[3..<131])
            guard block[0] == 0x01, block[1] == expected, block[2] == ~expected,
                  data.reduce(UInt8(0), &+) == block[131] else { badBlocks += 1; modem.receive([0x15]); return }
            if expected == 2 && !rejected { rejected = true; modem.receive([0x15]); return }
            received += data
            expected &+= 1
            modem.receive([0x06])
        }

        c64.setKey(.f5, pressed: true)
        for _ in 0..<4 { c64.runFrame() }
        c64.setKey(.f5, pressed: false)
        XCTAssertTrue(run(c64, until: "FILE NAME"), screen(c64))
        c64.queueTyping("upfile\n")
        XCTAssertTrue(run(c64, until: "ON THE"), screen(c64))   // "Start the download on the BBS now"
        modem.receive([0x15])                                   // the receiver starts
        XCTAssertTrue(run(c64, until: "COMPLETE", frames: frames), screen(c64))
        XCTAssertTrue(finished)
        XCTAssertTrue(rejected)
        XCTAssertEqual(badBlocks, 0)
        XCTAssertEqual(received.count, 384)
        XCTAssertEqual(Array(received.prefix(file.count)), file)
        XCTAssertEqual(Array(received.dropFirst(file.count)), [UInt8](repeating: 0x1A, count: 384 - file.count))
    }

    func testXMODEMUploadSwiftLink() throws { try xmodemUpload(.swiftLink, frames: 6000) }
    func testXMODEMUploadUserPort() throws { try xmodemUpload(.userPort, frames: 9000) }

    func testXMODEMUploadMissingFile() throws {
        let (c64, _) = try makeMachine(.swiftLink)
        guard let drive = c64.drive8 else { throw XCTSkip("1541 ROM not installed") }
        drive.insert(GCRDisk(d64: D64Image.blank(name: "EMPTY", id: "01")))
        XCTAssertTrue(run(c64, until: "OK"), screen(c64))
        c64.setKey(.f5, pressed: true)
        for _ in 0..<4 { c64.runFrame() }
        c64.setKey(.f5, pressed: false)
        XCTAssertTrue(run(c64, until: "FILE NAME"), screen(c64))
        c64.queueTyping("nothere\n")
        XCTAssertTrue(run(c64, until: "READ THE FILE", frames: 3000), screen(c64))
    }
}
