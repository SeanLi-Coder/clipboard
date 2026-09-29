import AppKit
import Carbon
import Foundation

struct KeyboardShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let pickerDefault = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)
    )
    static let previousDefault = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey)
    )

    static let supportedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    var isValid: Bool {
        modifiers != 0 && modifiers & ~Self.supportedModifiers == 0
            && keyCode <= 127 && !Self.modifierKeyCodes.contains(keyCode)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var value: UInt32 = 0
        if event.modifierFlags.contains(.command) { value |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { value |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { value |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { value |= UInt32(shiftKey) }
        modifiers = value
    }

    static func quickSlot(_ index: Int) -> KeyboardShortcut {
        let keyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        precondition(keyCodes.indices.contains(index))
        return KeyboardShortcut(keyCode: keyCodes[index], modifiers: UInt32(controlKey | optionKey))
    }

    private static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    // These are physical ANSI key labels, independent of the current input method.
    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'",
        40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 64: "F17", 65: "Keypad .",
        67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /", 76: "⌤",
        78: "Keypad −", 79: "F18", 80: "F19", 81: "Keypad =", 82: "Keypad 0",
        83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5",
        88: "Keypad 6", 89: "Keypad 7", 90: "F20", 91: "Keypad 8", 92: "Keypad 9",
        93: "¥", 94: "_", 95: "Keypad ,", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 102: "英数", 103: "F11", 104: "かな", 105: "F13",
        106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help",
        115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟",
        122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

enum HotKeyError: LocalizedError {
    case invalid(KeyboardShortcut)
    case duplicate(KeyboardShortcut)
    case handler(OSStatus)
    case registration(KeyboardShortcut, OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalid:
            return "快捷键必须包含 ⌘、⌥、⌃ 或 ⇧，以及一个普通按键。"
        case .duplicate(let shortcut):
            return "快捷键 \(shortcut.displayName) 重复了，请为不同操作设置不同的快捷键。"
        case .handler(let status):
            return "无法启用全局快捷键（错误 \(status)）。请重新启动 ClipShelf。"
        case .registration(let shortcut, let status):
            if status == eventHotKeyExistsErr {
                return "快捷键 \(shortcut.displayName) 已被系统或其他应用占用，请更换组合。原有快捷键仍然有效。"
            }
            return "无法注册快捷键 \(shortcut.displayName)（错误 \(status)）。原有快捷键仍然有效。"
        }
    }
}

// A recorder can receive an already registered combination without disabling hotkeys.
@MainActor
enum ShortcutCapture {
    static var receive: ((KeyboardShortcut) -> Void)?
    static var cancel: (() -> Void)?
}

private let clipShelfHotKeySignature: OSType = 0x43534C46

private let clipShelfHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
    )
    guard status == noErr, identifier.signature == clipShelfHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    let identifierValue = identifier.id
    Task { @MainActor [weak manager] in
        manager?.dispatch(identifierValue)
    }
    return noErr
}

@MainActor
final class HotKeyManager {
    private struct Registration {
        let identifier: UInt32
        let reference: EventHotKeyRef
    }

    private var eventHandler: EventHandlerRef?
    private var registrations: [KeyboardShortcut: Registration] = [:]
    private var callbacks: [UInt32: () -> Void] = [:]
    private var shortcutsByIdentifier: [UInt32: KeyboardShortcut] = [:]
    private var nextIdentifier: UInt32 = 1

    func register(
        picker: KeyboardShortcut,
        previous: KeyboardShortcut,
        enableQuickSlots: Bool,
        onPicker: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onSlot: @escaping (Int) -> Void
    ) throws {
        var requested: [(KeyboardShortcut, () -> Void)] = [(picker, onPicker), (previous, onPrevious)]
        if enableQuickSlots {
            for index in 0..<9 {
                requested.append((.quickSlot(index), { onSlot(index) }))
            }
        }

        var seen = Set<KeyboardShortcut>()
        for (shortcut, _) in requested {
            guard shortcut.isValid else { throw HotKeyError.invalid(shortcut) }
            guard seen.insert(shortcut).inserted else { throw HotKeyError.duplicate(shortcut) }
        }
        try installHandlerIfNeeded()

        var added: [KeyboardShortcut: Registration] = [:]
        do {
            for (shortcut, _) in requested where registrations[shortcut] == nil {
                var reference: EventHotKeyRef?
                let identifier = nextIdentifier
                nextIdentifier &+= 1
                let status = RegisterEventHotKey(
                    shortcut.keyCode, shortcut.modifiers,
                    EventHotKeyID(signature: clipShelfHotKeySignature, id: identifier),
                    GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference
                )
                guard status == noErr, let reference else {
                    throw HotKeyError.registration(shortcut, status)
                }
                added[shortcut] = Registration(identifier: identifier, reference: reference)
            }
        } catch {
            for registration in added.values { UnregisterEventHotKey(registration.reference) }
            throw error
        }

        // Preserve old registrations until every new combination has succeeded.
        for (shortcut, registration) in registrations where !seen.contains(shortcut) {
            UnregisterEventHotKey(registration.reference)
        }
        registrations = registrations.filter { seen.contains($0.key) }
        registrations.merge(added) { existing, _ in existing }
        var newCallbacks: [UInt32: () -> Void] = [:]
        var newShortcuts: [UInt32: KeyboardShortcut] = [:]
        for (shortcut, callback) in requested {
            guard let registration = registrations[shortcut] else { continue }
            newCallbacks[registration.identifier] = callback
            newShortcuts[registration.identifier] = shortcut
        }
        callbacks = newCallbacks
        shortcutsByIdentifier = newShortcuts
    }

    func unregisterAll() {
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        registrations.removeAll()
        callbacks.removeAll()
        shortcutsByIdentifier.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    fileprivate func dispatch(_ identifier: UInt32) {
        if let receive = ShortcutCapture.receive, let shortcut = shortcutsByIdentifier[identifier] {
            receive(shortcut)
        } else {
            callbacks[identifier]?()
        }
    }

    private func installHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(), clipShelfHotKeyHandler, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard status == noErr else { throw HotKeyError.handler(status) }
        eventHandler = handler
    }

    deinit {
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
