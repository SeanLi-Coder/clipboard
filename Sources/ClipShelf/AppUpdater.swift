import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var startupError: String?
    let isEnabled: Bool
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
    private var subscriptions = Set<AnyCancellable>()
    private var started = false

    var manualCheckAvailable: Bool {
        isEnabled && (!started || controller.updater.canCheckForUpdates)
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    var automaticChecksEnabled: Bool {
        get { isEnabled && controller.updater.automaticallyChecksForUpdates }
        set {
            guard isEnabled else { return }
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    init(enabled: Bool = true) {
        isEnabled = enabled
        guard enabled else { return }
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }

    func start() {
        guard isEnabled, !started else { return }
        do {
            try controller.updater.start()
            started = true
            startupError = nil
        } catch {
            startupError = "更新服务暂时不可用：\(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        guard isEnabled else { return }
        if !started { start() }
        NSApp.activate(ignoringOtherApps: true)
        if let startupError {
            let alert = NSAlert()
            alert.messageText = "无法检查更新"
            alert.informativeText = startupError
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        guard controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
