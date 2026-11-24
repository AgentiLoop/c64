import Foundation

/// Zilog Z80 (the C128's second CPU, used for CP/M and for the start-up code at power-on).
/// Instruction-stepped: `step()` runs one instruction (or accepts an interrupt) and returns its
/// length in T-states. All documented instructions plus the common undocumented ones (IXH/IXL,
/// SLL, DDCB register copies, OUT (C),0) and the undocumented X/Y flag bits.
public final class Z80 {
    public var a: UInt8 = 0xFF, f: UInt8 = 0xFF
    public var b: UInt8 = 0, c: UInt8 = 0, d: UInt8 = 0, e: UInt8 = 0, h: UInt8 = 0, l: UInt8 = 0
    var a2: UInt8 = 0, f2: UInt8 = 0, b2: UInt8 = 0, c2: UInt8 = 0, d2: UInt8 = 0, e2: UInt8 = 0, h2: UInt8 = 0, l2: UInt8 = 0
    public var ix: UInt16 = 0xFFFF, iy: UInt16 = 0xFFFF, sp: UInt16 = 0xFFFF, pc: UInt16 = 0
    public var i: UInt8 = 0, r: UInt8 = 0
    public var iff1 = false, iff2 = false, im = 0
    public private(set) var halted = false
    /// Level-triggered /INT input.
    public var intLine = false
    /// Edge on /NMI: set to request one non-maskable interrupt.
    public var nmiPending = false
    var eiDelay = false
    /// 0 = HL, 1 = IX, 2 = IY (the DD / FD prefix in effect for the current instruction).
    var idx = 0
    var usedDisplacement = false

    public var readMem: (UInt16) -> UInt8 = { _ in 0xFF }
    public var writeMem: (UInt16, UInt8) -> Void = { _, _ in }
    public var readIO: (UInt16) -> UInt8 = { _ in 0xFF }
    public var writeIO: (UInt16, UInt8) -> Void = { _, _ in }

    static let fS: UInt8 = 0x80, fZ: UInt8 = 0x40, fY: UInt8 = 0x20, fH: UInt8 = 0x10
    static let fX: UInt8 = 0x08, fP: UInt8 = 0x04, fN: UInt8 = 0x02, fC: UInt8 = 0x01

    /// Sign, zero, X/Y bits of a result; `sz53p` adds parity.
    static let sz53: [UInt8] = (0..<256).map { v in UInt8(v & 0xA8) | (v == 0 ? fZ : 0) }
    static let sz53p: [UInt8] = (0..<256).map { v in sz53[v] | (v.nonzeroBitCount & 1 == 0 ? fP : 0) }

    public init() {}

    public func reset() {
        pc = 0; i = 0; r = 0; iff1 = false; iff2 = false; im = 0; halted = false
        eiDelay = false; nmiPending = false
        a = 0xFF; f = 0xFF; sp = 0xFFFF
    }

    // MARK: - Register pairs

    public var af: UInt16 { get { UInt16(a) << 8 | UInt16(f) } set { a = UInt8(newValue >> 8); f = UInt8(truncatingIfNeeded: newValue) } }
    public var bc: UInt16 { get { UInt16(b) << 8 | UInt16(c) } set { b = UInt8(newValue >> 8); c = UInt8(truncatingIfNeeded: newValue) } }
    public var de: UInt16 { get { UInt16(d) << 8 | UInt16(e) } set { d = UInt8(newValue >> 8); e = UInt8(truncatingIfNeeded: newValue) } }
    public var hl: UInt16 { get { UInt16(h) << 8 | UInt16(l) } set { h = UInt8(newValue >> 8); l = UInt8(truncatingIfNeeded: newValue) } }

    /// HL, IX or IY depending on the prefix.
    var hlx: UInt16 {
        get { idx == 0 ? hl : idx == 1 ? ix : iy }
        set { if idx == 0 { hl = newValue } else if idx == 1 { ix = newValue } else { iy = newValue } }
    }

    @inline(__always) func rp(_ p: Int) -> UInt16 {
        switch p { case 0: return bc; case 1: return de; case 2: return hlx; default: return sp }
    }
    @inline(__always) func setRP(_ p: Int, _ v: UInt16) {
        switch p { case 0: bc = v; case 1: de = v; case 2: hlx = v; default: sp = v }
    }
    @inline(__always) func rp2(_ p: Int) -> UInt16 { p == 3 ? af : rp(p) }
    @inline(__always) func setRP2(_ p: Int, _ v: UInt16) { if p == 3 { af = v } else { setRP(p, v) } }

    /// 8-bit register by its opcode number (6 = (HL), handled by the caller). With `plain` false,
    /// H and L mean IXH/IXL or IYH/IYL under a prefix.
    @inline(__always) func reg(_ n: Int, plain: Bool = false) -> UInt8 {
        switch n {
        case 0: return b
        case 1: return c
        case 2: return d
        case 3: return e
        case 4: return plain || idx == 0 ? h : UInt8(hlx >> 8)
        case 5: return plain || idx == 0 ? l : UInt8(truncatingIfNeeded: hlx)
        default: return a
        }
    }
    @inline(__always) func setReg(_ n: Int, _ v: UInt8, plain: Bool = false) {
        switch n {
        case 0: b = v
        case 1: c = v
        case 2: d = v
        case 3: e = v
        case 4: if plain || idx == 0 { h = v } else { hlx = UInt16(v) << 8 | (hlx & 0xFF) }
        case 5: if plain || idx == 0 { l = v } else { hlx = (hlx & 0xFF00) | UInt16(v) }
        default: a = v
        }
    }

    // MARK: - Memory helpers

    @inline(__always) func fetch() -> UInt8 { let v = readMem(pc); pc &+= 1; return v }
    @inline(__always) func fetch16() -> UInt16 { let lo = UInt16(fetch()); return UInt16(fetch()) << 8 | lo }
    @inline(__always) func read16(_ a: UInt16) -> UInt16 { UInt16(readMem(a)) | UInt16(readMem(a &+ 1)) << 8 }
    @inline(__always) func write16(_ a: UInt16, _ v: UInt16) {
        writeMem(a, UInt8(truncatingIfNeeded: v)); writeMem(a &+ 1, UInt8(v >> 8))
    }
    @inline(__always) func push(_ v: UInt16) { sp &-= 2; write16(sp, v) }
    @inline(__always) func pop() -> UInt16 { let v = read16(sp); sp &+= 2; return v }
    @inline(__always) func incR() { r = (r & 0x80) | ((r &+ 1) & 0x7F) }

    /// Address of the (HL) operand: (IX+d) / (IY+d) under a prefix (fetches d).
    @inline(__always) func memAddr() -> UInt16 {
        if idx == 0 { return hl }
        usedDisplacement = true
        let dsp = Int8(bitPattern: fetch())
        return hlx &+ UInt16(bitPattern: Int16(dsp))
    }

    @inline(__always) func cond(_ cc: Int) -> Bool {
        switch cc {
        case 0: return f & Z80.fZ == 0
        case 1: return f & Z80.fZ != 0
        case 2: return f & Z80.fC == 0
        case 3: return f & Z80.fC != 0
        case 4: return f & Z80.fP == 0
        case 5: return f & Z80.fP != 0
        case 6: return f & Z80.fS == 0
        default: return f & Z80.fS != 0
        }
    }

    // MARK: - Arithmetic

    func add8(_ v: UInt8, carry: Bool) {
        let cin = carry && f & Z80.fC != 0 ? 1 : 0
        let res = Int(a) + Int(v) + cin
        let r8 = UInt8(truncatingIfNeeded: res)
        f = Z80.sz53[Int(r8)] | (res > 0xFF ? Z80.fC : 0) | ((a ^ v ^ r8) & Z80.fH)
            | (((a ^ ~v) & (a ^ r8) & 0x80) != 0 ? Z80.fP : 0)
        a = r8
    }

    func sub8(_ v: UInt8, carry: Bool, store: Bool = true) {
        let cin = carry && f & Z80.fC != 0 ? 1 : 0
        let res = Int(a) - Int(v) - cin
        let r8 = UInt8(truncatingIfNeeded: res)
        f = Z80.sz53[Int(r8)] | Z80.fN | (res < 0 ? Z80.fC : 0) | ((a ^ v ^ r8) & Z80.fH)
            | (((a ^ v) & (a ^ r8) & 0x80) != 0 ? Z80.fP : 0)
        if store { a = r8 } else { f = (f & ~(Z80.fX | Z80.fY)) | (v & (Z80.fX | Z80.fY)) }
    }

    func alu(_ op: Int, _ v: UInt8) {
        switch op {
        case 0: add8(v, carry: false)
        case 1: add8(v, carry: true)
        case 2: sub8(v, carry: false)
        case 3: sub8(v, carry: true)
        case 4: a &= v; f = Z80.sz53p[Int(a)] | Z80.fH
        case 5: a ^= v; f = Z80.sz53p[Int(a)]
        case 6: a |= v; f = Z80.sz53p[Int(a)]
        default: sub8(v, carry: false, store: false)
        }
    }

    func inc8(_ v: UInt8) -> UInt8 {
        let r8 = v &+ 1
        f = (f & Z80.fC) | Z80.sz53[Int(r8)] | (r8 & 0x0F == 0 ? Z80.fH : 0) | (r8 == 0x80 ? Z80.fP : 0)
        return r8
    }

    func dec8(_ v: UInt8) -> UInt8 {
        let r8 = v &- 1
        f = (f & Z80.fC) | Z80.fN | Z80.sz53[Int(r8)] | (v & 0x0F == 0 ? Z80.fH : 0) | (r8 == 0x7F ? Z80.fP : 0)
        return r8
    }

    func add16(_ x: UInt16, _ y: UInt16) -> UInt16 {
        let res = Int(x) + Int(y)
        let r16 = UInt16(truncatingIfNeeded: res)
        f = (f & (Z80.fS | Z80.fZ | Z80.fP)) | (res > 0xFFFF ? Z80.fC : 0) | (UInt8(r16 >> 8) & (Z80.fX | Z80.fY))
            | (UInt8(((x ^ y ^ r16) >> 8) & 0xFF) & Z80.fH)
        return r16
    }

    func adc16(_ v: UInt16) {
        let x = hl
        let res = Int(x) + Int(v) + Int(f & Z80.fC)
        let r16 = UInt16(truncatingIfNeeded: res)
        f = (UInt8(r16 >> 8) & (Z80.fS | Z80.fX | Z80.fY)) | (r16 == 0 ? Z80.fZ : 0) | (res > 0xFFFF ? Z80.fC : 0)
            | (UInt8(((x ^ v ^ r16) >> 8) & 0xFF) & Z80.fH)
            | ((~(x ^ v) & (x ^ r16) & 0x8000) != 0 ? Z80.fP : 0)
        hl = r16
    }

    func sbc16(_ v: UInt16) {
        let x = hl
        let res = Int(x) - Int(v) - Int(f & Z80.fC)
        let r16 = UInt16(truncatingIfNeeded: res)
        f = (UInt8(r16 >> 8) & (Z80.fS | Z80.fX | Z80.fY)) | (r16 == 0 ? Z80.fZ : 0) | (res < 0 ? Z80.fC : 0) | Z80.fN
            | (UInt8(((x ^ v ^ r16) >> 8) & 0xFF) & Z80.fH)
            | (((x ^ v) & (x ^ r16) & 0x8000) != 0 ? Z80.fP : 0)
        hl = r16
    }

    func daa() {
        let lo = a & 0x0F
        var diff: UInt8 = 0
        var carry = f & Z80.fC
        if carry != 0 || a > 0x99 { diff = 0x60; carry = Z80.fC }
        if f & Z80.fH != 0 || lo > 9 { diff |= 0x06 }
        let neg = f & Z80.fN
        let half: UInt8
        if neg != 0 { half = f & Z80.fH != 0 && lo < 6 ? Z80.fH : 0 } else { half = lo > 9 ? Z80.fH : 0 }
        a = neg != 0 ? a &- diff : a &+ diff
        f = Z80.sz53p[Int(a)] | neg | carry | half
    }

    /// CB-prefix rotate/shift group.
    func rot(_ op: Int, _ v: UInt8) -> UInt8 {
        let res: UInt8, cy: UInt8
        switch op {
        case 0: cy = v >> 7; res = v << 1 | cy
        case 1: cy = v & 1; res = v >> 1 | cy << 7
        case 2: cy = v >> 7; res = v << 1 | (f & Z80.fC)
        case 3: cy = v & 1; res = v >> 1 | (f & Z80.fC) << 7
        case 4: cy = v >> 7; res = v << 1
        case 5: cy = v & 1; res = v >> 1 | (v & 0x80)
        case 6: cy = v >> 7; res = v << 1 | 1
        default: cy = v & 1; res = v >> 1
        }
        f = Z80.sz53p[Int(res)] | cy
        return res
    }

    func bit(_ n: Int, _ v: UInt8, xy: UInt8) {
        let res = v & (1 << n)
        f = (f & Z80.fC) | Z80.fH | (res == 0 ? (Z80.fZ | Z80.fP) : 0) | (res & Z80.fS) | (xy & (Z80.fX | Z80.fY))
    }

    // MARK: - Execution

    /// Runs one instruction (or takes a pending interrupt); returns the T-states used.
    public func step() -> Int {
        if nmiPending {
            nmiPending = false
            halted = false
            iff1 = false
            incR()
            push(pc)
            pc = 0x66
            return 11
        }
        if intLine && iff1 && !eiDelay {
            iff1 = false; iff2 = false
            halted = false
            incR()
            push(pc)
            if im == 2 {
                pc = read16(UInt16(i) << 8 | 0xFF)
                return 19
            }
            pc = 0x38                                    // IM 1, or IM 0 with $FF (RST 38) on the bus
            return 13
        }
        eiDelay = false
        if halted { incR(); return 4 }
        var op = fetch()
        incR()
        var t = 0
        idx = 0
        while op == 0xDD || op == 0xFD {
            idx = op == 0xDD ? 1 : 2
            t += 4
            op = fetch()
            incR()
        }
        if op == 0xED { idx = 0; return t + executeED() }
        if op == 0xCB {
            if idx != 0 { return t + executeIndexedCB() }
            return t + executeCB()
        }
        usedDisplacement = false
        t += execute(op)
        if usedDisplacement { t += 8 }
        return t
    }

    private func execute(_ op: UInt8) -> Int {
        let x = Int(op >> 6), y = Int(op >> 3) & 7, z = Int(op) & 7, p = y >> 1, q = y & 1
        switch x {
        case 0:
            switch z {
            case 0:
                switch y {
                case 0: return 4
                case 1:
                    swap(&a, &a2); swap(&f, &f2)
                    return 4
                case 2:
                    let dsp = Int8(bitPattern: fetch())
                    b &-= 1
                    if b != 0 { pc = pc &+ UInt16(bitPattern: Int16(dsp)); return 13 }
                    return 8
                case 3:
                    let dsp = Int8(bitPattern: fetch())
                    pc = pc &+ UInt16(bitPattern: Int16(dsp))
                    return 12
                default:
                    let dsp = Int8(bitPattern: fetch())
                    if cond(y - 4) { pc = pc &+ UInt16(bitPattern: Int16(dsp)); return 12 }
                    return 7
                }
            case 1:
                if q == 0 { setRP(p, fetch16()); return 10 }
                hlx = add16(hlx, rp(p))
                return 11
            case 2:
                switch (q, p) {
                case (0, 0): writeMem(bc, a); return 7
                case (0, 1): writeMem(de, a); return 7
                case (0, 2): write16(fetch16(), hlx); return 16
                case (0, _): writeMem(fetch16(), a); return 13
                case (1, 0): a = readMem(bc); return 7
                case (1, 1): a = readMem(de); return 7
                case (1, 2): hlx = read16(fetch16()); return 16
                default: a = readMem(fetch16()); return 13
                }
            case 3:
                setRP(p, q == 0 ? rp(p) &+ 1 : rp(p) &- 1)
                return 6
            case 4, 5:
                if y == 6 {
                    let ad = memAddr()
                    let v = readMem(ad)
                    writeMem(ad, z == 4 ? inc8(v) : dec8(v))
                    return 11
                }
                let v = reg(y)
                setReg(y, z == 4 ? inc8(v) : dec8(v))
                return 4
            case 6:
                if y == 6 {
                    let ad = memAddr()
                    writeMem(ad, fetch())
                    return 10
                }
                setReg(y, fetch())
                return 7
            default:
                switch y {
                case 0:
                    a = a << 1 | a >> 7
                    f = (f & (Z80.fS | Z80.fZ | Z80.fP)) | (a & (Z80.fX | Z80.fY | Z80.fC))
                case 1:
                    let cy = a & 1
                    a = a >> 1 | cy << 7
                    f = (f & (Z80.fS | Z80.fZ | Z80.fP)) | (a & (Z80.fX | Z80.fY)) | cy
                case 2:
                    let cy = a >> 7
                    a = a << 1 | (f & Z80.fC)
                    f = (f & (Z80.fS | Z80.fZ | Z80.fP)) | (a & (Z80.fX | Z80.fY)) | cy
                case 3:
                    let cy = a & 1
                    a = a >> 1 | (f & Z80.fC) << 7
                    f = (f & (Z80.fS | Z80.fZ | Z80.fP)) | (a & (Z80.fX | Z80.fY)) | cy
                case 4: daa()
                case 5:
                    a = ~a
                    f = (f & (Z80.fS | Z80.fZ | Z80.fP | Z80.fC)) | Z80.fH | Z80.fN | (a & (Z80.fX | Z80.fY))
                case 6:
                    f = (f & (Z80.fS | Z80.fZ | Z80.fP)) | Z80.fC | (a & (Z80.fX | Z80.fY))
                default:
                    f = (f & (Z80.fS | Z80.fZ | Z80.fP)) | (f & Z80.fC != 0 ? Z80.fH : Z80.fC) | (a & (Z80.fX | Z80.fY))
                }
                return 4
            }
        case 1:
            if op == 0x76 { halted = true; return 4 }
            if z == 6 {
                let v = readMem(memAddr())
                setReg(y, v, plain: idx != 0)
                return 7
            }
            if y == 6 {
                writeMem(memAddr(), reg(z, plain: idx != 0))
                return 7
            }
            setReg(y, reg(z))
            return 4
        case 2:
            if z == 6 { alu(y, readMem(memAddr())); return 7 }
            alu(y, reg(z))
            return 4
        default:
            switch z {
            case 0:
                if cond(y) { pc = pop(); return 11 }
                return 5
            case 1:
                if q == 0 { setRP2(p, pop()); return 10 }
                switch p {
                case 0: pc = pop(); return 10
                case 1:
                    swap(&b, &b2); swap(&c, &c2); swap(&d, &d2); swap(&e, &e2); swap(&h, &h2); swap(&l, &l2)
                    return 4
                case 2: pc = hlx; return 4
                default: sp = hlx; return 6
                }
            case 2:
                let ad = fetch16()
                if cond(y) { pc = ad }
                return 10
            case 3:
                switch y {
                case 0: pc = fetch16(); return 10
                case 2:
                    let n = fetch()
                    writeIO(UInt16(a) << 8 | UInt16(n), a)
                    return 11
                case 3:
                    let n = fetch()
                    a = readIO(UInt16(a) << 8 | UInt16(n))
                    return 11
                case 4:
                    let v = read16(sp)
                    write16(sp, hlx)
                    hlx = v
                    return 19
                case 5:
                    swap(&d, &h); swap(&e, &l)
                    return 4
                case 6: iff1 = false; iff2 = false; return 4
                default: iff1 = true; iff2 = true; eiDelay = true; return 4
                }
            case 4:
                let ad = fetch16()
                if cond(y) { push(pc); pc = ad; return 17 }
                return 10
            case 5:
                if q == 0 { push(rp2(p)); return 11 }
                let ad = fetch16()
                push(pc); pc = ad
                return 17
            case 6:
                alu(y, fetch())
                return 7
            default:
                push(pc)
                pc = UInt16(y * 8)
                return 11
            }
        }
    }

    private func executeCB() -> Int {
        let op = fetch()
        incR()
        let x = Int(op >> 6), y = Int(op >> 3) & 7, z = Int(op) & 7
        let v = z == 6 ? readMem(hl) : reg(z)
        var res: UInt8
        switch x {
        case 0: res = rot(y, v)
        case 1:
            bit(y, v, xy: z == 6 ? h : v)
            return z == 6 ? 12 : 8
        case 2: res = v & ~(1 << y)
        default: res = v | (1 << y)
        }
        if z == 6 { writeMem(hl, res); return 15 }
        setReg(z, res)
        return 8
    }

    /// DD CB d op / FD CB d op.
    private func executeIndexedCB() -> Int {
        let dsp = Int8(bitPattern: fetch())
        let ad = hlx &+ UInt16(bitPattern: Int16(dsp))
        let op = fetch()
        let x = Int(op >> 6), y = Int(op >> 3) & 7, z = Int(op) & 7
        let v = readMem(ad)
        var res: UInt8
        switch x {
        case 0: res = rot(y, v)
        case 1:
            bit(y, v, xy: UInt8(ad >> 8))
            return 20
        case 2: res = v & ~(1 << y)
        default: res = v | (1 << y)
        }
        writeMem(ad, res)
        if z != 6 { setReg(z, res, plain: true) }       // undocumented copy into a register
        return 23
    }

    private func executeED() -> Int {
        let op = fetch()
        incR()
        let x = Int(op >> 6), y = Int(op >> 3) & 7, z = Int(op) & 7, p = y >> 1, q = y & 1
        if x == 1 {
            switch z {
            case 0:
                let v = readIO(bc)
                f = (f & Z80.fC) | Z80.sz53p[Int(v)]
                if y != 6 { setReg(y, v) }
                return 12
            case 1:
                writeIO(bc, y == 6 ? 0 : reg(y))
                return 12
            case 2:
                if q == 0 { sbc16(rp(p)) } else { adc16(rp(p)) }
                return 15
            case 3:
                let ad = fetch16()
                if q == 0 { write16(ad, rp(p)) } else { setRP(p, read16(ad)) }
                return 20
            case 4:
                let v = a
                a = 0
                sub8(v, carry: false)
                return 8
            case 5:
                iff1 = iff2
                pc = pop()
                return 14
            case 6:
                im = [0, 0, 1, 2][y & 3]
                return 8
            default:
                switch y {
                case 0: i = a; return 9
                case 1: r = a; return 9
                case 2, 3:
                    a = y == 2 ? i : r
                    f = (f & Z80.fC) | Z80.sz53[Int(a)] | (iff2 ? Z80.fP : 0)
                    return 9
                case 4, 5:
                    let m = readMem(hl)
                    if y == 4 {                                    // RRD
                        writeMem(hl, a << 4 | m >> 4)
                        a = (a & 0xF0) | (m & 0x0F)
                    } else {                                       // RLD
                        writeMem(hl, m << 4 | (a & 0x0F))
                        a = (a & 0xF0) | (m >> 4)
                    }
                    f = (f & Z80.fC) | Z80.sz53p[Int(a)]
                    return 18
                default: return 8
                }
            }
        }
        if x == 2 && z <= 3 && y >= 4 {
            let dec = y & 1 != 0
            let repeatOp = y >= 6
            let step: UInt16 = dec ? 0xFFFF : 1
            switch z {
            case 0:                                                 // LDI/LDD/LDIR/LDDR
                let v = readMem(hl)
                writeMem(de, v)
                hl &+= step; de &+= step; bc &-= 1
                let n = v &+ a
                f = (f & (Z80.fS | Z80.fZ | Z80.fC)) | (bc != 0 ? Z80.fP : 0) | (n & Z80.fX) | ((n & 0x02) << 4)
                if repeatOp && bc != 0 { pc &-= 2; return 21 }
                return 16
            case 1:                                                 // CPI/CPD/CPIR/CPDR
                let v = readMem(hl)
                let res = a &- v
                let half = (a ^ v ^ res) & Z80.fH
                hl &+= step; bc &-= 1
                let n = res &- (half != 0 ? 1 : 0)
                f = (f & Z80.fC) | Z80.fN | half | (res == 0 ? Z80.fZ : 0) | (res & Z80.fS)
                    | (bc != 0 ? Z80.fP : 0) | (n & Z80.fX) | ((n & 0x02) << 4)
                if repeatOp && bc != 0 && res != 0 { pc &-= 2; return 21 }
                return 16
            case 2:                                                 // INI/IND/INIR/INDR
                let v = readIO(bc)
                writeMem(hl, v)
                b &-= 1
                hl &+= step
                let k = Int(v) + Int(dec ? c &- 1 : c &+ 1)
                blockIOFlags(v, k)
                if repeatOp && b != 0 { pc &-= 2; return 21 }
                return 16
            default:                                                // OUTI/OUTD/OTIR/OTDR
                let v = readMem(hl)
                b &-= 1
                writeIO(bc, v)
                hl &+= step
                blockIOFlags(v, Int(v) + Int(l))
                if repeatOp && b != 0 { pc &-= 2; return 21 }
                return 16
            }
        }
        return 8                                                    // undefined ED: NOP
    }

    private func blockIOFlags(_ v: UInt8, _ k: Int) {
        f = Z80.sz53[Int(b)] | (v & 0x80 != 0 ? Z80.fN : 0) | (k > 255 ? (Z80.fH | Z80.fC) : 0)
            | (Z80.sz53p[Int(UInt8(k & 7) ^ b)] & Z80.fP)
    }
}
