/// Keys of the C64 keyboard with their matrix position (row = CIA1 PA bit, column = PB bit).
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

    static let indices: [C64Key: Int] = Dictionary(uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })

    /// Position in the matrix, 0...63 (64 = RESTORE, which is not part of the matrix).
    public var matrixIndex: Int { C64Key.indices[self]! }

    public var matrix: (row: Int, col: Int) {
        let idx = matrixIndex
        return (idx / 8, idx % 8)
    }
}
