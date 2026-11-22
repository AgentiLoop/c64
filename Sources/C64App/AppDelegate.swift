import AppKit
import AutoUpdateKit
import GameController
import UniformTypeIdentifiers
import C64Core

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Checks GitHub releases (tags vX.Y.Z, asset C64.app.zip) and installs Developer ID–signed updates.
    var updater: AutoUpdater!
    var window: NSWindow!
    var view: EmulatorView!
    var runner: EmulatorRunner!
    var keyMapper: KeyMapper!
    let audio = AudioOutput()
    var joystickPort = 2
    var warpItem: NSMenuItem!
    var cursorJoyItem: NSMenuItem!
    var swapItem: NSMenuItem!
    /// The D64 file currently in drive 8 and its GCR disk (written back when changed).
    var diskURL: URL?
    var disk: GCRDisk?
    /// The D81 file in drive 9 (1581) and its image.
    var disk9URL: URL?
    var disk9: D81Image?
    var baseTitle = "C64"
    var lastLED = false
    var lastTape = false
    /// The TAP file in the Datasette (recordings are written back to it).
    var tapeURL: URL?
    var pendingOpen: URL?
    var fastLoadItem: NSMenuItem!
    var borderItems: [NSMenuItem] = []
    var standardItems: [NSMenuItem] = []

    /// Border sizes: full PAL picture, a thin border, or just the 320×200 screen.
    static let borderCrops: [(String, CGRect)] = [
        ("Full Border", CGRect(x: 0, y: 0, width: 384, height: 272)),
        ("Small Border", CGRect(x: 16, y: 20, width: 352, height: 232)),
        ("No Border", CGRect(x: 32, y: 36, width: 320, height: 200)),
    ]
    var diskWarpItem: NSMenuItem!
    /// User-port modem connected to the internet (telnet BBSes).
    var modemLink: ModemLink!
    var hangUpItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        updater = AutoUpdater(configuration: AutoUpdateConfiguration(
            appName: "C64",
            repository: "AgentiLoop/c64",
            tagPrefix: "v",
            isUpdateAsset: { $0 == "C64.app.zip" },
            teamID: "469UCUB275"
        ))
        updater.start()
        guard let roms = loadROMs() else { NSApp.terminate(nil); return }
        let c64 = C64(roms: roms)
        c64.fastLoad = UserDefaults.standard.object(forKey: "FastLoad") as? Bool ?? true
        if let raw = UserDefaults.standard.string(forKey: "VideoStandard"),
           let std = VideoStandard(rawValue: raw), std != .pal {
            c64.standard = std
        }
        for item in standardItems { item.state = item.representedObject as? String == c64.standard.rawValue ? .on : .off }
        runner = EmulatorRunner(c64: c64, audio: audio)
        modemLink = ModemLink(runner: runner)
        modemLink.onStatus = { [weak self] host in
            self?.hangUpItem.title = host.map { "Hang Up (\($0))" } ?? "Hang Up"
        }
        runner.warpWhileDisk = UserDefaults.standard.object(forKey: "WarpWhileDisk") as? Bool ?? true
        fastLoadItem.state = c64.fastLoad ? .on : .off
        diskWarpItem.state = runner.warpWhileDisk ? .on : .off

        let scale: CGFloat = 2
        let size = NSSize(width: CGFloat(VICII.screenWidth) * scale * 0.94, height: CGFloat(VICII.screenHeight) * scale)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "C64"
        window.contentAspectRatio = size
        window.delegate = self
        view = EmulatorView(frame: NSRect(origin: .zero, size: size))
        view.runner = runner
        keyMapper = KeyMapper { [weak self] key, pressed in
            self?.runner.perform { $0.setKey(key, pressed: pressed) }
        }
        view.keyMapper = keyMapper
        view.onFileDrop = { [weak self] url in self?.open(url: url) }
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        window.setFrameAutosaveName("C64MainWindow")
        applyBorder(UserDefaults.standard.integer(forKey: "BorderMode"))

        runner.onFrame = { [weak self] in self?.frameTick() }
        audio.start()
        runner.start()
        if let url = pendingOpen { pendingOpen = nil; open(url: url) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        saveTapeIfNeeded()   // needs the emulation thread still running
        runner?.stop()
        saveDiskIfNeeded()
        saveDisk9IfNeeded()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        // Finder may deliver the file before the machine exists; open it after launch.
        if runner == nil { pendingOpen = url; return true }
        open(url: url)
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        keyMapper?.releaseAll()
        runner?.perform { $0.releaseAllKeys(); $0.joystick1 = 0; $0.joystick2 = 0 }
    }

    // MARK: - Frame tick (main thread)

    private func frameTick() {
        view.refresh()
        let led = (runner.c64.drive8?.ledOn ?? false) || (runner.c64.drive9?.ledOn ?? false)
        let tape = runner.c64.datasette.mode != .stopped && runner.c64.cassetteMotor
        if led != lastLED || tape != lastTape {
            lastLED = led
            lastTape = tape
            window.title = (led ? "● " : "") + (tape ? "▶ " : "") + baseTitle
        }
        var bits = keyMapper.joystickBits
        for pad in GCController.controllers() {
            if let gp = pad.extendedGamepad {
                if gp.dpad.up.isPressed || gp.leftThumbstick.yAxis.value > 0.5 { bits |= 0x01 }
                if gp.dpad.down.isPressed || gp.leftThumbstick.yAxis.value < -0.5 { bits |= 0x02 }
                if gp.dpad.left.isPressed || gp.leftThumbstick.xAxis.value < -0.5 { bits |= 0x04 }
                if gp.dpad.right.isPressed || gp.leftThumbstick.xAxis.value > 0.5 { bits |= 0x08 }
                if gp.buttonA.isPressed || gp.buttonB.isPressed || gp.rightTrigger.isPressed { bits |= 0x10 }
            } else if let mg = pad.microGamepad {
                if mg.dpad.up.isPressed { bits |= 0x01 }
                if mg.dpad.down.isPressed { bits |= 0x02 }
                if mg.dpad.left.isPressed { bits |= 0x04 }
                if mg.dpad.right.isPressed { bits |= 0x08 }
                if mg.buttonA.isPressed { bits |= 0x10 }
            }
        }
        let port = joystickPort
        runner.perform { c64 in
            if port == 2 { c64.joystick2 = bits; c64.joystick1 = 0 } else { c64.joystick1 = bits; c64.joystick2 = 0 }
        }
    }

    // MARK: - ROMs

    private func loadROMs() -> ROMSet? {
        if let roms = ROMSet.load() { return roms }
        let alert = NSAlert()
        alert.messageText = "Commodore ROMs not found"
        alert.informativeText = """
        The C64 needs the original BASIC, KERNAL and CHARGEN ROM images (and optionally the \
        1541 / 1581 drive ROMs). Choose a folder that contains them (for example VICE's C64 \
        and DRIVES folders). They will be copied to:
        \(ROMSet.userROMDirectory.path)
        """
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: ROMSet.userROMDirectory, withIntermediateDirectories: true)
        for dir in panel.urls {
            for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let src = dir.appendingPathComponent(f)
                let size = (try? fm.attributesOfItem(atPath: src.path)[.size] as? Int) ?? 0
                guard [4096, 8192, 16384, 32768].contains(size) else { continue }
                let dst = ROMSet.userROMDirectory.appendingPathComponent(f)
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
        }
        if let roms = ROMSet.load() { return roms }
        let fail = NSAlert()
        fail.messageText = "Still missing ROMs"
        fail.informativeText = "Need basic*.bin (8K), kernal*.bin (8K) and chargen*.bin (4K)."
        fail.runModal()
        return nil
    }

    // MARK: - Media

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["prg", "p00", "d64", "d71", "d81", "g64", "t64", "tap", "crt"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        guard let data = FileManager.default.contents(atPath: url.path) else { return }
        let bytes = [UInt8](data)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        switch url.pathExtension.lowercased() {
        case "d64":
            guard runner.c64.drive8 != nil else {
                let alert = NSAlert()
                alert.messageText = "1541 drive ROM not found"
                alert.informativeText = "Put dos1541*.bin (16 KB) into \(ROMSet.userROMDirectory.path)."
                alert.runModal()
                return
            }
            guard let image = D64Image(data: bytes) else {
                let alert = NSAlert()
                alert.messageText = "Not a valid D64 image"
                alert.informativeText = url.lastPathComponent
                alert.runModal()
                return
            }
            insertDisk(GCRDisk(d64: image), url: url)
            runner.perform { c64 in
                C64Autostart.ensureBooted(c64)
                c64.queueTyping("LOAD\"*\",8,1\nRUN\n")
            }
        case "d81":
            guard let image = D81Image(data: bytes) else {
                let alert = NSAlert()
                alert.messageText = "Not a valid D81 image"
                alert.informativeText = url.lastPathComponent
                alert.runModal()
                return
            }
            guard insertDisk9(image, url: url) else { return }
            runner.perform { c64 in
                C64Autostart.ensureBooted(c64)
                c64.queueTyping("LOAD\"*\",9,1\nRUN\n")
            }
        case "tap":
            guard let pulses = Datasette.parseTAP(bytes) else {
                let alert = NSAlert()
                alert.messageText = "Not a valid TAP image"
                alert.informativeText = url.lastPathComponent
                alert.runModal()
                return
            }
            insertTape(pulses, url: url)
            runner.perform { c64 in
                C64Autostart.ensureBooted(c64)
                c64.datasette.mode = .playing
                c64.queueTyping("LOAD\nRUN\n")
            }
        case "t64":
            guard let file = T64Archive.files(bytes)?.first else {
                let alert = NSAlert()
                alert.messageText = "No programs in T64 archive"
                alert.informativeText = url.lastPathComponent
                alert.runModal()
                return
            }
            runner.perform { c64 in
                C64Autostart.ensureBooted(c64)
                c64.loadPRG(file.prg)
                c64.typeIntoBuffer("RUN\n")
            }
        case "prg":
            runner.perform { c64 in
                C64Autostart.ensureBooted(c64)
                c64.loadPRG(bytes)
                c64.typeIntoBuffer("RUN\n")
            }
        default:
            let alert = NSAlert()
            alert.messageText = "Unsupported file type"
            alert.informativeText = url.lastPathComponent
            alert.runModal()
        }
        baseTitle = "C64 — \(url.lastPathComponent)"
        window.title = baseTitle
    }

    // MARK: - Datasette

    private func insertTape(_ pulses: [UInt32], url: URL?) {
        saveTapeIfNeeded()
        tapeURL = url
        runner.perform { $0.datasette.insert(pulses: pulses) }
    }

    /// Writes a tape that has been recorded on back to its TAP file.
    private func saveTapeIfNeeded() {
        guard let url = tapeURL else { return }
        var data: [UInt8]?
        let done = DispatchSemaphore(value: 0)
        runner.perform { c64 in
            if c64.datasette.dirty { data = c64.datasette.tapData() }
            done.signal()
        }
        guard done.wait(timeout: .now() + 1) == .success, let bytes = data else { return }
        do { try Data(bytes).write(to: url) } catch { NSLog("Saving tape failed: \(error)") }
    }

    @objc func attachTape(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tap")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url,
              let data = FileManager.default.contents(atPath: url.path),
              let pulses = Datasette.parseTAP([UInt8](data)) else { return }
        insertTape(pulses, url: url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    @objc func newBlankTape(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tap")].compactMap { $0 }
        panel.nameFieldStringValue = "blank.tap"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(Datasette.makeTAP([])).write(to: url) } catch { return }
        insertTape([], url: url)
    }

    @objc func tapePlay(_ sender: Any?) { runner.perform { $0.datasette.mode = .playing } }
    @objc func tapeRecord(_ sender: Any?) { runner.perform { $0.datasette.mode = .recording } }
    @objc func tapeStop(_ sender: Any?) {
        runner.perform { $0.datasette.mode = .stopped }
        saveTapeIfNeeded()
    }
    @objc func tapeRewind(_ sender: Any?) { runner.perform { $0.datasette.mode = .stopped; $0.datasette.rewind() } }
    @objc func ejectTape(_ sender: Any?) {
        runner.perform { $0.datasette.mode = .stopped }
        saveTapeIfNeeded()
        tapeURL = nil
        runner.perform { $0.datasette.insert(pulses: []) }
    }
    @objc func toggleTapeWarp(_ sender: NSMenuItem) {
        runner.warpWhileTape.toggle()
        sender.state = runner.warpWhileTape ? .on : .off
    }

    // MARK: - Video standard

    /// Switches the machine between PAL and NTSC. This resets the C64, like swapping
    /// the computer, so a confirmation is shown first.
    @objc func setVideoStandard(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let std = VideoStandard(rawValue: raw),
              sender.state != .on else { return }
        let alert = NSAlert()
        alert.messageText = "Switch to \(std == .pal ? "PAL" : "NTSC")?"
        alert.informativeText = "The C64 will restart. Anything in memory that isn't saved will be lost."
        alert.addButton(withTitle: "Restart as \(std == .pal ? "PAL" : "NTSC")")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(raw, forKey: "VideoStandard")
        for item in standardItems { item.state = item === sender ? .on : .off }
        runner.perform { $0.standard = std }
    }

    // MARK: - Border

    @objc func setBorder(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "BorderMode")
        applyBorder(sender.tag)
    }

    /// Crops the picture and reshapes the window so the screen keeps its proportions.
    private func applyBorder(_ mode: Int) {
        let m = min(max(mode, 0), AppDelegate.borderCrops.count - 1)
        let crop = AppDelegate.borderCrops[m].1
        view.crop = crop
        for item in borderItems { item.state = item.tag == m ? .on : .off }
        let aspect = NSSize(width: crop.width * 0.94, height: crop.height)
        window.contentAspectRatio = aspect
        let width = window.contentLayoutRect.width
        var frame = window.frame
        let newHeight = width * aspect.height / aspect.width
        let delta = newHeight - window.contentLayoutRect.height
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: false)
        view.refresh()
    }

    // MARK: - Drive 9 (1581)

    /// Puts a D81 into the 1581 on device 9, creating the drive on first use.
    @discardableResult
    private func insertDisk9(_ image: D81Image, url: URL?) -> Bool {
        guard ROMSet.load()?.drive1581 != nil else {
            let alert = NSAlert()
            alert.messageText = "1581 drive ROM not found"
            alert.informativeText = "Put dos1581*.bin (32 KB) into \(ROMSet.userROMDirectory.path)."
            alert.runModal()
            return false
        }
        saveDisk9IfNeeded()
        disk9 = image
        disk9URL = url
        runner.perform { c64 in
            let wasNew = c64.drive9 == nil
            c64.attach1581()?.insert(image)
            // A freshly powered drive needs a moment to boot before the C64 talks to it.
            if wasNew { for _ in 0..<50 { c64.runFrame() } }
        }
        return true
    }

    private func saveDisk9IfNeeded() {
        guard let d = disk9, d.dirty, let url = disk9URL else { return }
        do { try Data(d.data).write(to: url) } catch { NSLog("Saving D81 failed: \(error)") }
    }

    @objc func attachDisk9(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "d81")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url,
              let data = FileManager.default.contents(atPath: url.path),
              let image = D81Image(data: [UInt8](data)) else { return }
        if insertDisk9(image, url: url) { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }

    @objc func ejectDisk9(_ sender: Any?) {
        saveDisk9IfNeeded()
        disk9 = nil
        disk9URL = nil
        runner.perform { _ = $0.drive9?.eject() }
    }

    @objc func newBlankDisk9(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "d81")].compactMap { $0 }
        panel.nameFieldStringValue = "blank.d81"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        let image = D81Image.blank(name: String(name.prefix(16)), id: "01")
        do { try Data(image.data).write(to: url) } catch { return }
        insertDisk9(image, url: url)
    }

    @objc func toggleFastLoad(_ sender: NSMenuItem) {
        let on = sender.state != .on
        sender.state = on ? .on : .off
        UserDefaults.standard.set(on, forKey: "FastLoad")
        runner.perform { $0.fastLoad = on }
    }

    @objc func toggleDiskWarp(_ sender: NSMenuItem) {
        runner.warpWhileDisk.toggle()
        sender.state = runner.warpWhileDisk ? .on : .off
        UserDefaults.standard.set(runner.warpWhileDisk, forKey: "WarpWhileDisk")
    }

    // MARK: - Drive 8

    private func insertDisk(_ d: GCRDisk, url: URL?) {
        saveDiskIfNeeded()
        disk = d
        diskURL = url
        runner.perform { $0.drive8?.insert(d) }
    }

    /// Writes changed sectors back to the D64 file.
    private func saveDiskIfNeeded() {
        guard let d = disk, d.dirty, let url = diskURL else { return }
        let image = d.toD64()
        do { try Data(image.data).write(to: url) } catch { NSLog("Saving disk failed: \(error)") }
    }

    @objc func attachDisk(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "d64")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url,
              let data = FileManager.default.contents(atPath: url.path),
              let image = D64Image(data: [UInt8](data)) else { return }
        insertDisk(GCRDisk(d64: image), url: url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        baseTitle = "C64 — \(url.lastPathComponent)"
        window.title = baseTitle
    }

    @objc func ejectDisk(_ sender: Any?) {
        saveDiskIfNeeded()
        disk = nil
        diskURL = nil
        runner.perform { _ = $0.drive8?.eject() }
        baseTitle = "C64"
        window.title = baseTitle
    }

    @objc func newBlankDisk(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "d64")].compactMap { $0 }
        panel.nameFieldStringValue = "blank.d64"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        let image = D64Image.blank(name: String(name.prefix(16)), id: "01")
        do { try Data(image.data).write(to: url) } catch { return }
        insertDisk(GCRDisk(d64: image), url: url)
        baseTitle = "C64 — \(url.lastPathComponent)"
        window.title = baseTitle
    }

    @objc func pasteText(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        runner.perform { $0.queueTyping(text) }
    }

    // MARK: - Modem

    /// BBSes from BBS-LIST.md in the app bundle (rows of the Markdown table with a `host:port` column).
    static func loadPhoneBook() -> [(name: String, host: String, port: UInt16)] {
        guard let url = Bundle.main.url(forResource: "BBS-LIST", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard line.hasPrefix("|"), cells.count >= 2,
                  let address = cells[1].split(separator: "`").first(where: { $0.contains(":") }),
                  let colon = address.lastIndex(of: ":"), let port = UInt16(address[address.index(after: colon)...])
            else { return nil }
            return (cells[0], String(address[..<colon]), port)
        }
    }

    /// Autostarts the bundled BASIC terminal (1200 baud on the user port).
    @objc func loadTerminal(_ sender: Any?) {
        guard let url = Bundle.main.url(forResource: "TERM", withExtension: "PRG"),
              let data = FileManager.default.contents(atPath: url.path) else { return }
        runner.perform { c64 in
            C64Autostart.ensureBooted(c64)
            c64.loadPRG([UInt8](data))
            c64.typeIntoBuffer("RUN\n")
        }
    }

    @objc func dialPhoneBook(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String else { return }
        dial(address)
    }

    @objc func dialAddress(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Dial a BBS"
        alert.informativeText = "Enter host:port (telnet). A terminal program must be running on the C64."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "oasisbbs.hopto.org:6400"
        alert.accessoryView = field
        alert.addButton(withTitle: "Dial")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        dial(field.stringValue.trimmingCharacters(in: .whitespaces))
    }

    private func dial(_ address: String) {
        var host = address
        var port: UInt16 = 23
        if let colon = address.lastIndex(of: ":"), let p = UInt16(address[address.index(after: colon)...]) {
            host = String(address[..<colon])
            port = p
        }
        guard !host.isEmpty else { return }
        modemLink.dial(host: host, port: port)
    }

    @objc func hangUp(_ sender: Any?) { modemLink.hangUp() }

    // MARK: - Machine

    @objc func checkForUpdates(_ sender: Any?) { Task { await updater.check(interactive: true) } }

    @objc func softReset(_ sender: Any?) { runner.perform { $0.cpu.reset() } }
    @objc func hardReset(_ sender: Any?) { runner.perform { $0.reset() } }

    @objc func toggleWarp(_ sender: Any?) {
        runner.warp.toggle()
        warpItem.state = runner.warp ? .on : .off
    }

    @objc func togglePause(_ sender: NSMenuItem) {
        runner.paused.toggle()
        sender.state = runner.paused ? .on : .off
    }

    @objc func swapJoysticks(_ sender: Any?) {
        joystickPort = joystickPort == 2 ? 1 : 2
        swapItem.title = "Joystick in Port \(joystickPort == 2 ? 1 : 2)"
    }

    @objc func toggleCursorJoystick(_ sender: Any?) {
        keyMapper.cursorKeysAsJoystick.toggle()
        cursorJoyItem.state = keyMapper.cursorKeysAsJoystick ? .on : .off
    }

    @objc func toggleMute(_ sender: NSMenuItem) {
        audio.muted.toggle()
        sender.state = audio.muted ? .on : .off
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func mi(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        add("C64", [
            mi("About C64", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            mi("Check for Updates…", #selector(checkForUpdates(_:))),
            .separator(),
            mi("Hide C64", #selector(NSApplication.hide(_:)), "h"),
            mi("Quit C64", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add("File", [
            mi("Open / Autostart…", #selector(openDocument(_:)), "o"),
            .separator(),
            mi("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        add("Edit", [mi("Paste as Typing", #selector(pasteText(_:)), "v")])
        warpItem = mi("Warp Mode", #selector(toggleWarp(_:)), "j")
        standardItems = [("PAL (UK, Europe, Australia) — 50 Hz", "pal"), ("NTSC (USA, Canada, Japan) — 60 Hz", "ntsc")].map {
            let item = mi($0.0, #selector(setVideoStandard(_:)))
            item.representedObject = $0.1
            item.state = $0.1 == "pal" ? .on : .off
            return item
        }
        let standardMenu = NSMenu(title: "Video Standard")
        standardItems.forEach(standardMenu.addItem)
        let standardItem = NSMenuItem(title: "Video Standard", action: nil, keyEquivalent: "")
        standardItem.submenu = standardMenu
        add("Machine", [
            standardItem,
            .separator(),
            mi("Reset", #selector(softReset(_:)), "r"),
            mi("Hard Reset", #selector(hardReset(_:)), "r", [.command, .shift]),
            .separator(),
            warpItem,
            mi("Pause", #selector(togglePause(_:)), "p"),
            mi("Mute", #selector(toggleMute(_:)), "m", [.command, .shift]),
        ])
        swapItem = mi("Joystick in Port 1", #selector(swapJoysticks(_:)), "k")
        cursorJoyItem = mi("Cursor Keys Control Joystick", #selector(toggleCursorJoystick(_:)), "u")
        add("Input", [swapItem, cursorJoyItem])
        fastLoadItem = mi("Instant Load (Skip Disk Wait)", #selector(toggleFastLoad(_:)), "l")
        diskWarpItem = mi("Warp While Disk Loads", #selector(toggleDiskWarp(_:)))
        add("Drive", [
            mi("Attach Disk to Drive 8…", #selector(attachDisk(_:)), "d"),
            mi("Eject Disk", #selector(ejectDisk(_:)), "e"),
            .separator(),
            mi("New Blank Disk…", #selector(newBlankDisk(_:)), "n"),
            .separator(),
            mi("Attach Disk to Drive 9 (1581)…", #selector(attachDisk9(_:)), "d", [.command, .shift]),
            mi("Eject Drive 9 Disk", #selector(ejectDisk9(_:)), "e", [.command, .shift]),
            mi("New Blank D81…", #selector(newBlankDisk9(_:)), "n", [.command, .shift]),
            .separator(),
            fastLoadItem,
            diskWarpItem,
        ])
        let tapeWarp = mi("Warp While Tape Runs", #selector(toggleTapeWarp(_:)))
        tapeWarp.state = .on
        add("Tape", [
            mi("Insert Tape…", #selector(attachTape(_:)), "t"),
            mi("New Blank Tape…", #selector(newBlankTape(_:)), "t", [.command, .shift]),
            mi("Eject Tape", #selector(ejectTape(_:))),
            .separator(),
            mi("Play", #selector(tapePlay(_:)), "1", [.command, .option]),
            mi("Record", #selector(tapeRecord(_:)), "2", [.command, .option]),
            mi("Stop", #selector(tapeStop(_:)), "3", [.command, .option]),
            mi("Rewind", #selector(tapeRewind(_:)), "4", [.command, .option]),
            .separator(),
            tapeWarp,
        ])
        borderItems = AppDelegate.borderCrops.enumerated().map { i, b in
            let item = mi(b.0, #selector(setBorder(_:)), "\(i + 1)")
            item.tag = i
            return item
        }
        add("View", borderItems)
        let phoneBook = NSMenu(title: "Phone Book")
        for entry in AppDelegate.loadPhoneBook() {
            let item = mi("\(entry.name)  —  \(entry.host):\(entry.port)", #selector(dialPhoneBook(_:)))
            item.representedObject = "\(entry.host):\(entry.port)"
            phoneBook.addItem(item)
        }
        let phoneBookItem = NSMenuItem(title: "Phone Book", action: nil, keyEquivalent: "")
        phoneBookItem.submenu = phoneBook
        hangUpItem = mi("Hang Up", #selector(hangUp(_:)))
        add("Modem", [
            mi("Load Terminal Program", #selector(loadTerminal(_:))),
            .separator(),
            phoneBookItem,
            mi("Dial Address…", #selector(dialAddress(_:))),
            hangUpItem,
        ])
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(mi("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(mi("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        let wItem = NSMenuItem()
        wItem.submenu = windowMenu
        main.addItem(wItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}
