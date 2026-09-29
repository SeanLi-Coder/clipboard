import AppKit
import Carbon
import Combine
import Foundation
import SwiftUI

// Keep the property wrapper available with SDKs that also export a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
final class AppSettings: ObservableObject {
    @Published var pickerShortcut: KeyboardShortcut
    @Published var previousShortcut: KeyboardShortcut
    @Published var quickSlots: Bool
    @Published var maxEntries: Int
    @Published var autoPaste: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func savedShortcut(_ key: String) -> KeyboardShortcut? {
            guard let data = defaults.data(forKey: key),
                  let value = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) else { return nil }
            return value
        }
        let savedPicker = savedShortcut("pickerShortcut")
        let savedPrevious = savedShortcut("previousShortcut")
        let keepPicker = savedPicker?.isValid == true
        let keepPrevious = savedPrevious?.isValid == true
        var picker = keepPicker ? savedPicker! : .pickerDefault
        var previous = keepPrevious ? savedPrevious! : .previousDefault
        let alternate = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | shiftKey | cmdKey))

        // Keep custom combinations intact when a migrated default needs another key.
        if !keepPicker, keepPrevious, picker == previous {
            picker = [KeyboardShortcut.pickerDefault, alternate, .previousDefault].first { $0 != previous }!
        }
        if !keepPrevious, previous == picker {
            previous = [KeyboardShortcut.previousDefault, alternate, .pickerDefault].first { $0 != picker }!
        }
        pickerShortcut = picker
        previousShortcut = previous

        // Persist only reserved combinations; all unrelated preferences remain untouched.
        if savedPicker?.isReservedForFinder == true {
            defaults.set(try? JSONEncoder().encode(picker), forKey: "pickerShortcut")
        }
        if savedPrevious?.isReservedForFinder == true {
            defaults.set(try? JSONEncoder().encode(previous), forKey: "previousShortcut")
        }
        quickSlots = defaults.bool(forKey: "quickSlots")
        let limit = defaults.integer(forKey: "maxEntries")
        maxEntries = limit == 0 ? 100 : min(1000, max(10, limit))
        autoPaste = defaults.bool(forKey: "autoPaste")
    }

    func save() {
        defaults.set(try? JSONEncoder().encode(pickerShortcut), forKey: "pickerShortcut")
        defaults.set(try? JSONEncoder().encode(previousShortcut), forKey: "previousShortcut")
        defaults.set(quickSlots, forKey: "quickSlots")
        defaults.set(maxEntries, forKey: "maxEntries")
        defaults.set(autoPaste, forKey: "autoPaste")
    }
}

@MainActor
final class PickerState: ObservableObject {
    @Published var query = ""
    @Published var filter = "all"
    @Published var selection: UUID?
    @Published var error: String?
    @Published var focusToken = UUID()

    func reset() {
        query = ""
        filter = "all"
        error = nil
        focusToken = UUID()
    }
}
