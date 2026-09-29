import AppKit
import ClipboardCore
import Quartz
import SwiftUI

func filteredEntries(_ entries: [ClipboardEntry], query: String, filter: String) -> [ClipboardEntry] {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    return entries.filter { entry in
        (filter == "all" || entry.kind.rawValue == filter) &&
        terms.allSatisfy { entry.searchableText.localizedCaseInsensitiveContains($0) }
    }
}

extension ClipboardKind {
    var label: String {
        switch self {
        case .text: return "文字"
        case .image: return "图片"
        case .files: return "文件"
        case .other: return "其他"
        }
    }
    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        case .other: return "square.on.square"
        }
    }
    var tint: Color {
        switch self {
        case .text: return .indigo
        case .image: return .teal
        case .files: return .orange
        case .other: return .secondary
        }
    }
}

extension ClipboardEntry {
    var displayTitle: String {
        switch kind {
        case .image: return "复制的图片"
        case .files: return fileURLs.count > 1 ? "\(fileURLs.count) 个文件 · \(fileURLs.first?.lastPathComponent ?? "")" : title
        case .other: return "剪贴板内容"
        case .text: return title
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: PickerState
    let onChoose: (ClipboardEntry) -> Void
    let onSettings: () -> Void
    let onClose: () -> Void
    @FocusState private var searchFocused: Bool

    private var entries: [ClipboardEntry] { filteredEntries(store.entries, query: state.query, filter: state.filter) }
    private var selected: ClipboardEntry? { entries.first { $0.id == state.selection } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            HStack(spacing: 5) {
                filterButton("全部", key: "all", symbol: "square.grid.2x2")
                ForEach(ClipboardKind.allCases, id: \.rawValue) { kind in
                    filterButton(kind.label, key: kind.rawValue, symbol: kind.symbol)
                }
                Spacer()
                Text("\(entries.count) 条记录").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 22).padding(.bottom, 14)
            Divider()
            HStack(spacing: 0) {
                historyList.frame(minWidth: 295, idealWidth: 345, maxWidth: 375)
                Divider()
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = state.error ?? store.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error).font(.system(size: 12)).textSelection(.enabled)
                    Spacer(minLength: 0)
                }.foregroundStyle(.orange).padding(12).background(Color.orange.opacity(0.08))
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { searchFocused = true; reconcileSelection() }
        .onChange(of: state.focusToken) { _ in searchFocused = true }
        .onChange(of: state.query) { _ in reconcileSelection() }
        .onChange(of: state.filter) { _ in reconcileSelection() }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 24)).foregroundStyle(.white)
                .frame(width: 43, height: 43)
                .background(LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("ClipShelf").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("让剪贴板，记得更多。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(store.isPaused ? Color.orange : Color.teal).frame(width: 6, height: 6)
                Text(store.isPaused ? "已暂停" : "本地记录中").font(.system(size: 11, weight: .medium))
            }.foregroundStyle(.secondary).padding(.horizontal, 11).padding(.vertical, 7)
                .background(Color.primary.opacity(0.04), in: Capsule())
            Button { store.isPaused.toggle() } label: {
                Image(systemName: store.isPaused ? "play" : "pause").frame(width: 24, height: 25)
            }.buttonStyle(.plain).help(store.isPaused ? "继续记录" : "暂停记录")
            Button(action: onSettings) { Image(systemName: "gearshape").frame(width: 24, height: 25) }
                .buttonStyle(.plain).help("设置 · ⌘,")
            Button(action: onClose) { Image(systemName: "xmark").frame(width: 24, height: 25) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭 · Esc")
        }.padding(.horizontal, 22).padding(.vertical, 17)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索文字、文件名或来源应用…", text: $state.query)
                .textFieldStyle(.plain).font(.system(size: 14)).focused($searchFocused)
                .accessibilityLabel("搜索剪贴板历史")
            if !state.query.isEmpty {
                Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
            KeyCap(label: "⌘ F")
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 13)
    }

    private func filterButton(_ title: String, key: String, symbol: String) -> some View {
        Button { state.filter = key } label: {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(state.filter == key ? Color.white : Color.secondary)
                .background(state.filter == key ? Color.indigo : Color.clear, in: Capsule())
        }.buttonStyle(.plain)
    }

    private var historyList: some View {
        Group {
            if entries.isEmpty {
                emptyState(symbol: "tray", title: store.entries.isEmpty ? "从下一次复制开始" : "没有匹配的记录",
                           subtitle: store.entries.isEmpty ? "复制文字、图片或 Finder 中的文件，\n它们就会出现在这里。" : "试试其他关键词或内容类型。")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                HistoryRow(entry: entry, position: index, selected: entry.id == state.selection)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { onChoose(entry) }
                                    .onTapGesture { state.selection = entry.id }
                                    .contextMenu {
                                        Button("恢复到剪贴板") { onChoose(entry) }
                                        Button("删除此条记录", role: .destructive) { store.delete(id: entry.id) }
                                    }
                                    .id(entry.id)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { state.selection = entry.id }
                            }
                        }.padding(10)
                    }
                    .onChange(of: state.selection) { id in
                        if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var preview: some View {
        Group {
            if let entry = selected {
                EntryPreview(entry: entry, onChoose: { onChoose(entry) })
                    .id(entry.id)
            } else {
                emptyState(symbol: "square.stack.3d.up", title: "你的下一次粘贴，在这里", subtitle: "选中左侧记录，预览后再次使用。")
            }
        }.background(Color(nsColor: .textBackgroundColor).opacity(0.45))
    }

    private var footer: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) { KeyCap(label: "↑ ↓"); Text("浏览") }
            HStack(spacing: 5) { KeyCap(label: "↵"); Text("恢复") }
            HStack(spacing: 5) { KeyCap(label: "esc"); Text("关闭") }
            Spacer()
            Image(systemName: "lock.shield").foregroundStyle(.teal)
            Text("仅保存在本机 · 最多 \(store.maxEntries) 条")
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 12)
    }

    private func emptyState(symbol: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.indigo.opacity(0.6))
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reconcileSelection() {
        if !entries.contains(where: { $0.id == state.selection }) { state.selection = entries.first?.id }
    }
}

private struct HistoryRow: View {
    let entry: ClipboardEntry
    let position: Int
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: entry.kind.symbol).font(.system(size: 16))
                .foregroundStyle(entry.kind.tint).frame(width: 35, height: 35)
                .background(entry.kind.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.displayTitle).font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Text(entry.kind.label)
                    Text("·")
                    Text(entry.lastUsedAt, style: .relative).lineLimit(1)
                    Spacer(minLength: 0)
                    if position < 9 { Text("⌘\(position + 1)").font(.system(size: 10, design: .monospaced)) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(selected ? Color.indigo.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.indigo.opacity(0.25) : Color.clear, lineWidth: 1))
    }
}

private struct EntryPreview: View {
    let entry: ClipboardEntry
    let onChoose: () -> Void
    @ViewState private var selectedFile = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("内容预览", systemImage: "sidebar.right").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(entry.kind.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(entry.kind.tint)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(entry.kind.tint.opacity(0.08), in: Capsule())
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(entry.sourceApp ?? "剪贴板").lineLimit(1)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
                }
                Text(entry.lastUsedAt.formatted(date: .abbreviated, time: .shortened))
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .center) {
                Text("恢复后置顶，再按 ⌘V 粘贴").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(action: onChoose) { Label("恢复到剪贴板", systemImage: "arrow.uturn.backward").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.borderedProminent).tint(.indigo).controlSize(.large)
            }
        }.padding(22)
    }

    @ViewBuilder private var content: some View {
        if !entry.fileURLs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if entry.fileURLs.count > 1 {
                    Picker("预览文件", selection: $selectedFile) {
                        ForEach(Array(entry.fileURLs.enumerated()), id: \.offset) { index, url in
                            Text(url.lastPathComponent).tag(index)
                        }
                    }.labelsHidden()
                }
                let url = entry.fileURLs[min(selectedFile, entry.fileURLs.count - 1)]
                if FileManager.default.fileExists(atPath: url.path) {
                    QuickLookPreview(url: url).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Label("原文件已移动或删除", systemImage: "doc.badge.ellipsis").foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Text(url.deletingLastPathComponent().path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.font(.system(size: 11))
            }
        } else if let data = entry.imageData, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        } else if let text = entry.text {
            ScrollView {
                Text(text).font(.system(size: 15)).lineSpacing(7).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(18)
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "square.on.square").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("此格式无法直接预览").font(.headline)
                Text("原始剪贴板格式已保留，可恢复后在支持的应用中粘贴。").font(.system(size: 12)).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = false
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.previewItem = nil
        view.close()
    }
}

private struct KeyCap: View {
    let label: String
    var body: some View {
        Text(label).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
