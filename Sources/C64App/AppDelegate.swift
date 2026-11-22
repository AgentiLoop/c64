import AppKit
import GameController
import UniformTypeIdentifiers
import C64Core

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var view: EmulatorView!
    var runner: EmulatorRunner!
    var keyMapper: KeyMapper!
    let audio = AudioOutput()
    var joystickPort = 2
    var warpItem: NSMenuItem!
    var cursorJoyItem: NSMenuItem!
    var swapItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        guard let roms = loadROMs() else { NSApp.terminate(nil); return }
        let c64 = C64(roms: roms)
        runner = EmulatorRunner(c64: c64, audio: audio)

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

        runner.onFrame = { [weak self] in self?.frameTick() }
        audio.start()
        runner.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        open(url: URL(fileURLWithPath: filename))
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        keyMapper?.releaseAll()
        runner?.perform { $0.releaseAllKeys(); $0.joystick1 = 0; $0.joystick2 = 0 }
    }

    // MARK: - Frame tick (main thread)

    private func frameTick() {
        view.refresh()
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
        window.title = "C64 — \(url.lastPathComponent)"
    }

    @objc func pasteText(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        runner.perform { $0.queueTyping(text) }
    }

    // MARK: - Machine

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
        add("Machine", [
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
