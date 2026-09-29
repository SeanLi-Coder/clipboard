import Foundation
import Testing
@testable import ClipShelf

@Suite("Update isolation")
@MainActor
struct UpdaterIsolationTests {
    @Test
    func demoUpdaterCannotStartOrChangeUpdatePreferences() {
        let keys = ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SULastCheckTime"]
        let before = keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }
        let updater = AppUpdater(enabled: false)

        updater.automaticChecksEnabled = true
        updater.start()
        updater.checkForUpdates()

        #expect(!updater.isEnabled)
        #expect(!updater.manualCheckAvailable)
        #expect(!updater.canCheckForUpdates)
        #expect(!updater.automaticChecksEnabled)
        #expect(updater.startupError == nil)
        #expect(keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject } == before)
    }
}
