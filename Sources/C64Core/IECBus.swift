/// Commodore serial (IEC) bus. Lines are open-collector: a line reads high (true) unless
/// any participant pulls it low.
public protocol IECDevice: AnyObject {
    var pullsClock: Bool { get }
    var pullsData: Bool { get }
    /// Called whenever the C64 changes ATN (true = asserted / pulled low).
    func atnChanged(_ asserted: Bool)
}

/// A drive with a fast serial port (1571/1581): bytes arrive through its CIA's serial register.
public protocol FastSerialDevice: IECDevice {
    func fastSerialIn(_ byte: UInt8)
}

public final class IECBus {
    /// The C128's side of the fast serial line (nil on a C64, which has no fast serial).
    var hostFastSerialIn: ((UInt8) -> Void)?

    /// A byte shifted out by the host (C128 CIA1 with FSDIR = output) goes to every fast drive.
    func hostSentFast(_ byte: UInt8) {
        for d in devices { (d as? FastSerialDevice)?.fastSerialIn(byte) }
    }

    /// A byte shifted out by a drive goes to the C128 (if it is listening).
    func driveSentFast(_ byte: UInt8) { hostFastSerialIn?(byte) }

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
