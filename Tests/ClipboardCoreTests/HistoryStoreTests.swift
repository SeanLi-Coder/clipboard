import AppKit
import Testing
@testable import ClipboardCore

@Suite("Clipboard history")
struct HistoryStoreTests {
    @Test @MainActor
    func testTextDeduplicationAndRestorePromotion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.copyText("first")
        let first = try #require(fixture.store.entries.first)
        fixture.copyText("second")
        fixture.copyText("first")
        #expect(fixture.store.entries.map(\.text) == ["first", "second"])
        #expect(fixture.store.entries.first?.id == first.id)

        let second = fixture.store.entries[1]
        try fixture.store.restore(second)
        #expect(fixture.pasteboard.string(forType: .string) == "second")
        #expect(fixture.store.entries.first?.id == second.id)
        fixture.store.captureNow()
        #expect(fixture.store.entries.count == 2)
    }

    @Test @MainActor
    func testMixedPayloadRoundTripAndFileNormalization() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let file = fixture.directory.appendingPathComponent("movie.mov")
        try Data("file fixture".utf8).write(to: file)
        let plain = Data("Styled text".utf8)
        let rtf = Data("{\\rtf1\\ansi Styled text}".utf8)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jT2QAAAAASUVORK5CYII="))
        let textItem = NSPasteboardItem()
        textItem.setData(plain, forType: .string)
        textItem.setData(rtf, forType: .rtf)
        let imageItem = NSPasteboardItem()
        imageItem.setData(png, forType: .png)
        let fileItem = NSPasteboardItem()
        fileItem.setString(file.absoluteString, forType: .fileURL)
        fileItem.setData(Data("move".utf8), forType: .init("com.apple.finder.private-operation"))
        fixture.copy([textItem, imageItem, fileItem])
        let entry = try #require(fixture.store.entries.first)
        #expect(entry.kind == .files)
        #expect(entry.fileURLs == [file])
        #expect(entry.imageData == png)
        #expect(entry.items.count == 3)
        #expect(entry.items[2].representations.keys.sorted() == [NSPasteboard.PasteboardType.fileURL.rawValue])

        fixture.copyText("replacement")
        try fixture.store.restore(entry)
        let restored = try #require(fixture.pasteboard.pasteboardItems)
        #expect(restored.count == 3)
        #expect(restored[0].data(forType: .string) == plain)
        #expect(restored[0].data(forType: .rtf) == rtf)
        #expect(restored[1].data(forType: .png) == png)
        #expect(restored[2].string(forType: .fileURL) == file.absoluteString)
        #expect(fixture.store.entries.first?.id == entry.id)
    }

    @Test @MainActor
    func testMissingFileLeavesClipboardAndHistoryUnchanged() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let file = fixture.directory.appendingPathComponent("temporary.mp4")
        try Data("video placeholder".utf8).write(to: file)
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        fixture.copy([item])
        let fileEntry = try #require(fixture.store.entries.first)
        try FileManager.default.removeItem(at: file)
        fixture.copyText("keep this")
        let history = fixture.store.entries
        let changeCount = fixture.pasteboard.changeCount
        #expect(throws: (any Error).self) { try fixture.store.restore(fileEntry) }
        #expect(fixture.pasteboard.changeCount == changeCount)
        #expect(fixture.pasteboard.string(forType: .string) == "keep this")
        #expect(fixture.store.entries == history)
        #expect(fixture.store.lastError != nil)
    }

    @Test @MainActor
    func testLimitsPersistenceAndPrivateFilePermissions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.maxEntries = 12
        for value in 0..<15 { fixture.copyText("Item \(value)") }
        fixture.store.flushPendingWrites()
        #expect(fixture.store.entries.count == 12)
        #expect(fixture.store.entries.last?.text == "Item 3")
        let restored = HistoryStore(directory: fixture.directory, pasteboard: fixture.pasteboard)
        #expect(restored.maxEntries == 12)
        #expect(restored.entries == fixture.store.entries)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.appendingPathComponent("history.plist").path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        fixture.store.maxEntries = -1
        #expect(fixture.store.maxEntries == 10)
        #expect(fixture.store.entries.count == 10)
        fixture.store.maxEntries = Int.max
        #expect(fixture.store.maxEntries == 1_000)
    }

    @Test @MainActor
    func testSensitiveMarkersRejectEntireRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword", "org.nspasteboard.AutoGeneratedType"] {
            let publicItem = NSPasteboardItem()
            publicItem.setString("visible text", forType: .string)
            let protectedItem = NSPasteboardItem()
            protectedItem.setString("private text", forType: .string)
            protectedItem.setData(Data(), forType: .init(marker))
            fixture.copy([publicItem, protectedItem])
            #expect(fixture.store.entries.isEmpty)
        }
    }

    @Test @MainActor
    func testOversizedRecordIsNeverPartiallySaved() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.copyText("safe")
        let item = NSPasteboardItem()
        item.setString("small representation", forType: .string)
        item.setData(Data(repeating: 42, count: HistoryStore.maximumRecordBytes + 1), forType: .init("com.clipshelf.test.large-data"))
        fixture.copy([item])
        #expect(fixture.store.entries.map(\.text) == ["safe"])
        #expect(fixture.store.lastError != nil)
        #expect(fixture.pasteboard.string(forType: .string) == "small representation")
    }

    @Test @MainActor
    func testClearDeleteAndPauseDoNotRecaptureCurrentClipboard() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.copyText("delete me")
        fixture.store.delete(id: try #require(fixture.store.entries.first?.id))
        fixture.store.captureNow()
        #expect(fixture.store.entries.isEmpty)
        fixture.copyText("clear me")
        fixture.store.clear()
        fixture.store.captureNow()
        #expect(fixture.store.entries.isEmpty)
        fixture.store.isPaused = true
        fixture.copyText("do not save")
        fixture.store.isPaused = false
        fixture.store.captureNow()
        #expect(fixture.store.entries.isEmpty)
        fixture.copyText("save now")
        #expect(fixture.store.entries.first?.text == "save now")
    }

    @Test @MainActor
    func testFingerprintIncludesAllRepresentationsAndItemOrder() async throws {
        let a = ClipboardPayloadItem(representations: ["type-a": Data("a".utf8), "type-b": Data("b".utf8)])
        let sameA = ClipboardPayloadItem(representations: ["type-b": Data("b".utf8), "type-a": Data("a".utf8)])
        let b = ClipboardPayloadItem(representations: ["type-a": Data("b".utf8)])
        #expect(ClipboardEntry(items: [a], sourceApp: nil).fingerprint == ClipboardEntry(items: [sameA], sourceApp: "Other App").fingerprint)
        #expect(ClipboardEntry(items: [a, b], sourceApp: nil).fingerprint != ClipboardEntry(items: [b, a], sourceApp: nil).fingerprint)
    }

    @Test @MainActor
    func testStorageByteBudgetRetainsNewestWholeEntries() async throws {
        let entries = (0..<4).map { index in
            ClipboardEntry(items: [ClipboardPayloadItem(representations: ["test-type": Data(repeating: UInt8(index), count: 5)])], sourceApp: nil)
        }
        #expect(HistoryStore.retainedEntries(entries, capacity: 10, byteLimit: 12) == Array(entries.prefix(2)))
        #expect(HistoryStore.retainedEntries(entries, capacity: 1, byteLimit: 100) == Array(entries.prefix(1)))
        #expect(HistoryStore.retainedEntries(entries, capacity: 10, byteLimit: 4).isEmpty)
    }

    @Test @MainActor
    func testUnavailableRepresentationRejectsEntireRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.copyText("safe")
        let provider = EmptyDataProvider()
        let item = NSPasteboardItem()
        item.setString("incomplete item", forType: .string)
        item.setDataProvider(provider, forTypes: [.init("com.clipshelf.test.unavailable")])
        fixture.copy([item])
        #expect(fixture.store.entries.map(\.text) == ["safe"])
        #expect(fixture.store.lastError != nil)
    }

    @Test @MainActor
    func testPersistenceStoresPayloadOnceAndRebuildsDerivedValues() async throws {
        let entry = ClipboardEntry(items: [ClipboardPayloadItem(representations: [
            NSPasteboard.PasteboardType.string.rawValue: Data("Text fixture".utf8),
            NSPasteboard.PasteboardType.png.rawValue: Data([1, 2, 3, 4])
        ])], sourceApp: "Fixture App")
        let encoded = try PropertyListEncoder().encode(entry)
        let dictionary = try #require(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        #expect(Set(dictionary.keys) == Set(["id", "createdAt", "lastUsedAt", "sourceApp", "items"]))
        #expect(try PropertyListDecoder().decode(ClipboardEntry.self, from: encoded) == entry)
    }

    @Test @MainActor
    func testUnreadableHistoryIsPreservedBeforeNewWritesAndErasedOnClear() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = Data("unreadable history fixture".utf8)
        let historyURL = fixture.directory.appendingPathComponent("history.plist")
        try original.write(to: historyURL)
        let store = HistoryStore(directory: fixture.directory, pasteboard: fixture.pasteboard)
        #expect(store.entries.isEmpty)
        #expect(store.lastError != nil)
        let backups = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("history.unreadable-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == original)

        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("new history", forType: .string)
        store.captureNow()
        store.flushPendingWrites()
        #expect(try Data(contentsOf: #require(backups.first)) == original)
        #expect(HistoryStore(directory: fixture.directory, pasteboard: fixture.pasteboard).entries.first?.text == "new history")
        store.clear()
        #expect(!FileManager.default.fileExists(atPath: try #require(backups.first).path))
        #expect(HistoryStore(directory: fixture.directory, pasteboard: fixture.pasteboard).entries.isEmpty)
    }

    @Test @MainActor
    func testRestoreDoesNotCaptureExistingSensitiveClipboard() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.copyText("safe history")
        let safe = try #require(fixture.store.entries.first)
        #expect(fixture.store.currentEntryID == safe.id)
        let sensitive = NSPasteboardItem()
        sensitive.setString("private fixture", forType: .string)
        sensitive.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        fixture.copy([sensitive])
        #expect(fixture.store.currentEntryID == nil)
        try fixture.store.restore(safe)
        #expect(fixture.store.entries.map(\.text) == ["safe history"])
        #expect(fixture.store.currentEntryID == safe.id)
        #expect(fixture.pasteboard.string(forType: .string) == "safe history")
    }

    @Test @MainActor
    func testSensitiveEntryCannotBeRestoredEvenWhenDecodedExternally() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.copyText("keep this")
        let entry = ClipboardEntry(items: [ClipboardPayloadItem(representations: [
            NSPasteboard.PasteboardType.string.rawValue: Data("private fixture".utf8),
            "org.nspasteboard.ConcealedType": Data()
        ])], sourceApp: nil)
        let changeCount = fixture.pasteboard.changeCount
        #expect(throws: (any Error).self) { try fixture.store.restore(entry) }
        #expect(fixture.pasteboard.changeCount == changeCount)
        #expect(fixture.pasteboard.string(forType: .string) == "keep this")
        #expect(fixture.store.entries.map(\.text) == ["keep this"])
    }
}

private final class EmptyDataProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
}

@MainActor
private final class Fixture {
    let directory: URL
    let pasteboard: NSPasteboard
    let store: HistoryStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: .init("clipshelf-tests-\(UUID().uuidString)"))
        store = HistoryStore(directory: directory, pasteboard: pasteboard)
    }

    func copyText(_ text: String) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        copy([item])
    }

    func copy(_ items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects(items))
        store.captureNow()
    }

    func cleanUp() {
        store.stopMonitoring()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }
}
