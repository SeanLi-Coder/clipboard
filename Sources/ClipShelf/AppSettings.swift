import AppKit
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
        func shortcut(_ key: String, fallback: KeyboardShortcut) -> KeyboardShortcut {
            guard let data = defaults.data(forKey: key),
                  let value = try? JSONDecoder().decode(KeyboardShortcut.self, from: data), value.isValid else { return fallback }
            return value
        }
        pickerShortcut = shortcut("pickerShortcut", fallback: .pickerDefault)
        previousShortcut = shortcut("previousShortcut", fallback: .previousDefault)
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
