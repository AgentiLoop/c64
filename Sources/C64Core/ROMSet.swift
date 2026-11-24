import Foundation

/// The Commodore ROM images. They are copyrighted and not shipped with the source; the
/// loader looks in our Application Support folder and the app bundle.
public struct ROMSet {
    public var basic: [UInt8]
    public var kernal: [UInt8]
    public var chargen: [UInt8]
    public var drive1541: [UInt8]?
    public var drive1581: [UInt8]?
    /// 1571 DOS ROM (32 KB); drive 8 is a 1571 in C128 mode when present.
    public var drive1571: [UInt8]?
    /// The C128 ROMs, if all four are present (enables C128 mode).
    public var c128: C128ROMs?

    public init(basic: [UInt8], kernal: [UInt8], chargen: [UInt8], drive1541: [UInt8]? = nil, drive1581: [UInt8]? = nil) {
        self.basic = basic; self.kernal = kernal; self.chargen = chargen
        self.drive1541 = drive1541; self.drive1581 = drive1581
    }

    public static var userROMDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("C64Emu/ROMs", isDirectory: true)
    }

    public static var searchDirectories: [URL] {
        var dirs = [userROMDirectory]
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("ROMs")) }
        return dirs
    }

    /// Finds a ROM by file-name prefix and exact size.
    static func find(prefixes: [String], size: Int, in dirs: [URL]) -> [UInt8]? {
        let fm = FileManager.default
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for prefix in prefixes {
                for f in files.sorted().reversed() where f.lowercased().hasPrefix(prefix) {
                    if let d = fm.contents(atPath: dir.appendingPathComponent(f).path), d.count == size {
                        return [UInt8](d)
                    }
                }
            }
        }
        return nil
    }

    /// Loads the ROM set from the search directories, or nil if a required ROM is missing.
    public static func load(from extra: [URL] = []) -> ROMSet? {
        let dirs = extra + searchDirectories
        guard let basic = find(prefixes: ["basic"], size: 8192, in: dirs),
              let kernal = find(prefixes: ["kernal-901227-03", "kernal"], size: 8192, in: dirs),
              let chargen = find(prefixes: ["chargen-901225", "chargen"], size: 4096, in: dirs)
        else { return nil }
        let d1541 = find(prefixes: ["dos1541-325302-01", "dos1541ii", "dos1541", "1541"], size: 16384, in: dirs)
        let d1581 = find(prefixes: ["dos1581", "1581"], size: 32768, in: dirs)
        let d1571 = find(prefixes: ["dos1571-310654", "dos1571", "1571"], size: 32768, in: dirs)
        var set = ROMSet(basic: basic, kernal: kernal, chargen: chargen, drive1541: d1541, drive1581: d1581)
        set.drive1571 = d1571
        if let k = find(prefixes: ["kernal-318020", "kernal-315078", "kernal-318034", "kernal-325172", "kernal128", "kernal"],
                        size: 16384, in: dirs),
           let lo = find(prefixes: ["basiclo"], size: 16384, in: dirs),
           let hi = find(prefixes: ["basichi"], size: 16384, in: dirs),
           let ch = find(prefixes: ["chargen-390059", "chargen-315079", "chargen128", "chargen"], size: 8192, in: dirs) {
            set.c128 = C128ROMs(kernal: k, basicLo: lo, basicHi: hi, chargen: ch)
        }
        return set
    }
}
