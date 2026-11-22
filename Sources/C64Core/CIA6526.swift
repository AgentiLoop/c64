// MOS 6526 Complex Interface Adapter: two 8-bit ports, two 16-bit timers, time-of-day clock,
// serial shift register and interrupt control.

public final class CIA6526 {
    public var pra: UInt8 = 0
    public var prb: UInt8 = 0
    public var ddra: UInt8 = 0
    public var ddrb: UInt8 = 0

    /// External input levels for the ports (wired-AND with the outputs).
    public var portAIn: () -> UInt8 = { 0xFF }
    public var portBIn: () -> UInt8 = { 0xFF }
    /// Called whenever port A output changes (used for the IEC bus / VIC bank).
    public var portAChanged: (() -> Void)?

    public private(set) var irq = false

    var timerA: UInt16 = 0xFFFF
    var latchA: UInt16 = 0xFFFF
    var timerB: UInt16 = 0xFFFF
    var latchB: UInt16 = 0xFFFF
    var cra: UInt8 = 0
    var crb: UInt8 = 0
    var icrData: UInt8 = 0
    var icrMask: UInt8 = 0
    var pb6Toggle = false
    var pb7Toggle = false
    var pb6Pulse = false
    var pb7Pulse = false
    var startDelayA = 0
    var startDelayB = 0

    // Serial data register
    var sdr: UInt8 = 0
    var sdrShiftCount = 0

    // Time of day (BCD)
    var todTenths: UInt8 = 0, todSec: UInt8 = 0, todMin: UInt8 = 0, todHr: UInt8 = 1
    var alarmTenths: UInt8 = 0, alarmSec: UInt8 = 0, alarmMin: UInt8 = 0, alarmHr: UInt8 = 0
    var todLatched = false
    var latch: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    var todStopped = true
    var todDivider = 0

    public init() {}

    public func reset() {
        pra = 0; prb = 0; ddra = 0; ddrb = 0
        timerA = 0xFFFF; latchA = 0xFFFF; timerB = 0xFFFF; latchB = 0xFFFF
        cra = 0; crb = 0; icrData = 0; icrMask = 0; irq = false
        sdr = 0; sdrShiftCount = 0
        todTenths = 0; todSec = 0; todMin = 0; todHr = 1; todStopped = true; todLatched = false
        portAChanged?()
    }

    /// Port A as seen on the pins.
    public var portAOutput: UInt8 { (pra & ddra) | ~ddra }
    public var portBOutput: UInt8 { (prb & ddrb) | ~ddrb }

    private func setInterrupt(_ bit: UInt8) {
        icrData |= bit
        if icrData & icrMask & 0x1F != 0 { irq = true }
    }

    /// Falling edge on the FLAG pin.
    public func triggerFlag() { setInterrupt(0x10) }

    /// One phi2 clock cycle.
    @inline(__always) public func tick() {
        pb6Pulse = false
        pb7Pulse = false
        var underflowA = false
        if cra & 0x01 != 0 {
            if startDelayA > 0 {
                startDelayA -= 1
            } else if cra & 0x20 == 0 {
                if timerA == 0 {
                    underflowA = true
                    timerA = latchA
                    if cra & 0x08 != 0 { cra &= ~0x01 }
                } else {
                    timerA &-= 1
                }
            }
        }
        if underflowA {
            setInterrupt(0x01)
            pb6Pulse = true
            pb6Toggle.toggle()
            if cra & 0x40 != 0 && sdrShiftCount > 0 {
                sdrShiftCount -= 1
                if sdrShiftCount == 0 { setInterrupt(0x08) }
            }
        }
        if crb & 0x01 != 0 {
            if startDelayB > 0 {
                startDelayB -= 1
                return
            }
            let mode = (crb >> 5) & 3
            let count = mode == 0 || (mode >= 2 && underflowA)
            if count {
                if timerB == 0 {
                    timerB = latchB
                    if crb & 0x08 != 0 { crb &= ~0x01 }
                    setInterrupt(0x02)
                    pb7Pulse = true
                    pb7Toggle.toggle()
                } else {
                    timerB &-= 1
                }
            }
        }
    }

    /// Called at the mains frequency (50 Hz PAL / 60 Hz NTSC). The pin is divided by 5 or 6
    /// depending on CRA bit 7, like the real chip.
    public func tickTOD() {
        if todStopped { return }
        todDivider += 1
        if todDivider < ((cra & 0x80) != 0 ? 5 : 6) { return }
        todDivider = 0
        todTenths = (todTenths + 1)
        if todTenths >= 10 {
            todTenths = 0
            todSec = bcdInc(todSec)
            if todSec == 0x60 {
                todSec = 0
                todMin = bcdInc(todMin)
                if todMin == 0x60 {
                    todMin = 0
                    var pm = todHr & 0x80
                    var h = todHr & 0x1F
                    if h == 0x11 { pm ^= 0x80 }
                    h = bcdInc(h)
                    if h == 0x13 { h = 1 }
                    todHr = pm | h
                }
            }
        }
        if todTenths == alarmTenths && todSec == alarmSec && todMin == alarmMin && todHr == alarmHr {
            setInterrupt(0x04)
        }
    }

    private func bcdInc(_ v: UInt8) -> UInt8 {
        var r = v &+ 1
        if r & 0x0F > 9 { r = (r & 0xF0) &+ 0x10 }
        return r
    }

    public func read(_ reg: Int) -> UInt8 {
        switch reg & 0x0F {
        case 0x0: return (pra | ~ddra) & portAIn()
        case 0x1:
            var v = (prb | ~ddrb) & portBIn()
            if cra & 0x02 != 0 {
                v &= ~0x40
                if cra & 0x04 != 0 ? pb6Toggle : pb6Pulse { v |= 0x40 }
            }
            if crb & 0x02 != 0 {
                v &= ~0x80
                if crb & 0x04 != 0 ? pb7Toggle : pb7Pulse { v |= 0x80 }
            }
            return v
        case 0x2: return ddra
        case 0x3: return ddrb
        case 0x4: return UInt8(timerA & 0xFF)
        case 0x5: return UInt8(timerA >> 8)
        case 0x6: return UInt8(timerB & 0xFF)
        case 0x7: return UInt8(timerB >> 8)
        case 0x8:
            let v = todLatched ? latch.0 : todTenths
            todLatched = false
            return v
        case 0x9: return todLatched ? latch.1 : todSec
        case 0xA: return todLatched ? latch.2 : todMin
        case 0xB:
            if !todLatched { latch = (todTenths, todSec, todMin, todHr); todLatched = true }
            return latch.3
        case 0xC: return sdr
        case 0xD:
            let v = icrData | (irq ? 0x80 : 0)
            icrData = 0
            irq = false
            return v
        case 0xE: return cra & ~0x10
        default: return crb & ~0x10
        }
    }

    public func write(_ reg: Int, _ value: UInt8) {
        switch reg & 0x0F {
        case 0x0: pra = value; portAChanged?()
        case 0x1: prb = value
        case 0x2: ddra = value; portAChanged?()
        case 0x3: ddrb = value
        case 0x4: latchA = (latchA & 0xFF00) | UInt16(value)
        case 0x5:
            latchA = (latchA & 0x00FF) | UInt16(value) << 8
            if cra & 0x01 == 0 { timerA = latchA }
        case 0x6: latchB = (latchB & 0xFF00) | UInt16(value)
        case 0x7:
            latchB = (latchB & 0x00FF) | UInt16(value) << 8
            if crb & 0x01 == 0 { timerB = latchB }
        case 0x8:
            if crb & 0x80 != 0 { alarmTenths = value & 0x0F } else { todTenths = value & 0x0F; todStopped = false }
        case 0x9:
            if crb & 0x80 != 0 { alarmSec = value & 0x7F } else { todSec = value & 0x7F }
        case 0xA:
            if crb & 0x80 != 0 { alarmMin = value & 0x7F } else { todMin = value & 0x7F }
        case 0xB:
            if crb & 0x80 != 0 { alarmHr = value & 0x9F } else { todHr = value & 0x9F; todStopped = true }
        case 0xC:
            sdr = value
            if cra & 0x40 != 0 { sdrShiftCount = 16 }
        case 0xD:
            if value & 0x80 != 0 { icrMask |= value & 0x1F } else { icrMask &= ~(value & 0x1F) }
            if icrData & icrMask & 0x1F != 0 { irq = true }
        case 0xE:
            if value & 0x01 != 0 && cra & 0x01 == 0 { startDelayA = 1; pb6Toggle = true }
            if value & 0x10 != 0 { timerA = latchA }
            cra = value & ~0x10
        default:
            if value & 0x01 != 0 && crb & 0x01 == 0 { startDelayB = 1; pb7Toggle = true }
            if value & 0x10 != 0 { timerB = latchB }
            crb = value & ~0x10
        }
    }
}
