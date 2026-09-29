import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcut

    func makeNSView(context: Context) -> ShortcutRecordingButton {
        let button = ShortcutRecordingButton()
        button.shortcut = shortcut
        button.onChange = { shortcut = $0 }
        return button
    }

    func updateNSView(_ nsView: ShortcutRecordingButton, context: Context) {
        nsView.shortcut = shortcut
        nsView.onChange = { shortcut = $0 }
    }

    static func dismantleNSView(_ nsView: ShortcutRecordingButton, coordinator: ()) {
        nsView.cancelRecording()
    }
}

@MainActor
final class ShortcutRecordingButton: NSButton {
    var shortcut: KeyboardShortcut = .pickerDefault {
        didSet { if !isRecording { title = shortcut.displayName } }
    }
    var onChange: ((KeyboardShortcut) -> Void)?

    private var isRecording = false
    private var eventMonitor: Any?
    private var windowObserver: NSObjectProtocol?
    private weak var previousResponder: NSResponder?

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        title = shortcut.displayName
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        target = self
        action = #selector(beginRecording)
        toolTip = "点击后按下新快捷键；按 Esc 取消。"
        setAccessibilityLabel("设置快捷键")
        setAccessibilityHelp("点击后按下带修饰键的组合；按 Escape 取消。")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func beginRecording() {
        guard !isRecording, let window else { return }
        ShortcutCapture.cancel?()
        previousResponder = window.firstResponder
        isRecording = true
        title = "请按快捷键…"
        window.makeFirstResponder(self)
        ShortcutCapture.receive = { [weak self] in self?.accept($0) }
        ShortcutCapture.cancel = { [weak self] in self?.cancelRecording() }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, self.isRecording else { return event }
            guard event.window === self.window else {
                self.cancelRecording()
                return event
            }
            if event.type != .keyDown {
                self.cancelRecording()
                return event
            }
            if event.keyCode == 53 {
                self.cancelRecording()
            } else if !event.isARepeat {
                self.accept(KeyboardShortcut(event: event))
            }
            return nil
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }
    }

    private func accept(_ candidate: KeyboardShortcut) {
        guard isRecording else { return }
        guard candidate.isValid else {
            title = "请加上修饰键…"
            NSSound.beep()
            return
        }
        cancelRecording()
        onChange?(candidate)
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        ShortcutCapture.receive = nil
        ShortcutCapture.cancel = nil
        title = shortcut.displayName
        if window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
        previousResponder = nil
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }
}
