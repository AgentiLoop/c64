import XCTest
@testable import C64Core

/// Diagnostic probe: traces the VIC-II register writes of the disk in $C64_D64 once the game runs
/// (interrupt entries, $D011/$D016/$D018 and raster-compare changes with raster line and cycle) and
/// dumps the traced frames to /tmp/shake-N.raw. Skipped without $C64_D64.
/// $C64_FIRE = first frame fire is pressed, $C64_TRACE = first traced frame (12 are traced),
/// $C64_WALKSTOP = frames before the trace at which the joystick is released.
final class ShakeProbeTests: XCTestCase {
    func testProbe() throws {
        guard let path = ProcessInfo.processInfo.environment["C64_D64"],
              let data = FileManager.default.contents(atPath: path),
              let img = D64Image(data: [UInt8](data)),
              let roms = ROMSet.load() else { throw XCTSkip("no disk") }
        print("DIR", img.directory().map { "\($0.name) \($0.blocks)" })
        let c64 = C64(roms: roms)
        c64.fastLoad = ProcessInfo.processInfo.environment["C64_SLOW"] == nil
        c64.drive8!.insert(GCRDisk(d64: img))
        C64Autostart.ensureBooted(c64)
        c64.queueTyping("LOAD\"*\",8,1\nRUN\n")
        let startFire = Int(ProcessInfo.processInfo.environment["C64_FIRE"] ?? "1500")!
        let traceFrom = Int(ProcessInfo.processInfo.environment["C64_TRACE"] ?? "2200")!
        let total = traceFrom + 12
        let walkStop = Int(ProcessInfo.processInfo.environment["C64_WALKSTOP"] ?? "0")!
        func h(_ v: Int, _ w: Int = 2) -> String { String(repeating: "0", count: max(0, w - String(v, radix: 16).count)) + String(v, radix: 16) }
        for f in 0..<total {
            if f >= startFire && f < traceFrom - 300 && f % 100 == 0 { c64.joystick2 = 0x10 }
            if f >= startFire && f % 100 == 10 { c64.joystick2 = 0 }
            if f >= traceFrom - 60 && f < traceFrom - walkStop { c64.joystick2 = 0x08 }          // walk right
            if f == traceFrom { try? Data(c64.ram).write(to: URL(fileURLWithPath: "/tmp/shake-ram.bin")) }
            if f < traceFrom {
                c64.runFrame()
                if f % 250 == 0 {
                    print("F\(f) pc=\(h(Int(c64.cpu.pc), 4)) d011=\(h(Int(c64.vic.regs[0x11]))) d016=\(h(Int(c64.vic.regs[0x16]))) d018=\(h(Int(c64.vic.regs[0x18]))) cmp=\(c64.vic.rasterCompare) imr=\(c64.vic.imr) bank=\(c64.vicBank) cia1mask=\(h(Int(c64.cia1.icrMask))) cia2mask=\(h(Int(c64.cia2.icrMask))) irqvec=\(h(Int(c64.ram[0xFFFE]) | Int(c64.ram[0xFFFF]) << 8, 4)) nmivec=\(h(Int(c64.ram[0xFFFA]) | Int(c64.ram[0xFFFB]) << 8, 4)) port=\(h(Int(c64.portData)))")
                }
                continue
            }
            // Traced frame: step instruction by instruction.
            var log: [String] = []
            let start = c64.vic.frameCount
            var old = c64.vic.regs
            var oldCmp = c64.vic.rasterCompare
            var oldBank = c64.vicBank
            var oldI = c64.cpu.i
            var oldSP = c64.cpu.sp
            while c64.vic.frameCount == start {
                let pc = Int(c64.cpu.pc)
                let r0 = c64.vic.raster, c0 = c64.vic.cycle
                let irqBefore = c64.cpu.irqLine
                c64.cpu.step()
                let r = c64.vic.raster, c = c64.vic.cycle
                // interrupt entry: SP dropped by 3 and I set, pc changed to vector
                if c64.cpu.sp == oldSP &- 3 && c64.cpu.i && (!oldI || c64.cpu.pc != UInt16(pc)) && Int(c64.cpu.pc) != pc + 1 {
                    let op = c64.peekRAMorROM(pc)
                    if op != 0x00 && op != 0x08 {
                        log.append("  INT from \(h(pc, 4)) -> \(h(Int(c64.cpu.pc), 4)) started r\(r0) c\(c0), handler at r\(r) c\(c) irqLine=\(irqBefore)")
                    }
                }
                if r == 55 && r0 == 54 { log.append("  line 55 starts with vcbase=\(c64.vic.vcbase) rc=\(c64.vic.rc)") }
                oldI = c64.cpu.i; oldSP = c64.cpu.sp
                let now = c64.vic.regs
                for reg in [0x11, 0x16, 0x18, 0x15, 0x20, 0x21, 0x1A] where now[reg] != old[reg] {
                    log.append("  $D0\(h(reg)) \(h(Int(old[reg]))) -> \(h(Int(now[reg]))) pc=\(h(pc, 4)) after r\(r) c\(c)")
                }
                if c64.vic.rasterCompare != oldCmp {
                    log.append("  cmp \(oldCmp) -> \(c64.vic.rasterCompare) pc=\(h(pc, 4)) after r\(r) c\(c)")
                    oldCmp = c64.vic.rasterCompare
                }
                if c64.vicBank != oldBank {
                    log.append("  bank \(oldBank) -> \(c64.vicBank) pc=\(h(pc, 4)) after r\(r) c\(c)")
                    oldBank = c64.vicBank
                }
                old = now
            }
            print("FRAME \(f)")
            print(log.joined(separator: "\n"))
            // Frame dump (raw BGRA) for offline comparison.
            let fb = c64.vic.frameBuffer
            let d = fb.withUnsafeBufferPointer { Data(buffer: $0) }
            try? d.write(to: URL(fileURLWithPath: "/tmp/shake-\(f - traceFrom).raw"))
        }
        print("SCREEN\n" + c64.screenText().joined(separator: "\n"))
    }
}

extension C64 {
    func peekRAMorROM(_ a: Int) -> UInt8 {
        if a >= 0xE000 && hiram { return kernal[a & 0x1FFF] }
        return ram[a]
    }
}
