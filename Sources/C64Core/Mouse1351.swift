/// Commodore 1351 mouse in control port 1 (proportional mode, as GEOS and most mouse software use it).
///
/// The mouse counts its own movement and shows the low six bits of each axis in the SID's POT
/// registers ($D419 X, $D41A Y) as bits 1–6. A driver reads them about once a frame and works out
/// the movement from the difference to its last read, so a single read may differ from the previous
/// one by at most 31 counts. Host movement is therefore handed out in steps of up to 31 counts per
/// read: a quick sweep arrives over a few frames instead of wrapping around and jumping the wrong way.
/// Y counts up when the mouse moves away from the user (up the screen). The left button is the
/// joystick fire line, the right button the joystick up line.
extension C64 {
    /// Largest change between two reads that a driver can tell apart from a wrap-around.
    static let mouseStep = 31

    /// Moves the mouse by host pointer deltas in mouse counts (`dy` positive = up the screen).
    public func moveMouse(dx: Int, dy: Int) {
        mouseX &+= dx
        mouseY &+= dy
    }

    /// POT X or Y as the 1351 shows it, advancing the reported position toward the mouse.
    func mousePot(y: Bool) -> UInt8 {
        if y {
            potY += max(-C64.mouseStep, min(C64.mouseStep, mouseY - potY))
            return UInt8(truncatingIfNeeded: potY << 1) & 0x7E
        }
        potX += max(-C64.mouseStep, min(C64.mouseStep, mouseX - potX))
        return UInt8(truncatingIfNeeded: potX << 1) & 0x7E
    }

    /// SID register read with the 1351 answering the POT registers.
    @inline(__always) func readSID(_ reg: Int) -> UInt8 {
        if mouse1351 && (reg == 0x19 || reg == 0x1A) { return mousePot(y: reg == 0x1A) }
        return sid.read(reg)
    }

    /// Control port 1 lines pulled low by the joystick and the 1351's buttons (1 = active).
    @inline(__always) var port1Lines: UInt8 {
        guard mouse1351 else { return joystick1 }
        return joystick1 | (mouseLeft ? 0x10 : 0) | (mouseRight ? 0x01 : 0)
    }
}
