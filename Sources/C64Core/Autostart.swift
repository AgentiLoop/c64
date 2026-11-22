/// Helpers for starting software.
public enum C64Autostart {
    /// Runs the machine until the KERNAL has finished its power-on sequence (READY prompt).
    public static func ensureBooted(_ c64: C64) {
        let needed = UInt64(c64.clockHz) * 5 / 2
        while c64.cycles - c64.resetCycle < needed { c64.runFrame() }
    }
}
