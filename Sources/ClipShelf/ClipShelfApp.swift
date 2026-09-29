import AppKit
import ApplicationServices
import Carbon
import ClipboardCore
import Combine
import SwiftUI

@main
enum ClipShelfApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var store: HistoryStore!
    private var settings: AppSettings!
    private let state = PickerState()
    private let hotkeys = HotKeyManager()
    private var statusItem: NSStatusItem!
    private var panel: HistoryPanel!
    private var settingsWindow: NSWindow?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var cycle = HistoryCycle()
    private var pasteGeneration = UUID()
    private var pasteboard: NSPasteboard = .general
    private var demoDirectory: URL?
    private var subscriptions = Set<AnyCancellable>()
    private var isDemo = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        isDemo = CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--preview-output")
        if !isDemo, let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: {
               $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
           }) {
            NSApp.terminate(nil)
            return
        }
        if isDemo {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-demo-\(UUID())")
            demoDirectory = folder
            pasteboard = NSPasteboard(name: .init("ClipShelf.demo.\(UUID())"))
            settings = AppSettings(defaults: UserDefaults(suiteName: "ClipShelf.demo.\(UUID())")!)
            store = HistoryStore(directory: folder, pasteboard: pasteboard)
            seedDemo()
        } else {
            settings = AppSettings()
            store = HistoryStore(maxEntries: settings.maxEntries)
        }
        makeMenu()
        makeApplicationMenu()
        makePanel()
        installKeyboardNavigation()
        if !isDemo {
            do { try registerHotkeys() } catch { state.error = error.localizedDescription }
            store.startMonitoring()
        }
        store.$entries.sink { [weak self] _ in
            DispatchQueue.main.async { self?.reconcileSelection() }
        }.store(in: &subscriptions)
        if isDemo {
            showPicker()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.finishDemo() }
        } else if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            showPicker()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stopMonitoring()
        hotkeys.unregisterAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let demoDirectory { try? FileManager.default.removeItem(at: demoDirectory) }
        if isDemo { pasteboard.releaseGlobally() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPicker()
        return true
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "ClipShelf 剪贴板历史")
        statusItem.button?.toolTip = "ClipShelf · 剪贴板历史"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func makeApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "退出 ClipShelf", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        editItem.title = "编辑"
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = NSMenuItem(title: "ClipShelf · \(store.entries.count) 条记录", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        addMenuItem(menu, "打开剪贴板历史    \(settings.pickerShortcut.displayName)", #selector(openHistory))
        addMenuItem(menu, "切换到更早一条    \(settings.previousShortcut.displayName)", #selector(previousItem))
        menu.addItem(.separator())
        addMenuItem(menu, store.isPaused ? "继续记录" : "暂停记录", #selector(togglePause))
        addMenuItem(menu, "设置…", #selector(openSettings))
        menu.addItem(.separator())
        addMenuItem(menu, "退出 ClipShelf", #selector(quit))
    }

    private func addMenuItem(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func makePanel() {
        panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.title = "ClipShelf"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 780, height: 500)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: HistoryView(
            store: store, settings: settings, state: state,
            onChoose: { [weak self] in self?.choose($0) },
            onSettings: { [weak self] in self?.showSettings() },
            onClose: { [weak self] in self?.hidePicker(restoreFocus: true) }
        ).environment(\.locale, Locale(identifier: "zh_CN")))
    }

    @objc private func openHistory() { showPicker() }
    @objc private func previousItem() { choosePrevious() }
    @objc private func togglePause() { store.isPaused.toggle() }
    @objc private func openSettings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func rememberTarget() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = app
        }
    }

    private func showPicker() {
        pasteGeneration = UUID()
        rememberTarget()
        store.captureNow()
        let error = state.error
        state.reset()
        state.error = error
        state.selection = store.entries.first?.id
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                         y: frame.midY - panel.frame.height / 2 + 30))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func hidePicker(restoreFocus: Bool) {
        panel.orderOut(nil)
        if restoreFocus { previousApp?.activate(options: [.activateIgnoringOtherApps]) }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        panel.orderOut(nil)
    }

    private func registerHotkeys(picker: KeyboardShortcut? = nil, previous: KeyboardShortcut? = nil, quickSlots: Bool? = nil) throws {
        try hotkeys.register(
            picker: picker ?? settings.pickerShortcut, previous: previous ?? settings.previousShortcut,
            enableQuickSlots: quickSlots ?? settings.quickSlots,
            onPicker: { [weak self] in
                guard let self else { return }
                if self.panel.isVisible { self.hidePicker(restoreFocus: true) } else { self.showPicker() }
            },
            onPrevious: { [weak self] in self?.choosePrevious() },
            onSlot: { [weak self] index in
                guard let self else { return }
                self.store.captureNow()
                guard self.store.entries.indices.contains(index) else { NSSound.beep(); return }
                self.rememberTarget()
                self.choose(self.store.entries[index])
            }
        )
    }

    private func choosePrevious() {
        rememberTarget()
        store.captureNow()
        guard let id = cycle.next(in: store.entries.map(\.id), changeCount: pasteboard.changeCount, currentEntryID: store.currentEntryID),
              let entry = store.entries.first(where: { $0.id == id }) else {
            NSSound.beep()
            return
        }
        if restore(entry) { cycle.didRestore(changeCount: pasteboard.changeCount) }
    }

    private func choose(_ entry: ClipboardEntry) {
        cycle.reset()
        _ = restore(entry)
    }

    @discardableResult
    private func restore(_ entry: ClipboardEntry) -> Bool {
        pasteGeneration = UUID()
        do {
            try store.restore(entry)
            state.error = nil
            statusItem.button?.toolTip = "ClipShelf · 已恢复：\(entry.title.prefix(80))"
            let target = previousApp
            hidePicker(restoreFocus: true)
            if settings.autoPaste, AXIsProcessTrusted(), let target {
                pasteWhenReady(to: target, attempts: 20, generation: pasteGeneration, changeCount: pasteboard.changeCount)
            }
            return true
        } catch {
            showPicker()
            state.error = error.localizedDescription
            return false
        }
    }

    private func pasteWhenReady(to target: NSRunningApplication, attempts: Int, generation: UUID, changeCount: Int) {
        guard attempts > 0, !target.isTerminated else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.pasteGeneration == generation, self.pasteboard.changeCount == changeCount else { return }
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontmostPID != target.processIdentifier {
                if frontmostPID == ProcessInfo.processInfo.processIdentifier {
                    self.pasteWhenReady(to: target, attempts: attempts - 1, generation: generation, changeCount: changeCount)
                }
                return
            }
            let heldModifiers = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
            guard heldModifiers.isEmpty else {
                self.pasteWhenReady(to: target, attempts: attempts - 1, generation: generation, changeCount: changeCount)
                return
            }
            guard let source = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.postToPid(target.processIdentifier)
            up.postToPid(target.processIdentifier)
        }
    }

    private var visibleEntries: [ClipboardEntry] {
        filteredEntries(store.entries, query: state.query, filter: state.filter)
    }

    private func reconcileSelection() {
        if !visibleEntries.contains(where: { $0.id == state.selection }) {
            state.selection = visibleEntries.first?.id
        }
    }

    private func installKeyboardNavigation() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handleKey(event) }
            return consumed ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty {
            if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
            switch event.keyCode {
            case 125, 126:
                let entries = visibleEntries
                guard !entries.isEmpty else { return true }
                let current = entries.firstIndex(where: { $0.id == state.selection }) ?? 0
                let index = min(entries.count - 1, max(0, current + (event.keyCode == 125 ? 1 : -1)))
                state.selection = entries[index].id
                return true
            case 36, 76:
                if let entry = visibleEntries.first(where: { $0.id == state.selection }) { choose(entry) }
                return true
            case 53:
                hidePicker(restoreFocus: true)
                return true
            default: break
            }
        }
        if flags == .command {
            if event.charactersIgnoringModifiers == "," { showSettings(); return true }
            if event.charactersIgnoringModifiers == "f" { state.focusToken = UUID(); return true }
            if let character = event.charactersIgnoringModifiers, let index = Int(character),
               (1...9).contains(index), visibleEntries.indices.contains(index - 1) {
                choose(visibleEntries[index - 1])
                return true
            }
        }
        return false
    }

    private func showSettings() {
        pasteGeneration = UUID()
        hidePicker(restoreFocus: false)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 660),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ClipShelf 设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, store: store) { [weak self] picker, previous, quickSlots, maxEntries, autoPaste in
                guard let self else { return }
                try self.registerHotkeys(picker: picker, previous: previous, quickSlots: quickSlots)
                self.settings.pickerShortcut = picker
                self.settings.previousShortcut = previous
                self.settings.quickSlots = quickSlots
                self.settings.maxEntries = maxEntries
                self.settings.autoPaste = autoPaste
                self.store.maxEntries = maxEntries
                self.settings.save()
            })
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func seedDemo() {
        let samples = [
            "每一个灵感，都值得被留住。",
            "https://developer.apple.com/documentation/appkit/nspasteboard",
            "swift build -c release",
            "周五的设计评审\n\n• 整理交互细节\n• 准备桌面版本\n• 让每次复制都有迹可循"
        ]
        for sample in samples {
            pasteboard.clearContents()
            pasteboard.setString(sample, forType: .string)
            store.captureNow()
        }
        let image = NSImage(size: NSSize(width: 640, height: 400))
        image.lockFocus()
        NSGradient(starting: NSColor.systemTeal, ending: NSColor.systemIndigo)?.draw(in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 400)), angle: 35)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        ("Less searching.\nMore creating." as NSString).draw(in: NSRect(x: 30, y: 130, width: 580, height: 140), withAttributes: [
            .font: NSFont.systemFont(ofSize: 42, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph
        ])
        image.unlockFocus()
        if let data = image.tiffRepresentation {
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .tiff)
            store.captureNow()
        }
        pasteboard.clearContents()
        pasteboard.setString("让剪贴板，记得更多。\n\n复制过的文字、图片和文件，都在这里。\n按 ↑ ↓ 浏览，按 Enter 再次使用。", forType: .string)
        store.captureNow()
    }

    private func finishDemo() {
        if let index = CommandLine.arguments.firstIndex(of: "--preview-output"),
           CommandLine.arguments.indices.contains(index + 1), let view = panel.contentView {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fputs("Preview bitmap creation failed.\n", stderr); exit(1)
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                fputs("Preview PNG encoding failed.\n", stderr); exit(1)
            }
            do { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { fputs("Preview export failed.\n", stderr); exit(1) }
        }
        guard store.entries.count == 6, panel.isVisible else {
            fputs("UI smoke test failed.\n", stderr)
            exit(1)
        }
        let imageEntry = store.entries[1]
        let olderEntry = store.entries[2]
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: panel.windowNumber, context: nil, characters: "",
                             charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        guard handleKey(key(125)), state.selection == imageEntry.id,
              handleKey(key(36)), !panel.isVisible, store.entries.first?.id == imageEntry.id,
              pasteboard.data(forType: .tiff) == imageEntry.imageData else {
            fputs("Keyboard selection and image restore smoke test failed.\n", stderr); exit(1)
        }
        choosePrevious()
        choosePrevious()
        guard store.entries.first?.id == olderEntry.id else {
            fputs("Continuous history navigation smoke test failed.\n", stderr); exit(1)
        }
        print("UI smoke test passed: native window, keyboard selection, image restore, and history cycling.")
        NSApp.terminate(nil)
    }
}
