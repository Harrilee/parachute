import SwiftUI
import AppKit

@main
struct ParachuteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var language = LanguageStore()
    @StateObject private var device = DeviceService()
    @StateObject private var updater = UpdaterService()

    var body: some Scene {
        Window("Parachute", id: "main") {
            ContentView()
                .environmentObject(language)
                .environmentObject(device)
                .frame(minWidth: 740, minHeight: 520)
                .onAppear {
                    delegate.device = device
                    updater.start()
                    if !ProcessInfo.processInfo.arguments.contains("--preview") { device.startPolling() }
                }
        }
        .defaultSize(width: 1040, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(language.t("update.check")) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var device: DeviceService?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        device?.stop()
        // Allow tracked children their grace period before this process exits.
        let reply = Timer(timeInterval: 1.2, repeats: false) { _ in
            sender.reply(toApplicationShouldTerminate: true)
        }
        RunLoop.main.add(reply, forMode: .common)
        RunLoop.main.add(reply, forMode: .modalPanel)
        return .terminateLater
    }
}
