/// MOS 6522 Versatile Interface Adapter (as used twice in the 1541): two ports, two timers,
/// CA1/CB1 edge interrupts, CA2/CB2 manual outputs.
public final class VIA6522 {
    public var ora: UInt8 = 0
    public var orb: UInt8 = 0
    public var ddra: UInt8 = 0
    public var ddrb: UInt8 = 0
    var t1Counter: UInt16 = 0xFFFF
    var t1Latch: UInt16 = 0xFFFF
    var t1Armed = false
    var t1Reload = false
    var t2Counter: UInt16 = 0xFFFF
    var t2LatchLo: UInt8 = 0xFF
    var t2Armed = false
    var sr: UInt8 = 0
    public var acr: UInt8 = 0
    public var pcr: UInt8 = 0
    public var ifr: UInt8 = 0
    public var ier: UInt8 = 0
    var ca1 = false

    public var portAIn: () -> UInt8 = { 0xFF }
    public var portBIn: () -> UInt8 = { 0xFF }

    public init() {}

    public func reset() {
        ora = 0; orb = 0; ddra = 0; ddrb = 0
        t1Armed = false; t1Reload = false; t2Armed = false
        acr = 0; pcr = 0; ifr = 0; ier = 0; sr = 0
    }

    @inline(__always) public var irq: Bool { ifr & ier & 0x7F != 0 }
    /// CA2 pin level (high unless in manual-low output mode).
    @inline(__always) public var ca2High: Bool { pcr & 0x0E != 0x0C }
    /// CB2 pin level (high unless in manual-low output mode).
    @inline(__always) public var cb2High: Bool { pcr & 0xE0 != 0xC0 }
    @inline(__always) public var portBOutput: UInt8 { orb & ddrb }
    @inline(__always) public var portAOutput: UInt8 { ora & ddra }

    /// Sets the CA1 input level; the active edge (PCR bit 0) raises the interrupt flag.
    public func setCA1(_ level: Bool) {
        guard level != ca1 else { return }
        ca1 = level
        if level == (pcr & 0x01 != 0) { ifr |= 0x02 }
    }

    /// Pulses CA1 (an active edge happens regardless of the configured polarity).
    @inline(__always) public func pulseCA1() { ifr |= 0x02 }

    @inline(__always) public func tick() {
        if t1Reload {
            t1Counter = t1Latch
            t1Reload = false
        } else {
            t1Counter &-= 1
            if t1Counter == 0xFFFF {
                if acr & 0x40 != 0 { ifr |= 0x40; t1Reload = true }
                else if t1Armed { ifr |= 0x40; t1Armed = false }
            }
        }
        if acr & 0x20 == 0 {
            t2Counter &-= 1
            if t2Counter == 0xFFFF && t2Armed { ifr |= 0x20; t2Armed = false }
        }
    }

    public func read(_ reg: Int) -> UInt8 {
        switch reg & 0x0F {
        case 0x0:
            ifr &= ~0x18
            return (orb & ddrb) | (portBIn() & ~ddrb)
        case 0x1:
            ifr &= ~0x03
            return (ora & ddra) | (portAIn() & ~ddra)
        case 0x2: return ddrb
        case 0x3: return ddra
        case 0x4: ifr &= ~0x40; return UInt8(t1Counter & 0xFF)
        case 0x5: return UInt8(t1Counter >> 8)
        case 0x6: return UInt8(t1Latch & 0xFF)
        case 0x7: return UInt8(t1Latch >> 8)
        case 0x8: ifr &= ~0x20; return UInt8(t2Counter & 0xFF)
        case 0x9: return UInt8(t2Counter >> 8)
        case 0xA: return sr
        case 0xB: return acr
        case 0xC: return pcr
        case 0xD: return ifr | (irq ? 0x80 : 0)
        case 0xE: return ier | 0x80
        default: return (ora & ddra) | (portAIn() & ~ddra)
        }
    }

    public func write(_ reg: Int, _ v: UInt8) {
        switch reg & 0x0F {
        case 0x0: orb = v; ifr &= ~0x18
        case 0x1: ora = v; ifr &= ~0x03
        case 0x2: ddrb = v
        case 0x3: ddra = v
        case 0x4, 0x6: t1Latch = (t1Latch & 0xFF00) | UInt16(v)
        case 0x5:
            t1Latch = (t1Latch & 0x00FF) | UInt16(v) << 8
            t1Counter = t1Latch
            t1Reload = false
            t1Armed = true
            ifr &= ~0x40
        case 0x7:
            t1Latch = (t1Latch & 0x00FF) | UInt16(v) << 8
            ifr &= ~0x40
        case 0x8: t2LatchLo = v
        case 0x9:
            t2Counter = UInt16(v) << 8 | UInt16(t2LatchLo)
            t2Armed = true
            ifr &= ~0x20
        case 0xA: sr = v
        case 0xB: acr = v
        case 0xC: pcr = v
        case 0xD: ifr &= ~(v & 0x7F)
        case 0xE:
            if v & 0x80 != 0 { ier |= v & 0x7F } else { ier &= ~(v & 0x7F) }
        default: ora = v
        }
    }
}
