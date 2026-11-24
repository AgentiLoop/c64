import Foundation

/// What a disk drive is doing while its LED is on, for the activity light.
public enum DiskActivity: Equatable {
    case idle, reading, writing, appending, deleting, formatting, erasing

    /// Classifies a DOS command or file name as the drive received it ("S0:NAME", "N0:DISK,ID",
    /// "NAME,S,W", "NAME,S,A"…). `headWriting` is true while the head is writing (SAVE sends a
    /// plain name: only the write gate tells it apart from a load).
    public static func classify(command: String, headWriting: Bool) -> DiskActivity {
        let c = command.uppercased()
        func isCommand(_ letter: Character) -> Bool {
            guard c.first == letter, let colon = c.firstIndex(of: ":") else { return false }
            let between = c[c.index(after: c.startIndex)..<colon]       // "", "0", "1", "CRATCH"…
            return between.allSatisfy { $0.isNumber } || c.hasPrefix(letter == "S" ? "SCRATCH" : "NEW")
        }
        if isCommand("N") { return c.contains(",") ? .formatting : .erasing }   // with an ID: full format
        if isCommand("S") { return .deleting }
        let parts = c.split(separator: ",").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.contains(where: { $0.hasPrefix("A") }) { return .appending }
        if headWriting || parts.contains(where: { $0.hasPrefix("W") }) || c.hasPrefix("@") { return .writing }
        return .reading
    }
}

/// Rebuilds the last command / file name the drive's DOS received: the DOS stores the bytes
/// one after another from $0200 (and clears the buffer afterwards, so it is copied here).
struct CommandSniffer {
    private(set) var bytes: [UInt8] = []
    private var len = 0

    mutating func ramWrite(_ a: Int, _ v: UInt8) {
        guard a >= 0x200 && a < 0x22A else { return }
        let i = a - 0x200
        let printable = v >= 0x20 && v < 0x80
        if i == 0 {
            guard printable else { return }
            bytes = [v]; len = 1
        } else if i == len && printable && len > 0 {
            bytes.append(v); len += 1
        }
    }

    var command: String { String(decoding: bytes, as: UTF8.self) }
}
