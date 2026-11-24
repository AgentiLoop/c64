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
        activity &+= 1
        for d in devices { (d as? FastSerialDevice)?.fastSerialIn(byte) }
    }

    /// A byte shifted out by a drive goes to the C128 (if it is listening).
    func driveSentFast(_ byte: UInt8) { hostFastSerialIn?(byte) }

    public private(set) var c64Atn = false
    public private(set) var c64Clock = false
    public private(set) var c64Data = false
    public var devices: [IECDevice] = []
    /// Bumped whenever the host changes a line or sends a fast-serial byte (wakes sleeping drives).
    public private(set) var activity = 0

    public init() {}

    public func reset() {
        c64Atn = false; c64Clock = false; c64Data = false
        driveSeesClock = false; driveSeesData = false
    }

    /// Arguments are the CIA2 output bits (1 = pull the line low, the C64 uses inverters).
    func setC64Lines(atn: Bool, clock: Bool, data: Bool) {
        let atnChanged = atn != c64Atn
        if atnChanged || clock != c64Clock || data != c64Data { activity &+= 1 }
        c64Atn = atn; c64Clock = clock; c64Data = data
        if atnChanged { for d in devices { d.atnChanged(atn) } }
    }

    /// The C64's clock and data outputs as a 1541's port pins see them: a change the C64 makes in
    /// one cycle reaches the drive from the next cycle on (`latchHostLines`, at the end of each
    /// C64 cycle). Cycle-counted 2-bit loaders depend on this: a drive that sees the C64's
    /// request in the same cycle answers a cycle early and the C64 reads the next bit pair.
    private var driveSeesClock = false, driveSeesData = false
    func latchHostLines() { driveSeesClock = c64Clock; driveSeesData = c64Data }
    var clockLineForDrive: Bool {
        if driveSeesClock { return false }
        for d in devices where d.pullsClock { return false }
        return true
    }
    var dataLineForDrive: Bool {
        if driveSeesData { return false }
        for d in devices where d.pullsData { return false }
        return true
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
