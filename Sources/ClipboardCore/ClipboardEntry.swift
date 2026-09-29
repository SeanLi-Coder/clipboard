import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum ClipboardKind: String, Codable, CaseIterable, Sendable {
    case text
    case image
    case files
    case other
}

public struct ClipboardPayloadItem: Codable, Equatable, Sendable {
    public let representations: [String: Data]

    public init(representations: [String: Data]) {
        self.representations = representations
    }
}

public struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public internal(set) var lastUsedAt: Date
    public let sourceApp: String?
    public let items: [ClipboardPayloadItem]
    public let kind: ClipboardKind
    public let title: String
    public let text: String?
    public let fileURLs: [URL]
    public let imageData: Data?
    public let byteCount: Int
    public let fingerprint: String

    public var searchableText: String {
        ([title, text ?? "", sourceApp ?? ""] + fileURLs.map(\.path)).joined(separator: "\n")
    }

    init(items: [ClipboardPayloadItem], sourceApp: String?, date: Date = Date(), id: UUID = UUID(), lastUsedAt: Date? = nil) {
        self.id = id
        createdAt = date
        self.lastUsedAt = lastUsedAt ?? date
        self.sourceApp = sourceApp
        self.items = items
        byteCount = items.reduce(0) { count, item in
            count + item.representations.values.reduce(0) { $0 + $1.count }
        }
        fingerprint = Self.fingerprint(for: items)
        fileURLs = items.flatMap { Self.fileURLs(in: $0.representations) }
        text = items.compactMap { Self.plainText(in: $0.representations) }.first
        imageData = items.lazy.compactMap { Self.imageData(in: $0.representations) }.first

        if !fileURLs.isEmpty {
            kind = .files
            title = fileURLs.count == 1
                ? fileURLs[0].lastPathComponent
                : "\(fileURLs.count) 个文件 · \(fileURLs[0].lastPathComponent)"
        } else if imageData != nil {
            kind = .image
            title = "图片"
        } else if let text, !text.isEmpty {
            kind = .text
            title = String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(180))
        } else {
            kind = .other
            title = "剪贴板内容"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, lastUsedAt, sourceApp, items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            items: try container.decode([ClipboardPayloadItem].self, forKey: .items),
            sourceApp: try container.decodeIfPresent(String.self, forKey: .sourceApp),
            date: try container.decode(Date.self, forKey: .createdAt),
            id: try container.decode(UUID.self, forKey: .id),
            lastUsedAt: try container.decode(Date.self, forKey: .lastUsedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try container.encode(items, forKey: .items)
    }

    static func fileURLs(in representations: [String: Data]) -> [URL] {
        if let data = representations[NSPasteboard.PasteboardType.fileURL.rawValue],
           let string = String(data: data, encoding: .utf8),
           let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.isFileURL {
            return [url]
        }
        if let data = representations["NSFilenamesPboardType"],
           let paths = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return []
    }

    private static func plainText(in representations: [String: Data]) -> String? {
        for type in [NSPasteboard.PasteboardType.string.rawValue, "NSStringPboardType", "public.utf8-plain-text"] {
            if let data = representations[type], let string = String(data: data, encoding: .utf8) {
                return string
            }
        }
        if let data = representations["public.utf16-external-plain-text"] {
            return String(data: data, encoding: .utf16)
        }
        if let data = representations[NSPasteboard.PasteboardType.rtf.rawValue],
           let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return attributed.string
        }
        return nil
    }

    private static func imageData(in representations: [String: Data]) -> Data? {
        for type in [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue, "public.jpeg"] {
            if let data = representations[type] { return data }
        }
        return representations.keys.sorted().first(where: { UTType($0)?.conforms(to: .image) == true })
            .flatMap { representations[$0] }
    }

    private static func fingerprint(for items: [ClipboardPayloadItem]) -> String {
        var hasher = SHA256()
        func appendLength(_ length: Int) {
            var value = UInt64(length).bigEndian
            withUnsafeBytes(of: &value) { hasher.update(data: Data($0)) }
        }
        appendLength(items.count)
        for item in items {
            appendLength(item.representations.count)
            for key in item.representations.keys.sorted() {
                let type = Data(key.utf8)
                let data = item.representations[key]!
                appendLength(type.count)
                hasher.update(data: type)
                appendLength(data.count)
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
