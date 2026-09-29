import AppKit
import Combine
import Foundation

public enum ClipboardHistoryError: LocalizedError {
    case recordTooLarge
    case incompleteClipboard
    case missingFiles
    case pasteboardWriteFailed
    case unreadableHistory
    case sensitiveClipboard

    public var errorDescription: String? {
        switch self {
        case .recordTooLarge:
            return "这条剪贴板内容超过 32 MiB，未保存到历史，当前剪贴板保持不变。"
        case .incompleteClipboard:
            return "这条剪贴板内容无法完整读取，未保存到历史。"
        case .missingFiles:
            return "部分原文件已被移动或删除，当前剪贴板保持不变。"
        case .pasteboardWriteFailed:
            return "无法更新剪贴板，请重试。"
        case .unreadableHistory:
            return "无法读取已保存的剪贴板历史。"
        case .sensitiveClipboard:
            return "这条记录包含密码或临时内容标记，无法恢复，当前剪贴板保持不变。"
        }
    }
}

@MainActor
public final class HistoryStore: ObservableObject {
    public static let maximumRecordBytes = 32 * 1_024 * 1_024
    public static let maximumHistoryBytes = 256 * 1_024 * 1_024

    @Published public private(set) var entries: [ClipboardEntry] = []
    @Published public private(set) var lastError: String?
    @Published public var isPaused = false {
        didSet { observedChangeCount = pasteboard.changeCount }
    }
    @Published private var capacity: Int

    public var maxEntries: Int {
        get { capacity }
        set {
            let value = Self.clampedCapacity(newValue)
            guard value != capacity else { return }
            capacity = value
            prune()
            persist()
        }
    }

    public var currentEntryID: UUID? {
        guard pasteboard.changeCount == currentEntryChangeCount,
              let id = capturedCurrentEntryID,
              entries.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private let pasteboard: NSPasteboard
    private let directory: URL
    private let diskWriter: HistoryDiskWriter
    private var historyURL: URL { directory.appendingPathComponent("history.plist") }
    private var timer: Timer?
    private var observedChangeCount: Int
    private var currentEntryChangeCount: Int?
    private var capturedCurrentEntryID: UUID?
    private var persistenceRevision: UInt64 = 0
    private var canPersist = true

    public init(directory: URL? = nil, pasteboard: NSPasteboard = .general, maxEntries: Int = 100) {
        self.pasteboard = pasteboard
        let storageDirectory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipShelf", isDirectory: true)
        self.directory = storageDirectory
        diskWriter = HistoryDiskWriter(directory: storageDirectory)
        capacity = Self.clampedCapacity(maxEntries)
        observedChangeCount = pasteboard.changeCount
        load()
    }

    deinit {
        timer?.invalidate()
    }

    public func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.captureNow() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        flushPendingWrites()
    }

    public func flushPendingWrites() {
        if let failure = diskWriter.flush() { lastError = failure }
    }

    public func captureNow() {
        let changeCount = pasteboard.changeCount
        guard changeCount != observedChangeCount else { return }
        observedChangeCount = changeCount
        guard !isPaused else { return }

        do {
            guard let items = try snapshot(), pasteboard.changeCount == changeCount else { return }
            let source = NSWorkspace.shared.frontmostApplication?.localizedName
            let entry = ClipboardEntry(items: items, sourceApp: source)
            promote(entry)
            capturedCurrentEntryID = entries.first?.id
            currentEntryChangeCount = changeCount
            lastError = nil
            persist()
        } catch {
            if pasteboard.changeCount == changeCount {
                lastError = error.localizedDescription
            }
        }
    }

    public func restore(_ entry: ClipboardEntry) throws {
        do {
            guard !entry.items.contains(where: { $0.representations.keys.contains(where: Self.isSensitiveType) }) else {
                throw ClipboardHistoryError.sensitiveClipboard
            }
            guard !entry.items.isEmpty, entry.items.allSatisfy({ !$0.representations.isEmpty }),
                  entry.byteCount <= Self.maximumRecordBytes else {
                throw ClipboardHistoryError.incompleteClipboard
            }
            guard entry.fileURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                throw ClipboardHistoryError.missingFiles
            }
            let items = try entry.items.map { payload -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in payload.representations {
                    guard !type.isEmpty, item.setData(data, forType: NSPasteboard.PasteboardType(type)) else {
                        throw ClipboardHistoryError.incompleteClipboard
                    }
                }
                return item
            }
            guard !items.isEmpty else { throw ClipboardHistoryError.incompleteClipboard }
            pasteboard.clearContents()
            guard pasteboard.writeObjects(items) else {
                observedChangeCount = pasteboard.changeCount
                throw ClipboardHistoryError.pasteboardWriteFailed
            }
            observedChangeCount = pasteboard.changeCount
            promote(entry)
            capturedCurrentEntryID = entries.first?.id
            currentEntryChangeCount = observedChangeCount
            lastError = nil
            persist()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        observedChangeCount = pasteboard.changeCount
        persist()
    }

    public func clear() {
        lastError = nil
        entries.removeAll()
        observedChangeCount = pasteboard.changeCount
        canPersist = true
        persist(removeUnreadableBackups: true)
        flushPendingWrites()
    }

    private func snapshot() throws -> [ClipboardPayloadItem]? {
        guard let boardItems = pasteboard.pasteboardItems, !boardItems.isEmpty else { return nil }
        let allTypes = (pasteboard.types ?? []) + boardItems.flatMap(\.types)
        guard !allTypes.contains(where: { Self.isSensitiveType($0.rawValue) }) else { return nil }
        let initialTypes = boardItems.map { Set($0.types) }

        var payloads: [ClipboardPayloadItem] = []
        var bytes = 0
        for item in boardItems {
            guard !item.types.isEmpty else { throw ClipboardHistoryError.incompleteClipboard }
            let fileTypes: [NSPasteboard.PasteboardType] = [.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")]
            if let fileType = fileTypes.first(where: { item.types.contains($0) }) {
                guard let data = item.data(forType: fileType) else { throw ClipboardHistoryError.incompleteClipboard }
                let urls = ClipboardEntry.fileURLs(in: [fileType.rawValue: data])
                guard !urls.isEmpty else { throw ClipboardHistoryError.incompleteClipboard }
                // Keep file copy semantics without replaying Finder cut or drag metadata.
                for url in urls {
                    let urlData = Data(url.absoluteString.utf8)
                    bytes += urlData.count
                    guard bytes <= Self.maximumRecordBytes else { throw ClipboardHistoryError.recordTooLarge }
                    payloads.append(ClipboardPayloadItem(representations: [NSPasteboard.PasteboardType.fileURL.rawValue: urlData]))
                }
                continue
            }
            var representations: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { throw ClipboardHistoryError.incompleteClipboard }
                guard data.count <= Self.maximumRecordBytes - bytes else { throw ClipboardHistoryError.recordTooLarge }
                bytes += data.count
                representations[type.rawValue] = data
            }
            payloads.append(ClipboardPayloadItem(representations: representations))
        }
        let finalTypes = (pasteboard.types ?? []) + boardItems.flatMap(\.types)
        guard !finalTypes.contains(where: { Self.isSensitiveType($0.rawValue) }) else { return nil }
        guard boardItems.map({ Set($0.types) }) == initialTypes else { throw ClipboardHistoryError.incompleteClipboard }
        return payloads.isEmpty ? nil : payloads
    }

    private static func isSensitiveType(_ type: String) -> Bool {
        let value = type.lowercased()
        return value.contains("concealed") || value.contains("transient")
            || value.contains("password") || value == "com.agilebits.onepassword"
            || value == "de.petermaurer.transientpasteboardtype"
            || value == "org.nspasteboard.autogeneratedtype"
    }

    private func promote(_ entry: ClipboardEntry) {
        var promoted = entries.first(where: { $0.fingerprint == entry.fingerprint }) ?? entry
        promoted.lastUsedAt = Date()
        entries.removeAll { $0.fingerprint == entry.fingerprint }
        entries.insert(promoted, at: 0)
        prune()
    }

    private func prune() {
        entries = Self.retainedEntries(entries, capacity: capacity, byteLimit: Self.maximumHistoryBytes)
    }

    static func retainedEntries(_ entries: [ClipboardEntry], capacity: Int, byteLimit: Int) -> [ClipboardEntry] {
        var size = 0
        return Array(entries.prefix(capacity).prefix { entry in
            guard entry.byteCount <= Self.maximumRecordBytes, entry.byteCount <= byteLimit - size else {
                return false
            }
            size += entry.byteCount
            return true
        })
    }

    private static func clampedCapacity(_ value: Int) -> Int {
        min(1_000, max(10, value))
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: historyURL.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumHistoryBytes * 3 else {
                throw ClipboardHistoryError.unreadableHistory
            }
            let data = try Data(contentsOf: historyURL)
            let saved = try PropertyListDecoder().decode(SavedHistory.self, from: data)
            guard [1, 2].contains(saved.version), saved.entries.allSatisfy({ entry in
                !entry.items.isEmpty && entry.byteCount <= Self.maximumRecordBytes
                    && entry.items.allSatisfy { item in
                        !item.representations.isEmpty
                            && !item.representations.keys.contains(where: { $0.isEmpty || Self.isSensitiveType($0) })
                    }
            }) else { throw ClipboardHistoryError.unreadableHistory }
            capacity = Self.clampedCapacity(saved.maxEntries)
            var seen: Set<String> = []
            entries = saved.entries.filter { seen.insert($0.fingerprint).inserted }
            prune()
            try protectStorage()
        } catch {
            preserveUnreadableHistory()
        }
    }

    private func persist(removeUnreadableBackups: Bool = false) {
        guard canPersist else {
            lastError = "无法备份原历史文件，已暂停保存新历史以免覆盖原数据。请检查历史目录的权限。"
            return
        }
        persistenceRevision &+= 1
        let revision = persistenceRevision
        diskWriter.save(SavedHistory(maxEntries: capacity, entries: entries), removeUnreadableBackups: removeUnreadableBackups) { [weak self] failure in
            Task { @MainActor [weak self] in
                guard let self, self.persistenceRevision == revision, let failure else { return }
                self.lastError = failure
            }
        }
    }

    private func preserveUnreadableHistory() {
        let backupURL = directory.appendingPathComponent("history.unreadable-\(UUID().uuidString).plist")
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try FileManager.default.moveItem(at: historyURL, to: backupURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            lastError = "无法读取历史，原文件已保留在同一目录的 \(backupURL.lastPathComponent)。"
        } catch {
            canPersist = false
            lastError = "无法读取或备份历史文件，已暂停保存新历史以免覆盖原数据。请检查历史目录的权限。"
        }
    }

    private func protectStorage() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    }
}
