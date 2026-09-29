import Foundation

struct SavedHistory: Codable, Sendable {
    var version = 2
    let maxEntries: Int
    let entries: [ClipboardEntry]
}

final class HistoryDiskWriter: @unchecked Sendable {
    private struct PendingWrite {
        let snapshot: SavedHistory
        let completion: @Sendable (String?) -> Void
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "app.clipshelf.history-writer", qos: .utility)
    private let lock = NSLock()
    private var pending: PendingWrite?
    private var isWriting = false
    private var lastFailure: String?
    private var removeUnreadableBackups = false

    init(directory: URL) {
        self.directory = directory
    }

    func save(_ snapshot: SavedHistory, removeUnreadableBackups: Bool = false, completion: @escaping @Sendable (String?) -> Void) {
        lock.lock()
        // Coalesce queued snapshots while one atomic write is in progress.
        pending = PendingWrite(snapshot: snapshot, completion: completion)
        self.removeUnreadableBackups = self.removeUnreadableBackups || removeUnreadableBackups
        let shouldStart = !isWriting
        isWriting = true
        lock.unlock()
        if shouldStart { queue.async { self.drain() } }
    }

    func flush() -> String? {
        queue.sync {}
        lock.lock()
        defer { lock.unlock() }
        return lastFailure
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = pending else {
                isWriting = false
                lock.unlock()
                return
            }
            pending = nil
            let shouldRemoveBackups = removeUnreadableBackups
            removeUnreadableBackups = false
            lock.unlock()

            var failure: String?
            do {
                try autoreleasepool {
                    let fileManager = FileManager.default
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    let data = try encoder.encode(next.snapshot)
                    let historyURL = directory.appendingPathComponent("history.plist")
                    try data.write(to: historyURL, options: .atomic)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
                    if shouldRemoveBackups {
                        for file in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        where file.lastPathComponent.hasPrefix("history.unreadable-") && file.pathExtension == "plist" {
                            try fileManager.removeItem(at: file)
                        }
                    }
                }
            } catch {
                failure = "无法保存剪贴板历史，请检查存储空间和文件夹权限。"
            }
            lock.lock()
            lastFailure = failure
            lock.unlock()
            next.completion(failure)
        }
    }
}
