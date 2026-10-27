// Explicitly isolated test application. Never compile into Parachute.
import AppKit
import Sparkle

@MainActor
final class UpgradeHarness: NSObject, NSApplicationDelegate, SPUUserDriver, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private var directory: URL {
        URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "UpgradeTestDirectory") as! String)
    }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String }

    private func record(_ event: String, detail: String? = nil) {
        let record: [String: Any] = ["event": event, "detail": detail ?? "", "version": version,
                                     "pid": ProcessInfo.processInfo.processIdentifier,
                                     "time": Date().timeIntervalSince1970]
        let path = directory.appendingPathComponent("events.jsonl")
        let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10])
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: path) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    private func fail(_ error: Error) {
        record("failed", detail: String(describing: error))
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        record("launched")
        if version == "2" {
            record("relaunch-confirmed", detail: Bundle.main.bundlePath)
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 50) { [weak self] in
            self?.record("timeout")
            NSApp.terminate(nil)
        }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        self.updater = updater
        do {
            try updater.start()
            updater.checkForUpdates()
        } catch { fail(error) }
    }

    func applicationWillTerminate(_ notification: Notification) { record("terminating") }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { record("checking") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("update-found", detail: appcastItem.versionString)
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { fail(error) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        fail(error)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        fail(error)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { record("downloading") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { record("extracting") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("ready-to-install")
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        record("installing")
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        record("installed", detail: String(relaunched))
        acknowledgement()
    }
    func dismissUpdateInstallation() { record("dismissed") }
}

@main
struct SparkleUpgradeTestApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = UpgradeHarness()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
