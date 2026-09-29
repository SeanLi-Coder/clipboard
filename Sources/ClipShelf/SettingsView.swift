import AppKit
import ApplicationServices
import ClipboardCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: HistoryStore
    @ObservedObject var updater: AppUpdater
    let onSave: (KeyboardShortcut, KeyboardShortcut, Bool, Int, Bool) throws -> Void
    @ViewState private var pickerShortcut: KeyboardShortcut
    @ViewState private var previousShortcut: KeyboardShortcut
    @ViewState private var quickSlots: Bool
    @ViewState private var maxEntries: Int
    @ViewState private var autoPaste: Bool
    @ViewState private var feedback: String? = nil
    @ViewState private var failed: Bool = false
    @ViewState private var confirmClear: Bool = false
    @ViewState private var loginEnabled: Bool = SMAppService.mainApp.status == .enabled
    @ViewState private var permissionGranted: Bool = AXIsProcessTrusted()

    init(
        settings: AppSettings,
        store: HistoryStore,
        updater: AppUpdater,
        onSave: @escaping (KeyboardShortcut, KeyboardShortcut, Bool, Int, Bool) throws -> Void
    ) {
        self.settings = settings
        self.store = store
        self.updater = updater
        self.onSave = onSave
        _pickerShortcut = ViewState(initialValue: settings.pickerShortcut)
        _previousShortcut = ViewState(initialValue: settings.previousShortcut)
        _quickSlots = ViewState(initialValue: settings.quickSlots)
        _maxEntries = ViewState(initialValue: settings.maxEntries)
        _autoPaste = ViewState(initialValue: settings.autoPaste)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 25)).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 4) {
                    Text("按照你的习惯来").font(.system(size: 20, weight: .bold))
                    Text("快捷键与历史记录，随时调整。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(24)
            Divider()
            Form {
                Section("全局快捷键") {
                    HStack { Text("打开历史与预览"); Spacer(); ShortcutRecorder(shortcut: $pickerShortcut).frame(width: 180, height: 29) }
                    HStack { Text("连续切换到更早一条"); Spacer(); ShortcutRecorder(shortcut: $previousShortcut).frame(width: 180, height: 29) }
                    Toggle("启用 ⌃⌥1–9，直接恢复第 1–9 条", isOn: $quickSlots)
                    Text("点击快捷键框后按下新组合。连续切换会按原先顺序向前循环。").font(.caption).foregroundStyle(.secondary)
                }
                Section("历史与粘贴") {
                    HStack {
                        Text("最多保留")
                        TextField("条数", value: $maxEntries, formatter: limitFormatter)
                            .frame(width: 70).textFieldStyle(.roundedBorder)
                        Text("条").foregroundStyle(.secondary)
                        Stepper("", value: $maxEntries, in: 10...1000, step: 10).labelsHidden()
                        Spacer()
                        Text("10–1000 条").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("选中后自动粘贴到原应用", isOn: $autoPaste)
                    if autoPaste {
                        HStack {
                            Text(permissionGranted ? "辅助功能已授权。" : "自动粘贴需要辅助功能权限；未授权时仍可手动 ⌘V。")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("授权") { requestAccessibility() }
                        }
                    }
                    Text("单条超过 32 MiB 不收录；全部历史最多 256 MiB，超容量或数量时淘汰最早记录。文件和视频保存引用，原文件需保持可访问。").font(.caption).foregroundStyle(.secondary)
                }
                Section("应用") {
                    Toggle("登录后自动启动", isOn: Binding<Bool>(
                        get: { loginEnabled },
                        set: { setLoginEnabled($0) }
                    ))
                    HStack {
                        Text("剪贴板历史仅保存在本机，不会上传。").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("清空历史…", role: .destructive) { confirmClear = true }
                    }
                }
                Section("版本与更新") {
                    HStack {
                        Text("ClipShelf \(updater.currentVersion)")
                        Spacer()
                        Button("检查更新…") { updater.checkForUpdates() }
                            .disabled(!updater.manualCheckAvailable)
                    }
                    Toggle("自动检查新版本", isOn: Binding(
                        get: { updater.automaticChecksEnabled },
                        set: { updater.automaticChecksEnabled = $0 }
                    )).disabled(!updater.isEnabled)
                    Text("每天检查一次。新版本可直接下载并重启安装，保留历史和设置；只有更新功能会联网。").font(.caption).foregroundStyle(.secondary)
                    if let error = updater.startupError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                if let feedback { Text(feedback).font(.system(size: 11)).foregroundStyle(failed ? Color.orange : Color.teal).lineLimit(3) }
                Spacer()
                Button("保存设置") {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    maxEntries = min(1000, max(10, maxEntries))
                    do {
                        try onSave(pickerShortcut, previousShortcut, quickSlots, maxEntries, autoPaste)
                        failed = false
                        feedback = "设置已保存。"
                    }
                    catch { failed = true; feedback = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(.indigo).keyboardShortcut("s", modifiers: .command)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 570, height: 660)
        .alert("清空所有剪贴板历史？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空历史", role: .destructive) { store.clear() }
        } message: { Text("这会删除本机保存的全部记录，不改变当前系统剪贴板，也不会删除原文件。") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionGranted = AXIsProcessTrusted()
            loginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginEnabled = SMAppService.mainApp.status == .enabled
            failed = false
            if SMAppService.mainApp.status == .requiresApproval {
                feedback = "请在系统设置中允许 ClipShelf 登录启动。"
                SMAppService.openSystemSettingsLoginItems()
            } else {
                feedback = loginEnabled ? "已启用登录启动。" : "已关闭登录启动。"
            }
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            failed = true
            feedback = "登录启动设置失败：\(error.localizedDescription)"
        }
    }

    private var limitFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 10
        formatter.maximum = 1000
        return formatter
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        permissionGranted = AXIsProcessTrustedWithOptions(options)
    }
}
