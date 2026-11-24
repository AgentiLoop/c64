/// Keys of the C64 keyboard with their matrix position (row = CIA1 PA bit, column = PB bit).
/// After RESTORE come the C128's extra keys: their rows are the VIC-IIe's K0–K2 lines ($D02F bits
/// 0–2), read through CIA1 port B like the others. A C64 never drives those lines.
public enum C64Key: CaseIterable {
    case delete, ret, cursorRight, f7, f1, f3, f5, cursorDown
    case k3, w, a, k4, z, s, e, leftShift
    case k5, r, d, k6, c, f, t, x
    case k7, y, g, k8, b, h, u, v
    case k9, i, j, k0, m, k, o, n
    case plus, p, l, minus, period, colon, at, comma
    case pound, asterisk, semicolon, home, rightShift, equals, upArrow, slash
    case k1, leftArrow, control, k2, space, commodore, q, runStop
    case restore
    // C128: K0, K1, K2
    case help, kp8, kp5, tab, kp2, kp4, kp7, kp1
    case esc, kpPlus, kpMinus, lineFeed, kpEnter, kp6, kp9, kp3
    case alt, kp0, kpPeriod, up128, down128, left128, right128, noScroll

    static let indices: [C64Key: Int] = Dictionary(uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })

    /// Position in the matrix, 0...63 (64 = RESTORE, which is not part of the matrix; 65... C128 keys).
    public var matrixIndex: Int { C64Key.indices[self]! }

    /// Row 0–7 (CIA1 port A) or 8–10 (C128 K0–K2), column = CIA1 port B bit.
    public var matrix: (row: Int, col: Int) {
        var idx = matrixIndex
        if idx > 64 { idx -= 1 }
        return (idx / 8, idx % 8)
    }
}
