import Foundation

/// The C128's 80-column picture, from the 8563 VDC (`VDC8563`).
extension C64 {
    public static let vdcWidth = 640
    public static let vdcHeight = 200
    static let rgbi = VDC8563.rgbi

    /// True while the 80-column screen should be shown: the KERNAL's active screen is the 80-column
    /// one (40/80 key at reset, ESC X), or a program that draws on the VDC switched the VIC-II's
    /// display off (bit 4 of $D011), as VDC demos and games do — on a real C128 the other monitor
    /// would show their picture. A 40-column game that uses $D7 for its own data, or blanks the
    /// VIC-II between screens, stays on the 40-column screen.
    public var showing80Columns: Bool {
        guard let m = c128 else { return false }
        return m.mode80 || (m.programUsesVDC && vic.read(0x11) & 0x10 == 0)
    }

    /// Makes the C128's screen editor print on the 80-column (VDC) or 40-column (VIC-II) screen,
    /// as typing ESC X does: ESC ($1B) and X go into the keyboard buffer, so the KERNAL swaps
    /// screens the next time it reads the keyboard (at READY, INPUT or GET). Does nothing on the C64
    /// or when that screen is already active.
    public func switchC128Screen(to80: Bool) {
        guard let m = c128, m.mode80 != to80 else { return }
        typeQueue += [0x1B, 0x58]
    }

    /// The 40/80 DISPLAY key: down makes the C128 start in 80 columns (read at reset).
    public var key4080Down: Bool {
        get { c128?.key4080Down ?? false }
        set { c128?.key4080Down = newValue }
    }

    /// Size of the last completed VDC picture (640x200 with the KERNAL's settings).
    public var vdcPictureSize: (width: Int, height: Int) {
        guard let v = c128?.vdc else { return (C64.vdcWidth, C64.vdcHeight) }
        return (v.pictureWidth, v.pictureHeight)
    }

    /// Whether the VDC draws its picture (turn off while only the 40-column screen is shown).
    public var vdcDrawing: Bool {
        get { c128?.vdc.drawing ?? false }
        set { c128?.vdc.drawing = newValue }
    }

    /// Sequence number of the last completed VDC picture.
    public var vdcPictureCount: UInt64 { c128?.vdc.pictureCount ?? 0 }

    /// Copies the last completed VDC picture into `buffer` (`vdcPictureSize`, 0xAARRGGBB).
    public func renderVDC(into buffer: inout [UInt32]) {
        guard let v = c128?.vdc else { return }
        buffer = v.picture
    }

    /// The 80-column text screen as ASCII lines (for tests and debugging).
    public func vdcText() -> [String] { c128?.vdc.text() ?? [] }

    /// 80-column chip state for debugging: 64 register bytes followed by the 64K of VDC RAM.
    public func vdcDump() -> Data? {
        guard let v = c128?.vdc else { return nil }
        return Data(v.regs + v.ram)
    }
}
