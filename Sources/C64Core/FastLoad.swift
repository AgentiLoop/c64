/// Instant disk loading: traps the KERNAL LOAD routine and copies the file straight out of
/// the disk image into memory, skipping the slow serial-bus transfer. Loads the KERNAL
/// doesn't handle (directory "$", verify, custom fast loaders) still go to the real drive.
extension C64 {
    static let kernalLoadEntry: UInt16 = 0xF4A5   // after LOAD has stored X/Y in $C3/$C4

    /// Enables or disables instant loading for drives 8 and 9.
    public var fastLoad: Bool {
        get { cpu.trapAddresses.contains(C64.kernalLoadEntry) }
        set {
            if newValue {
                cpu.trapAddresses.insert(C64.kernalLoadEntry)
                cpu.trap = { [unowned(unsafe) self] cpu in self.trapLoad(cpu) }
            } else {
                cpu.trapAddresses.remove(C64.kernalLoadEntry)
            }
        }
    }

    /// Returns true when the load was done here (the CPU then continues after LOAD's RTS).
    func trapLoad(_ cpu: CPU6502<C64>) -> Bool {
        guard c128 == nil, cpu.pc == C64.kernalLoadEntry, hiram, cpu.a == 0 else { return false }
        let device = Int(ram[0xBA])
        let nameLen = Int(ram[0xB7])
        let namePtr = Int(ram[0xBB]) | Int(ram[0xBC]) << 8
        guard nameLen > 0 else { return false }
        var name = (0..<nameLen).map { ram[(namePtr + $0) & 0xFFFF] }
        if name.first == 0x24 { return false }                 // "$" directory: real drive
        if name.first == 0x40 { name.removeFirst() }           // "@"
        if let colon = name.firstIndex(of: 0x3A) { name = Array(name[(colon + 1)...]) }   // "0:"

        let entries: [D64Image.Entry]
        let read: (D64Image.Entry) -> [UInt8]
        if device == 8, !drive8Is1581, let d = drive8?.disk {
            let img = d.dirty ? d.toD64() : d.source
            entries = img.directory(); read = img.readFile
        } else if let d9 = drive9, device == d9.deviceNumber, let img = d9.image {
            entries = img.directory(); read = img.readFile
        } else {
            return false
        }
        let pattern = String(name.map { Character(UnicodeScalar($0 & 0x7F)) })
        guard let entry = entries.first(where: { $0.type & 0x07 != 0 && C64.matches($0.name, pattern) }) else {
            return false   // not found: let the drive report the error
        }
        // DOS never puts file data on the directory track (18); a file starting there is a
        // loader trick (e.g. several names sharing one sector that runs drive code): real drive.
        if entry.track == 18 { return false }
        let file = read(entry)
        guard file.count >= 2 else { return false }

        // Store through the $AE/$AF pointer like the KERNAL (STA ($AE),Y / INC $AE / INC $AF):
        // the address wraps at $FFFF, and a file that overwrites $AE/$AF redirects the rest.
        let start = ram[0xB9] == 0 ? Int(ram[0xC3]) | Int(ram[0xC4]) << 8 : Int(file[0]) | Int(file[1]) << 8
        ram[0xAE] = UInt8(start & 0xFF); ram[0xAF] = UInt8(start >> 8)
        for b in file.dropFirst(2) {
            let a = (Int(ram[0xAE]) | Int(ram[0xAF]) << 8) & 0xFFFF
            if a < 2 { ram[a] = b } else { poke(UInt16(a), b) }
            ram[0xAE] &+= 1
            if ram[0xAE] == 0 { ram[0xAF] &+= 1 }
        }
        let end = Int(ram[0xAE]) | Int(ram[0xAF]) << 8
        ram[0x90] = 0x40                                        // status: end of file
        // Return from LOAD with carry clear and X/Y = end address (pull the JSR return).
        cpu.x = UInt8(end & 0xFF); cpu.y = UInt8(end >> 8)
        cpu.c = false
        cpu.sp &+= 1
        let lo = UInt16(ram[0x100 | Int(cpu.sp)])
        cpu.sp &+= 1
        let hi = UInt16(ram[0x100 | Int(cpu.sp)])
        cpu.pc = (hi << 8 | lo) &+ 1
        return true
    }

    /// Commodore file name matching: `*` matches the rest, `?` any single character.
    static func matches(_ name: String, _ pattern: String) -> Bool {
        let n = Array(name), p = Array(pattern)
        for (i, c) in p.enumerated() {
            if c == "*" { return true }
            if i >= n.count { return false }
            if c != "?" && c != n[i] { return false }
        }
        return n.count == p.count
    }
}
