import Carbon
import Foundation
import Testing
@testable import ClipShelf

@Suite("Shortcut settings migration")
@MainActor
struct ShortcutSettingsTests {
    private let finderMove = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | cmdKey))
    private let alternate = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | shiftKey | cmdKey))

    @Test
    func oldDefaultMigratesBeforeRegistrationAndPreservesOtherSettings() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try fixture.store(.pickerDefault, forKey: "pickerShortcut")
        try fixture.store(finderMove, forKey: "previousShortcut")
        fixture.defaults.set(true, forKey: "quickSlots")
        fixture.defaults.set(321, forKey: "maxEntries")
        fixture.defaults.set(true, forKey: "autoPaste")
        fixture.defaults.set("untouched", forKey: "unrelatedPreference")
        let savedPicker = fixture.defaults.data(forKey: "pickerShortcut")

        let settings = AppSettings(defaults: fixture.defaults)

        #expect(settings.previousShortcut == .previousDefault)
        #expect(settings.previousShortcut.displayName == "⌃⌘V")
        #expect(try fixture.read("previousShortcut") == .previousDefault)
        #expect(fixture.defaults.data(forKey: "pickerShortcut") == savedPicker)
        #expect(settings.quickSlots)
        #expect(settings.maxEntries == 321)
        #expect(settings.autoPaste)
        #expect(fixture.defaults.bool(forKey: "quickSlots"))
        #expect(fixture.defaults.integer(forKey: "maxEntries") == 321)
        #expect(fixture.defaults.bool(forKey: "autoPaste"))
        #expect(fixture.defaults.string(forKey: "unrelatedPreference") == "untouched")
    }

    @Test
    func absentSettingsUseSafeDefaultsWithoutWritingPreferences() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }

        let settings = AppSettings(defaults: fixture.defaults)

        #expect(settings.pickerShortcut == .pickerDefault)
        #expect(settings.previousShortcut == .previousDefault)
        #expect(settings.pickerShortcut != settings.previousShortcut)
        #expect(fixture.defaults.persistentDomain(forName: fixture.suiteName)?.isEmpty != false)
    }

    @Test
    func customNonconflictingShortcutsRemainByteForByteUnchanged() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let picker = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey))
        let previous = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey | controlKey))
        try fixture.store(picker, forKey: "pickerShortcut")
        try fixture.store(previous, forKey: "previousShortcut")
        let before = fixture.domain

        let settings = AppSettings(defaults: fixture.defaults)

        #expect(settings.pickerShortcut == picker)
        #expect(settings.previousShortcut == previous)
        #expect(fixture.domain == before)
    }

    @Test
    func reservedPickerMigratesWithoutChangingCustomPrevious() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let previous = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | cmdKey))
        try fixture.store(finderMove, forKey: "pickerShortcut")
        try fixture.store(previous, forKey: "previousShortcut")
        let savedPrevious = fixture.defaults.data(forKey: "previousShortcut")

        let settings = AppSettings(defaults: fixture.defaults)

        #expect(settings.pickerShortcut == .pickerDefault)
        #expect(try fixture.read("pickerShortcut") == .pickerDefault)
        #expect(settings.previousShortcut == previous)
        #expect(fixture.defaults.data(forKey: "previousShortcut") == savedPrevious)
    }

    @Test
    func migratingPreviousAvoidsCustomPickerUsingTheNewDefault() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try fixture.store(.previousDefault, forKey: "pickerShortcut")
        try fixture.store(finderMove, forKey: "previousShortcut")
        let savedPicker = fixture.defaults.data(forKey: "pickerShortcut")

        let settings = AppSettings(defaults: fixture.defaults)

        #expect(settings.pickerShortcut == .previousDefault)
        #expect(settings.previousShortcut == alternate)
        #expect(try fixture.read("previousShortcut") == alternate)
        #expect(fixture.defaults.data(forKey: "pickerShortcut") == savedPicker)
    }

    @Test
    func migratingPickerAvoidsCustomPreviousUsingThePickerDefault() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try fixture.store(finderMove, forKey: "pickerShortcut")
        try fixture.store(.pickerDefault, forKey: "previousShortcut")
        let savedPrevious = fixture.defaults.data(forKey: "previousShortcut")

        let settings = AppSettings(defaults: fixture.defaults)

        #expect(settings.pickerShortcut == alternate)
        #expect(settings.previousShortcut == .pickerDefault)
        #expect(try fixture.read("pickerShortcut") == alternate)
        #expect(fixture.defaults.data(forKey: "previousShortcut") == savedPrevious)
    }

    @Test
    func migratingBothReservedRolesProducesDistinctShortcutsAndIsIdempotent() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try fixture.store(finderMove, forKey: "pickerShortcut")
        try fixture.store(finderMove, forKey: "previousShortcut")

        let first = AppSettings(defaults: fixture.defaults)
        let migrated = fixture.domain
        let second = AppSettings(defaults: fixture.defaults)

        #expect(first.pickerShortcut == .pickerDefault)
        #expect(first.previousShortcut == .previousDefault)
        #expect(second.pickerShortcut == first.pickerShortcut)
        #expect(second.previousShortcut == first.previousShortcut)
        #expect(fixture.domain == migrated)
    }

    @Test
    func reservedCombinationIsRejectedForEveryRegisteredRole() {
        #expect(finderMove.isReservedForFinder)
        #expect(!finderMove.isValid)
        guard case .reservedForFinder = finderMove.validationError else {
            Issue.record("Finder's reserved shortcut must have a dedicated validation error")
            return
        }
        for pickerUsesReserved in [true, false] {
            let manager = HotKeyManager()
            defer { manager.unregisterAll() }
            do {
                try manager.register(
                    picker: pickerUsesReserved ? finderMove : .pickerDefault,
                    previous: pickerUsesReserved ? .previousDefault : finderMove,
                    enableQuickSlots: false, onPicker: {}, onPrevious: {}, onSlot: { _ in }
                )
                Issue.record("Finder's reserved shortcut was registered")
            } catch HotKeyError.reservedForFinder {
                #expect(HotKeyError.reservedForFinder.localizedDescription.contains("Finder"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    private struct Fixture {
        let suiteName = "ClipShelf.shortcut-tests.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() { defaults = UserDefaults(suiteName: suiteName)! }

        var domain: NSDictionary {
            (defaults.persistentDomain(forName: suiteName) ?? [:]) as NSDictionary
        }

        func store(_ shortcut: KeyboardShortcut, forKey key: String) throws {
            defaults.set(try JSONEncoder().encode(shortcut), forKey: key)
        }

        func read(_ key: String) throws -> KeyboardShortcut? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        }

        func cleanUp() { defaults.removePersistentDomain(forName: suiteName) }
    }
}
