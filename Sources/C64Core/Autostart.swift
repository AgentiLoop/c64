/// Helpers for starting software.
public enum C64Autostart {
    /// Runs the machine until the KERNAL has finished its power-on sequence (READY prompt).
    public static func ensureBooted(_ c64: C64) {
        // The C128 also checks drive 8 for a boot disk before READY.
        let needed = UInt64(c64.clockHz) * (c64.isC128 ? 4 : 5) / 2 + (c64.isC128 ? UInt64(c64.clockHz) : 0)
        while c64.cycles - c64.resetCycle < needed { c64.runFrame() }
    }
}
