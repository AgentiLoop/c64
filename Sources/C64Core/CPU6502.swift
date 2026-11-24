// MOS 6502/6510 CPU core. Every bus access is exactly one clock cycle (including the
// dummy reads/writes the real chip performs), so the bus implementation drives the rest
// of the machine one cycle per access. All documented and undocumented NMOS opcodes.

import Foundation

public protocol CPUBus: AnyObject {
    func read(_ address: UInt16) -> UInt8
    func write(_ address: UInt16, _ value: UInt8)
}

public final class CPU6502 {
    public var a: UInt8 = 0
    public var x: UInt8 = 0
    public var y: UInt8 = 0
    public var sp: UInt8 = 0xFD
    public var pc: UInt16 = 0
    public var c = false, z = false, i = true, d = false, v = false, n = false

    /// Level-triggered IRQ input (true = asserted).
    public var irqLine = false
    /// Set by the machine on a falling NMI edge.
    public var nmiPending = false
    public private(set) var jammed = false
    /// Optional hook executed before each opcode fetch; return true if it handled the
    /// instruction itself (used for KERNAL traps).
    public var trap: ((CPU6502) -> Bool)?
    public var trapAddresses = Set<UInt16>()

    unowned(unsafe) let bus: CPUBus
    private var pollI: Bool?

    public init(bus: CPUBus) { self.bus = bus }

    public var p: UInt8 {
        get {
            var r: UInt8 = 0x20
            if n { r |= 0x80 }; if v { r |= 0x40 }; if d { r |= 0x08 }
            if i { r |= 0x04 }; if z { r |= 0x02 }; if c { r |= 0x01 }
            return r
        }
        set {
            n = newValue & 0x80 != 0; v = newValue & 0x40 != 0; d = newValue & 0x08 != 0
            i = newValue & 0x04 != 0; z = newValue & 0x02 != 0; c = newValue & 0x01 != 0
        }
    }

    public func reset() {
        jammed = false
        sp = 0xFD
        i = true
        nmiPending = false
        pollI = nil
        pc = UInt16(bus.read(0xFFFC)) | UInt16(bus.read(0xFFFD)) << 8
    }

    // MARK: - Helpers

    @inline(__always) private func rd(_ a: UInt16) -> UInt8 { bus.read(a) }
    @inline(__always) private func wr(_ a: UInt16, _ v: UInt8) { bus.write(a, v) }
    @inline(__always) private func fetch() -> UInt8 { let v = bus.read(pc); pc &+= 1; return v }
    @inline(__always) private func fetchWord() -> UInt16 {
        let lo = UInt16(fetch()); return lo | UInt16(fetch()) << 8
    }
    @inline(__always) private func push(_ v: UInt8) { wr(0x100 | UInt16(sp), v); sp &-= 1 }
    @inline(__always) private func pull() -> UInt8 { sp &+= 1; return rd(0x100 | UInt16(sp)) }
    @inline(__always) private func nz(_ r: UInt8) { z = r == 0; n = r & 0x80 != 0 }

    // MARK: - Execution

    /// Executes one instruction or interrupt sequence.
    public func step() {
        if jammed { _ = rd(0xFFFF); return }
        if nmiPending {
            nmiPending = false
            interrupt(vector: 0xFFFA)
            return
        }
        let iPoll = pollI ?? i
        pollI = nil
        if irqLine && !iPoll {
            interrupt(vector: 0xFFFE)
            return
        }
        if let trap = trap, trapAddresses.contains(pc), trap(self) { return }
        let opcode = fetch()
        execute(opcode)
    }

    private func interrupt(vector: UInt16) {
        _ = rd(pc); _ = rd(pc)
        push(UInt8(pc >> 8)); push(UInt8(pc & 0xFF))
        push(p & ~0x10)
        i = true
        var vec = vector
        if vector == 0xFFFE && nmiPending { nmiPending = false; vec = 0xFFFA }
        let lo = UInt16(rd(vec))
        pc = lo | UInt16(rd(vec + 1)) << 8
    }

    enum Mode: UInt8 { case imp, acc, imm, zp, zpx, zpy, abs, abx, aby, ind, izx, izy, rel }
    enum Op: UInt8 {
        case ADC, AND, ASL, BCC, BCS, BEQ, BIT, BMI, BNE, BPL, BRK, BVC, BVS, CLC, CLD, CLI, CLV,
             CMP, CPX, CPY, DEC, DEX, DEY, EOR, INC, INX, INY, JMP, JSR, LDA, LDX, LDY, LSR, NOP,
             ORA, PHA, PHP, PLA, PLP, ROL, ROR, RTI, RTS, SBC, SEC, SED, SEI, STA, STX, STY, TAX,
             TAY, TSX, TXA, TXS, TYA,
             SLO, RLA, SRE, RRA, SAX, LAX, DCP, ISC, ANC, ALR, ARR, SBX, ANE, LXA, LAS, SHA, SHX,
             SHY, TAS, JAM
    }

    static let table: [(Op, Mode)] = {
        let src = """
        BRK imp,ORA izx,JAM imp,SLO izx,NOP zp,ORA zp,ASL zp,SLO zp,PHP imp,ORA imm,ASL acc,ANC imm,NOP abs,ORA abs,ASL abs,SLO abs,
        BPL rel,ORA izy,JAM imp,SLO izy,NOP zpx,ORA zpx,ASL zpx,SLO zpx,CLC imp,ORA aby,NOP imp,SLO aby,NOP abx,ORA abx,ASL abx,SLO abx,
        JSR abs,AND izx,JAM imp,RLA izx,BIT zp,AND zp,ROL zp,RLA zp,PLP imp,AND imm,ROL acc,ANC imm,BIT abs,AND abs,ROL abs,RLA abs,
        BMI rel,AND izy,JAM imp,RLA izy,NOP zpx,AND zpx,ROL zpx,RLA zpx,SEC imp,AND aby,NOP imp,RLA aby,NOP abx,AND abx,ROL abx,RLA abx,
        RTI imp,EOR izx,JAM imp,SRE izx,NOP zp,EOR zp,LSR zp,SRE zp,PHA imp,EOR imm,LSR acc,ALR imm,JMP abs,EOR abs,LSR abs,SRE abs,
        BVC rel,EOR izy,JAM imp,SRE izy,NOP zpx,EOR zpx,LSR zpx,SRE zpx,CLI imp,EOR aby,NOP imp,SRE aby,NOP abx,EOR abx,LSR abx,SRE abx,
        RTS imp,ADC izx,JAM imp,RRA izx,NOP zp,ADC zp,ROR zp,RRA zp,PLA imp,ADC imm,ROR acc,ARR imm,JMP ind,ADC abs,ROR abs,RRA abs,
        BVS rel,ADC izy,JAM imp,RRA izy,NOP zpx,ADC zpx,ROR zpx,RRA zpx,SEI imp,ADC aby,NOP imp,RRA aby,NOP abx,ADC abx,ROR abx,RRA abx,
        NOP imm,STA izx,NOP imm,SAX izx,STY zp,STA zp,STX zp,SAX zp,DEY imp,NOP imm,TXA imp,ANE imm,STY abs,STA abs,STX abs,SAX abs,
        BCC rel,STA izy,JAM imp,SHA izy,STY zpx,STA zpx,STX zpy,SAX zpy,TYA imp,STA aby,TXS imp,TAS aby,SHY abx,STA abx,SHX aby,SHA aby,
        LDY imm,LDA izx,LDX imm,LAX izx,LDY zp,LDA zp,LDX zp,LAX zp,TAY imp,LDA imm,TAX imp,LXA imm,LDY abs,LDA abs,LDX abs,LAX abs,
        BCS rel,LDA izy,JAM imp,LAX izy,LDY zpx,LDA zpx,LDX zpy,LAX zpy,CLV imp,LDA aby,TSX imp,LAS aby,LDY abx,LDA abx,LDX aby,LAX aby,
        CPY imm,CMP izx,NOP imm,DCP izx,CPY zp,CMP zp,DEC zp,DCP zp,INY imp,CMP imm,DEX imp,SBX imm,CPY abs,CMP abs,DEC abs,DCP abs,
        BNE rel,CMP izy,JAM imp,DCP izy,NOP zpx,CMP zpx,DEC zpx,DCP zpx,CLD imp,CMP aby,NOP imp,DCP aby,NOP abx,CMP abx,DEC abx,DCP abx,
        CPX imm,SBC izx,NOP imm,ISC izx,CPX zp,SBC zp,INC zp,ISC zp,INX imp,SBC imm,NOP imp,SBC imm,CPX abs,SBC abs,INC abs,ISC abs,
        BEQ rel,SBC izy,JAM imp,ISC izy,NOP zpx,SBC zpx,INC zpx,ISC zpx,SED imp,SBC aby,NOP imp,ISC aby,NOP abx,SBC abx,INC abx,ISC abx
        """
        let modes: [String: Mode] = ["imp": .imp, "acc": .acc, "imm": .imm, "zp": .zp, "zpx": .zpx,
                                     "zpy": .zpy, "abs": .abs, "abx": .abx, "aby": .aby, "ind": .ind,
                                     "izx": .izx, "izy": .izy, "rel": .rel]
        let ops: [String: Op] = {
            var d = [String: Op]()
            var k: UInt8 = 0
            while let op = Op(rawValue: k) { d["\(op)"] = op; k += 1 }
            return d
        }()
        let entries = src.replacingOccurrences(of: "\n", with: "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        precondition(entries.count == 256, "opcode table has \(entries.count) entries")
        return entries.map { e in
            let parts = e.split(separator: " ")
            return (ops[String(parts[0])]!, modes[String(parts[1])]!)
        }
    }()

    // Effective address for read instructions (dummy read only on page crossing).
    @inline(__always) private func eaRead(_ m: Mode) -> UInt16 {
        switch m {
        case .zp: return UInt16(fetch())
        case .zpx: let b = fetch(); _ = rd(UInt16(b)); return UInt16(b &+ x)
        case .zpy: let b = fetch(); _ = rd(UInt16(b)); return UInt16(b &+ y)
        case .abs: return fetchWord()
        case .abx, .aby:
            let base = fetchWord()
            let ea = base &+ UInt16(m == .abx ? x : y)
            if (base ^ ea) & 0xFF00 != 0 { _ = rd((base & 0xFF00) | (ea & 0x00FF)) }
            return ea
        case .izx:
            var p = fetch(); _ = rd(UInt16(p)); p &+= x
            let lo = UInt16(rd(UInt16(p)))
            return lo | UInt16(rd(UInt16(p &+ 1))) << 8
        case .izy:
            let p = fetch()
            let lo = UInt16(rd(UInt16(p)))
            let base = lo | UInt16(rd(UInt16(p &+ 1))) << 8
            let ea = base &+ UInt16(y)
            if (base ^ ea) & 0xFF00 != 0 { _ = rd((base & 0xFF00) | (ea & 0x00FF)) }
            return ea
        default: return 0
        }
    }

    // Effective address for write / read-modify-write instructions (always dummy read).
    @inline(__always) private func eaWrite(_ m: Mode) -> UInt16 {
        switch m {
        case .abx, .aby:
            let base = fetchWord()
            let ea = base &+ UInt16(m == .abx ? x : y)
            _ = rd((base & 0xFF00) | (ea & 0x00FF))
            return ea
        case .izy:
            let p = fetch()
            let lo = UInt16(rd(UInt16(p)))
            let base = lo | UInt16(rd(UInt16(p &+ 1))) << 8
            let ea = base &+ UInt16(y)
            _ = rd((base & 0xFF00) | (ea & 0x00FF))
            return ea
        default: return eaRead(m)
        }
    }

    @inline(__always) private func operand(_ m: Mode) -> UInt8 {
        m == .imm ? fetch() : rd(eaRead(m))
    }

    private func adc(_ val: UInt8) {
        let ci = c ? 1 : 0
        let av = Int(a), vv = Int(val)
        if d {
            var t = (av & 0x0F) + (vv & 0x0F) + ci
            if t > 9 { t += 6 }
            if t <= 0x0F { t = (t & 0x0F) + (av & 0xF0) + (vv & 0xF0) }
            else { t = (t & 0x0F) + (av & 0xF0) + (vv & 0xF0) + 0x10 }
            z = (av + vv + ci) & 0xFF == 0
            n = t & 0x80 != 0
            v = ((av ^ t) & 0x80) != 0 && ((av ^ vv) & 0x80) == 0
            if (t & 0x1F0) > 0x90 { t += 0x60 }
            c = (t & 0xFF0) > 0xF0
            a = UInt8(truncatingIfNeeded: t)
        } else {
            let t = av + vv + ci
            v = ((av ^ vv) & 0x80) == 0 && ((av ^ t) & 0x80) != 0
            c = t > 0xFF
            a = UInt8(truncatingIfNeeded: t)
            nz(a)
        }
    }

    private func sbc(_ val: UInt8) {
        let borrow = c ? 0 : 1
        let av = Int(a), vv = Int(val)
        let t = av - vv - borrow
        if d {
            var ta = (av & 0x0F) - (vv & 0x0F) - borrow
            if ta & 0x10 != 0 { ta = ((ta - 6) & 0x0F) | ((av & 0xF0) - (vv & 0xF0) - 0x10) }
            else { ta = (ta & 0x0F) | ((av & 0xF0) - (vv & 0xF0)) }
            if ta & 0x100 != 0 { ta -= 0x60 }
            c = t >= 0
            nz(UInt8(truncatingIfNeeded: t))
            v = ((av ^ t) & 0x80) != 0 && ((av ^ vv) & 0x80) != 0
            a = UInt8(truncatingIfNeeded: ta)
        } else {
            nz(UInt8(truncatingIfNeeded: t))
            c = t >= 0
            v = ((av ^ t) & 0x80) != 0 && ((av ^ vv) & 0x80) != 0
            a = UInt8(truncatingIfNeeded: t)
        }
    }

    @inline(__always) private func cmp(_ r: UInt8, _ val: UInt8) {
        let t = r &- val
        c = r >= val
        nz(t)
    }

    @inline(__always) private func asl(_ val: UInt8) -> UInt8 { c = val & 0x80 != 0; let r = val << 1; nz(r); return r }
    @inline(__always) private func lsr(_ val: UInt8) -> UInt8 { c = val & 1 != 0; let r = val >> 1; nz(r); return r }
    @inline(__always) private func rol(_ val: UInt8) -> UInt8 {
        let r = val << 1 | (c ? 1 : 0); c = val & 0x80 != 0; nz(r); return r
    }
    @inline(__always) private func ror(_ val: UInt8) -> UInt8 {
        let r = val >> 1 | (c ? 0x80 : 0); c = val & 1 != 0; nz(r); return r
    }

    private func branch(_ cond: Bool) {
        let off = Int8(bitPattern: fetch())
        guard cond else { return }
        _ = rd(pc)
        let np = UInt16(bitPattern: Int16(bitPattern: pc) &+ Int16(off))
        if (np ^ pc) & 0xFF00 != 0 { _ = rd((pc & 0xFF00) | (np & 0x00FF)) }
        pc = np
    }

    // SHA/SHX/SHY/TAS: store reg & (H+1); on page crossing the high byte is corrupted.
    private func unstableStore(_ m: Mode, _ reg: UInt8) {
        let base: UInt16
        let index: UInt8
        if m == .izy {
            let p = fetch()
            let lo = UInt16(rd(UInt16(p)))
            base = lo | UInt16(rd(UInt16(p &+ 1))) << 8
            index = y
        } else {
            base = fetchWord()
            index = m == .abx ? x : y
        }
        var ea = base &+ UInt16(index)
        _ = rd((base & 0xFF00) | (ea & 0x00FF))
        let val = reg & (UInt8(base >> 8) &+ 1)
        if (base ^ ea) & 0xFF00 != 0 { ea = (ea & 0x00FF) | UInt16(val) << 8 }
        wr(ea, val)
    }

    private func execute(_ opcode: UInt8) {
        let (op, m) = CPU6502.table[Int(opcode)]
        switch op {
        // Loads / ALU reads
        case .LDA: a = operand(m); nz(a)
        case .LDX: x = operand(m); nz(x)
        case .LDY: y = operand(m); nz(y)
        case .LAX: a = operand(m); x = a; nz(a)
        case .ADC: adc(operand(m))
        case .SBC: sbc(operand(m))
        case .AND: a &= operand(m); nz(a)
        case .ORA: a |= operand(m); nz(a)
        case .EOR: a ^= operand(m); nz(a)
        case .CMP: cmp(a, operand(m))
        case .CPX: cmp(x, operand(m))
        case .CPY: cmp(y, operand(m))
        case .BIT:
            let val = operand(m)
            z = a & val == 0; n = val & 0x80 != 0; v = val & 0x40 != 0
        case .NOP:
            if m == .imp { _ = rd(pc) } else { _ = operand(m) }
        case .ANC: a &= operand(m); nz(a); c = n
        case .ALR: a &= operand(m); a = lsr(a)
        case .ARR:
            let t = a & operand(m)
            if d {
                var ta = t >> 1 | (c ? 0x80 : 0)
                n = c; z = ta == 0
                v = ((t ^ ta) & 0x40) != 0
                if (t & 0x0F) &+ (t & 0x01) > 0x05 { ta = (ta & 0xF0) | ((ta &+ 0x06) & 0x0F) }
                if UInt16(t & 0xF0) + UInt16(t & 0x10) > 0x50 { ta = (ta & 0x0F) | ((ta &+ 0x60) & 0xF0); c = true }
                else { c = false }
                a = ta
            } else {
                let r = t >> 1 | (c ? 0x80 : 0)
                a = r; nz(r)
                c = r & 0x40 != 0
                v = ((r & 0x40) ^ ((r & 0x20) << 1)) != 0
            }
        case .SBX:
            let val = operand(m)
            let ax = a & x
            c = ax >= val
            x = ax &- val; nz(x)
        case .ANE: a = (a | 0xEE) & x & operand(m); nz(a)
        case .LXA: a = (a | 0xEE) & operand(m); x = a; nz(a)
        case .LAS: let r = operand(m) & sp; a = r; x = r; sp = r; nz(r)

        // Stores
        case .STA: wr(eaWrite(m), a)
        case .STX: wr(eaWrite(m), x)
        case .STY: wr(eaWrite(m), y)
        case .SAX: wr(eaWrite(m), a & x)
        case .SHA: unstableStore(m, a & x)
        case .SHX: unstableStore(m, x)
        case .SHY: unstableStore(m, y)
        case .TAS: sp = a & x; unstableStore(m, sp)

        // Read-modify-write
        case .ASL, .LSR, .ROL, .ROR, .INC, .DEC, .SLO, .RLA, .SRE, .RRA, .DCP, .ISC:
            if m == .acc {
                _ = rd(pc)
                switch op {
                case .ASL: a = asl(a)
                case .LSR: a = lsr(a)
                case .ROL: a = rol(a)
                default: a = ror(a)
                }
                return
            }
            let ea = eaWrite(m)
            let old = rd(ea)
            wr(ea, old)
            var r: UInt8
            switch op {
            case .ASL: r = asl(old)
            case .LSR: r = lsr(old)
            case .ROL: r = rol(old)
            case .ROR: r = ror(old)
            case .INC: r = old &+ 1; nz(r)
            case .DEC: r = old &- 1; nz(r)
            case .SLO: r = asl(old); a |= r; nz(a)
            case .RLA: r = rol(old); a &= r; nz(a)
            case .SRE: r = lsr(old); a ^= r; nz(a)
            case .RRA: r = ror(old); adc(r)
            case .DCP: r = old &- 1; cmp(a, r)
            default: r = old &+ 1; sbc(r) // ISC
            }
            wr(ea, r)

        // Branches
        case .BPL: branch(!n)
        case .BMI: branch(n)
        case .BVC: branch(!v)
        case .BVS: branch(v)
        case .BCC: branch(!c)
        case .BCS: branch(c)
        case .BNE: branch(!z)
        case .BEQ: branch(z)

        // Jumps / stack
        case .JMP:
            if m == .abs {
                pc = fetchWord()
            } else {
                let ptr = fetchWord()
                let lo = UInt16(rd(ptr))
                pc = lo | UInt16(rd((ptr & 0xFF00) | ((ptr &+ 1) & 0x00FF))) << 8
            }
        case .JSR:
            let lo = UInt16(fetch())
            _ = rd(0x100 | UInt16(sp))
            push(UInt8(pc >> 8)); push(UInt8(pc & 0xFF))
            pc = lo | UInt16(rd(pc)) << 8
        case .RTS:
            _ = rd(pc); _ = rd(0x100 | UInt16(sp))
            let lo = UInt16(pull())
            pc = lo | UInt16(pull()) << 8
            _ = rd(pc); pc &+= 1
        case .RTI:
            _ = rd(pc); _ = rd(0x100 | UInt16(sp))
            p = pull()
            let lo = UInt16(pull())
            pc = lo | UInt16(pull()) << 8
        case .BRK:
            _ = fetch()
            push(UInt8(pc >> 8)); push(UInt8(pc & 0xFF))
            push(p | 0x10)
            i = true
            let vec: UInt16 = nmiPending ? 0xFFFA : 0xFFFE
            if nmiPending { nmiPending = false }
            let lo = UInt16(rd(vec))
            pc = lo | UInt16(rd(vec + 1)) << 8
            pollI = true
        case .PHA: _ = rd(pc); push(a)
        case .PHP: _ = rd(pc); push(p | 0x10)
        case .PLA: _ = rd(pc); _ = rd(0x100 | UInt16(sp)); a = pull(); nz(a)
        case .PLP: _ = rd(pc); _ = rd(0x100 | UInt16(sp)); pollI = i; p = pull()

        // Flags / transfers
        case .CLC: _ = rd(pc); c = false
        case .SEC: _ = rd(pc); c = true
        case .CLI: _ = rd(pc); pollI = i; i = false
        case .SEI: _ = rd(pc); pollI = i; i = true
        case .CLV: _ = rd(pc); v = false
        case .CLD: _ = rd(pc); d = false
        case .SED: _ = rd(pc); d = true
        case .TAX: _ = rd(pc); x = a; nz(x)
        case .TAY: _ = rd(pc); y = a; nz(y)
        case .TXA: _ = rd(pc); a = x; nz(a)
        case .TYA: _ = rd(pc); a = y; nz(a)
        case .TSX: _ = rd(pc); x = sp; nz(x)
        case .TXS: _ = rd(pc); sp = x
        case .INX: _ = rd(pc); x &+= 1; nz(x)
        case .INY: _ = rd(pc); y &+= 1; nz(y)
        case .DEX: _ = rd(pc); x &-= 1; nz(x)
        case .DEY: _ = rd(pc); y &-= 1; nz(y)

        case .JAM:
            jammed = true
            pc &-= 1
        }
    }
}
