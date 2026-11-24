import XCTest
@testable import C64Core

final class VICTimingTests: XCTestCase {
    /// A double raster IRQ with the usual CMP $D012 / BEQ jitter correction, followed by DEC $D011
    /// on line 54 (a badline forced in mid-line: "DMA delay", used for VSP scrolling). The write must
    /// land on cycle 31 in every frame, leaving 24 character fetches on that line.
    func testStableRasterAndDMADelay() throws {
        let c64 = C64(basic: [UInt8](repeating: 0, count: 0x2000), kernal: [UInt8](repeating: 0, count: 0x2000),
                      chargen: [UInt8](repeating: 0, count: 0x1000))
        c64.poke(0, 0x2F); c64.poke(1, 0x35)                  // RAM under the ROMs, I/O visible
        func put(_ address: Int, _ bytes: [UInt8]) { for (i, b) in bytes.enumerated() { c64.ram[address + i] = b } }
        let nop: UInt8 = 0xEA
        put(0x1000, [0x78,                                    // SEI
                     0xA9, 0x17, 0x8D, 0x11, 0xD0,            // LDA #$17 : STA $D011
                     0xA9, 0x34, 0x8D, 0x12, 0xD0,            // LDA #52  : STA $D012
                     0xA9, 0x00, 0x8D, 0xFE, 0xFF,            // IRQ vector = $1100
                     0xA9, 0x11, 0x8D, 0xFF, 0xFF,
                     0xA9, 0x01, 0x8D, 0x1A, 0xD0,            // raster IRQ on
                     0xA9, 0xFF, 0x8D, 0x19, 0xD0,
                     0xA2, 0x00, 0x58,                        // LDX #0 : CLI
                     0xE6, 0x02, 0xA5, 0x02,                  // $1022: INC $02 : LDA $02 (a main loop whose
                     0x4A, 0x90, 0x01, nop,                   //   LSR : BCC +1 : NOP      length changes on
                     0x4A, 0x90, 0x02, 0x24, 0xEA,            //   LSR : BCC +2 : BIT $EA  every pass)
                     0x4C, 0x22, 0x10])                       // JMP $1022
        put(0x1100, [0x8D, 0x00, 0x13, 0x8E, 0x01, 0x13,      // STA $1300 : STX $1301
                     0xA9, 0x00, 0x8D, 0xFE, 0xFF,            // IRQ vector = $1200
                     0xA9, 0x12, 0x8D, 0xFF, 0xFF,
                     0xA9, 0xFF, 0x8D, 0x19, 0xD0,
                     0xEE, 0x12, 0xD0,                        // INC $D012
                     0xBA, 0x58] + [UInt8](repeating: nop, count: 30))   // TSX : CLI : NOPs
        put(0x1200, [0x9A,                                    // TXS
                     0xA2, 0x07, 0xCA, 0xD0, 0xFD,            // LDX #7 : DEX : BNE
                     0x24, 0xEA, 0x24, 0xEA, nop, nop,        // BIT $EA : BIT $EA : NOP : NOP
                     0xA9, 0x35, 0xCD, 0x12, 0xD0,            // LDA #53 : CMP $D012
                     0xF0, 0x00]                              // BEQ +0 (one cycle longer on line 53)
                    + [UInt8](repeating: nop, count: 11)
                    + [0xCE, 0x11, 0xD0, 0xEE, 0x11, 0xD0,    // DEC $D011 : INC $D011
                       0xA9, 0xFF, 0x8D, 0x19, 0xD0,
                       0xA9, 0x00, 0x8D, 0xFE, 0xFF,          // IRQ vector = $1100
                       0xA9, 0x11, 0x8D, 0xFF, 0xFF,
                       0xA9, 0x34, 0x8D, 0x12, 0xD0,          // LDA #52 : STA $D012
                       0xAD, 0x00, 0x13, 0xAE, 0x01, 0x13,    // LDA $1300 : LDX $1301
                       0x40])                                 // RTI
        c64.cpu.pc = 0x1000
        for _ in 0..<5 { c64.runFrame() }

        var entryCycles = Set<Int>()
        var writeCycles = Set<Int>()
        var fetches = Set<Int>()
        for n in 0..<60 {
            c64.ram[2] = UInt8(truncatingIfNeeded: n &* 37)   // the main loop is at a different point every frame
            let frame = c64.vic.frameCount
            var seen = false
            while c64.vic.frameCount == frame {
                if c64.cpu.pc == 0x1200 { entryCycles.insert(c64.vic.cycle) }
                let y = c64.vic.regs[0x11] & 7
                c64.cpu.step()
                if y == 7 && c64.vic.regs[0x11] & 7 == 6 { writeCycles.insert(c64.vic.cycle - 1) }
                if c64.vic.raster == 55 && !seen { seen = true; fetches.insert(c64.vic.vcbase) }
            }
        }
        XCTAssertEqual(entryCycles, [10, 11])                 // second IRQ: one cycle of jitter…
        XCTAssertEqual(writeCycles, [31])                     // …removed by the time of the write
        XCTAssertEqual(fetches, [24])
    }

    /// The fast border/text drawing paths produce exactly the pixels of the general path,
    /// including horizontal scrolling and the 38-column border.
    func testFastDrawingMatchesGeneralPath() throws {
        guard let roms = ROMSet.load() else { throw XCTSkip("ROMs not installed") }
        var pictures: [[UInt32]] = []
        for fast in [true, false] {
            let c64 = C64(roms: roms)
            c64.vic.fastDraw = fast
            for _ in 0..<150 { c64.runFrame() }
            c64.queueTyping("POKE53270,195:POKE53280,2:PRINT\"HELLO WORLD\"\n")
            for _ in 0..<60 { c64.runFrame() }
            pictures.append(c64.vic.frameBuffer)
        }
        XCTAssertEqual(pictures[0], pictures[1])
    }
}
