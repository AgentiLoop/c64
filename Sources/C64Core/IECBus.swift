/// Commodore serial (IEC) bus. Lines are open-collector: a line reads high (true) unless
/// any participant pulls it low.
public protocol IECDevice: AnyObject {
    var pullsClock: Bool { get }
    var pullsData: Bool { get }
    /// Called whenever the C64 changes ATN (true = asserted / pulled low).
    func atnChanged(_ asserted: Bool)
}

public final class IECBus {
    public private(set) var c64Atn = false
    public private(set) var c64Clock = false
    public private(set) var c64Data = false
    public var devices: [IECDevice] = []

    public init() {}

    public func reset() {
        c64Atn = false; c64Clock = false; c64Data = false
    }

    /// Arguments are the CIA2 output bits (1 = pull the line low, the C64 uses inverters).
    func setC64Lines(atn: Bool, clock: Bool, data: Bool) {
        let atnChanged = atn != c64Atn
        c64Atn = atn; c64Clock = clock; c64Data = data
        if atnChanged { for d in devices { d.atnChanged(atn) } }
    }

    /// True = ATN line high (released).
    public var atnLine: Bool { !c64Atn }
    public var clockLine: Bool {
        if c64Clock { return false }
        for d in devices where d.pullsClock { return false }
        return true
    }
    public var dataLine: Bool {
        if c64Data { return false }
        for d in devices where d.pullsData { return false }
        return true
    }
}
