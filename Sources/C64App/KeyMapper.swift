import AppKit
import C64Core

/// Translates Mac keyboard events into C64 matrix presses. Letters, digits, RETURN, SPACE, etc.
/// map positionally; punctuation maps by the character typed so the symbol printed on the Mac
/// keycap is what appears on the C64 (overriding SHIFT where needed).
final class KeyMapper {
    struct Press { let keys: [C64Key]; let shift: Bool? }

    private var active: [UInt16: Press] = [:]
    private var macShift = false
    private(set) var joystickBits: UInt8 = 0
    var cursorKeysAsJoystick = false
    /// Called with (key, pressed) to change the matrix.
    let apply: (C64Key, Bool) -> Void

    init(apply: @escaping (C64Key, Bool) -> Void) { self.apply = apply }

    static let special: [UInt16: Press] = [
        36: Press(keys: [.ret], shift: nil),
        76: Press(keys: [.ret], shift: nil),
        51: Press(keys: [.delete], shift: nil),
        117: Press(keys: [.delete], shift: true),     // forward delete = INST
        53: Press(keys: [.runStop], shift: nil),      // Esc = RUN/STOP
        49: Press(keys: [.space], shift: nil),
        124: Press(keys: [.cursorRight], shift: false),
        123: Press(keys: [.cursorRight], shift: true),
        125: Press(keys: [.cursorDown], shift: false),
        126: Press(keys: [.cursorDown], shift: true),
        115: Press(keys: [.home], shift: nil),
        122: Press(keys: [.f1], shift: false), 120: Press(keys: [.f1], shift: true),
        99: Press(keys: [.f3], shift: false), 118: Press(keys: [.f3], shift: true),
        96: Press(keys: [.f5], shift: false), 97: Press(keys: [.f5], shift: true),
        98: Press(keys: [.f7], shift: false), 100: Press(keys: [.f7], shift: true),
        116: Press(keys: [.restore], shift: nil),     // Page Up = RESTORE
        48: Press(keys: [.control], shift: nil),      // Tab = CTRL
    ]

    static func pressFor(character ch: Character) -> Press? {
        let letters: [Character: C64Key] = [
            "a": .a, "b": .b, "c": .c, "d": .d, "e": .e, "f": .f, "g": .g, "h": .h, "i": .i, "j": .j,
            "k": .k, "l": .l, "m": .m, "n": .n, "o": .o, "p": .p, "q": .q, "r": .r, "s": .s, "t": .t,
            "u": .u, "v": .v, "w": .w, "x": .x, "y": .y, "z": .z,
        ]
        if let k = letters[Character(ch.lowercased())] { return Press(keys: [k], shift: nil) }
        let table: [Character: (C64Key, Bool)] = [
            "1": (.k1, false), "2": (.k2, false), "3": (.k3, false), "4": (.k4, false), "5": (.k5, false),
            "6": (.k6, false), "7": (.k7, false), "8": (.k8, false), "9": (.k9, false), "0": (.k0, false),
            "!": (.k1, true), "\"": (.k2, true), "#": (.k3, true), "$": (.k4, true), "%": (.k5, true),
            "&": (.k6, true), "'": (.k7, true), "(": (.k8, true), ")": (.k9, true),
            "+": (.plus, false), "-": (.minus, false), "*": (.asterisk, false), "/": (.slash, false),
            "=": (.equals, false), ":": (.colon, false), ";": (.semicolon, false), ",": (.comma, false),
            ".": (.period, false), "@": (.at, false), "<": (.comma, true), ">": (.period, true),
            "?": (.slash, true), "[": (.colon, true), "]": (.semicolon, true), "^": (.upArrow, false),
            "\\": (.pound, false), "£": (.pound, false), "`": (.leftArrow, false), "_": (.leftArrow, false),
            "~": (.upArrow, true), "{": (.plus, true), "}": (.minus, true), "|": (.pound, true),
        ]
        if let (k, s) = table[ch] { return Press(keys: [k], shift: s) }
        return nil
    }

    // Joystick bits: 0 up, 1 down, 2 left, 3 right, 4 fire
    static let joystickKeys: [UInt16: UInt8] = [91: 0x01, 84: 0x02, 86: 0x04, 88: 0x08, 82: 0x10, 87: 0x10,
                                               89: 0x05, 92: 0x09, 83: 0x06, 85: 0x0A]
    static let cursorJoystick: [UInt16: UInt8] = [126: 0x01, 125: 0x02, 123: 0x04, 124: 0x08]

    /// Returns true if handled.
    func keyDown(_ event: NSEvent) -> Bool {
        if let j = KeyMapper.joystickKeys[event.keyCode] { joystickBits |= j; return true }
        if cursorKeysAsJoystick, let j = KeyMapper.cursorJoystick[event.keyCode] { joystickBits |= j; return true }
        if event.isARepeat { return true }
        let press: Press?
        if let p = KeyMapper.special[event.keyCode] {
            press = p
        } else if let ch = event.characters?.first {
            press = KeyMapper.pressFor(character: ch)
        } else {
            press = nil
        }
        guard let p = press else { return false }
        macShift = event.modifierFlags.contains(.shift)
        if let old = active[event.keyCode] { for k in old.keys { apply(k, false) } }
        active[event.keyCode] = p
        updateShift()   // SHIFT state must reach the matrix before the key itself
        for k in p.keys { apply(k, true) }
        return true
    }

    func keyUp(_ event: NSEvent) {
        if let j = KeyMapper.joystickKeys[event.keyCode] { joystickBits &= ~j; return }
        if let j = KeyMapper.cursorJoystick[event.keyCode], cursorKeysAsJoystick { joystickBits &= ~j; return }
        guard let p = active.removeValue(forKey: event.keyCode) else { return }
        for k in p.keys {
            // Only release if no other active press still uses the key.
            if !active.values.contains(where: { $0.keys.contains(k) }) { apply(k, false) }
        }
        updateShift()
    }

    func flagsChanged(_ event: NSEvent) {
        let f = event.modifierFlags
        macShift = f.contains(.shift)
        // Device-dependent bits: 0x20 = left option (C= key), 0x40 = right option (joystick fire).
        apply(.commodore, f.rawValue & 0x20 != 0)
        apply(.control, f.contains(.control))
        if f.rawValue & 0x40 != 0 { joystickBits |= 0x10 } else { joystickBits &= ~0x10 }
        updateShift()
    }

    func releaseAll() {
        active.removeAll()
        joystickBits = 0
        macShift = false
    }

    private func updateShift() {
        var shift = macShift
        if let forced = active.values.compactMap({ $0.shift }).last { shift = forced }
        apply(.leftShift, shift)
        if !shift { apply(.rightShift, false) }
    }
}
