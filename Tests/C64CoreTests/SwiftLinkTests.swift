import XCTest
@testable import C64Core

/// A small NMI-driven SwiftLink driver (6510 machine code) talking to the modem through the ACIA.
final class SwiftLinkTests: XCTestCase {
    var dialed: (String, UInt16)?
    var hungUp = 0

    /// $C000: set NMI vector, 38,400 8N1, DTR + receive IRQ, send "AT\r" polling TDRE, then idle.
    /// $C040: NMI handler storing every received byte at $C100,($FB).
    static let program: [UInt8] = {
        var m = [UInt8](repeating: 0xEA, count: 0x60)
        let main: [UInt8] = [
            0x78,                   // C000 SEI
            0xA9, 0x40, 0x8D, 0x18, 0x03,   // LDA #$40 / STA $0318
            0xA9, 0xC0, 0x8D, 0x19, 0x03,   // LDA #$C0 / STA $0319
            0xA9, 0x1F, 0x8D, 0x03, 0xDE,   // LDA #$1F / STA $DE03   8N1, 19200 x2
            0xA9, 0x09, 0x8D, 0x02, 0xDE,   // LDA #$09 / STA $DE02   DTR, RX IRQ, RTS
            0x58,                   // C015 CLI
            0xA2, 0x00,             // C016 LDX #0
            0xAD, 0x01, 0xDE,       // C018 LDA $DE01
            0x29, 0x10,             // C01B AND #$10   TDRE
            0xF0, 0xF9,             // C01D BEQ C018
            0xBD, 0x30, 0xC0,       // C01F LDA $C030,X
            0xF0, 0x06,             // C022 BEQ C02A
            0x8D, 0x00, 0xDE,       // C024 STA $DE00
            0xE8,                   // C027 INX
            0xD0, 0xEE,             // C028 BNE C018
            0x4C, 0x2A, 0xC0,       // C02A JMP C02A
        ]
        m.replaceSubrange(0..<main.count, with: main)
        m.replaceSubrange(0x30..<0x34, with: [0x41, 0x54, 0x0D, 0x00])   // "AT\r"
        let nmi: [UInt8] = [
            0x48, 0x8A, 0x48,       // C040 PHA / TXA / PHA
            0xAD, 0x01, 0xDE,       // C043 LDA $DE01   (clears the IRQ)
            0x29, 0x08,             // C046 AND #$08    RDRF
            0xF0, 0x0B,             // C048 BEQ C055
            0xAD, 0x00, 0xDE,       // C04A LDA $DE00
            0xA6, 0xFB,             // C04D LDX $FB
            0x9D, 0x00, 0xC1,       // C04F STA $C100,X
            0xE6, 0xFB,             // C052 INC $FB
            0xEA,                   // C054 NOP
            0x68, 0xAA, 0x68,       // C055 PLA / TAX / PLA
            0x40,                   // C058 RTI
        ]
        m.replaceSubrange(0x40..<0x40 + nmi.count, with: nmi)
        return m
    }()

    func makeMachine(_ port: C64.ModemPort) throws -> (C64, HayesModem) {
        guard let roms = ROMSet.load() else { throw XCTSkip("C64 ROMs not installed") }
        let c64 = C64(roms: roms)
        let modem = HayesModem()
        modem.onDial = { [unowned self] in self.dialed = ($0, $1) }
        modem.onHangUp = { [unowned self] in self.hungUp += 1 }
        c64.modemPort = port
        c64.modem = modem
        for _ in 0..<150 { c64.runFrame() }
        return (c64, modem)
    }

    func received(_ c64: C64) -> [UInt8] { Array(c64.ram[0xC100..<0xC100 + Int(c64.ram[0xFB])]) }

    func testDriverTalksAt38400() throws {
        let (c64, modem) = try makeMachine(.swiftLink)
        c64.ram.replaceSubrange(0xC000..<0xC060, with: SwiftLinkTests.program)
        c64.ram[0xFB] = 0
        c64.typeIntoBuffer("SYS49152\n")
        for _ in 0..<20 { c64.runFrame() }
        XCTAssertEqual(modem.baud, 38400)
        XCTAssertEqual(String(decoding: received(c64), as: UTF8.self), "AT\r\r\nOK\r\n")

        modem.dial(host: "bbs.example.com", port: 6400)
        XCTAssertEqual(dialed?.0, "bbs.example.com")
        modem.connected()
        for _ in 0..<10 { c64.runFrame() }
        XCTAssertTrue(String(decoding: received(c64), as: UTF8.self).hasSuffix("CONNECT 38400\r\n"))

        // A burst arrives paced at 38,400 baud (10 bits per byte), with nothing lost.
        c64.ram[0xFB] = 0
        let burst = (0..<200).map { UInt8(32 + $0 % 90) }
        modem.receive(burst)
        let byteCycles = C64.palClock * 10 / 38400
        c64.run(cycles: byteCycles * 100)
        XCTAssertLessThanOrEqual(Int(c64.ram[0xFB]), 101)
        XCTAssertGreaterThanOrEqual(Int(c64.ram[0xFB]), 95)
        for _ in 0..<10 { c64.runFrame() }
        XCTAssertEqual(received(c64), burst)

        // Dropping DTR hangs up, like a real modem set to &D2.
        c64.poke(0xDE02, 0x08)
        XCTAssertEqual(hungUp, 1)
        XCTAssertFalse(modem.carrier)
    }

    func testCarrierInStatus() throws {
        let (c64, modem) = try makeMachine(.swiftLink)
        c64.poke(0xDE02, 0x0B)   // DTR, RX IRQ off, RTS
        XCTAssertEqual(c64.peek(0xDE01) & 0x40, 0x40)   // no carrier
        modem.dial(host: "h", port: 23)
        modem.connected()
        XCTAssertEqual(c64.peek(0xDE01) & 0x40, 0)
        c64.poke(0xDE03, 0x1F)
        XCTAssertEqual(c64.peek(0xDE07), 0x1F)   // SwiftLink decodes 4 registers, mirrored
    }

    func testTurbo232EnhancedSpeed() throws {
        let (c64, modem) = try makeMachine(.turbo232)
        c64.poke(0xDE03, 0x10)                   // external clock → enhanced register decides
        XCTAssertEqual(c64.peek(0xDE07), 0x04)   // EXT_ACTIVE, 230,400
        XCTAssertEqual(modem.baud, 230400)
        c64.poke(0xDE07, 0x01)
        XCTAssertEqual(modem.baud, 115200)
        c64.poke(0xDE03, 0x1F)
        XCTAssertEqual(modem.baud, 38400)
        c64.poke(0xDE07, 0x02)                   // ignored unless the external clock is selected
        XCTAssertEqual(c64.peek(0xDE07), 0x01)
    }
}
