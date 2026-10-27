import Foundation
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

/// Update configuration is explicit in the signed bundle. Preview/QA builds never
/// initialize Sparkle, so opening a local sample cannot contact the production feed.
struct UpdaterConfiguration {
    let feedURL: URL
    let publicKey: String

    static func load(from bundle: Bundle = .main,
                     arguments: [String] = ProcessInfo.processInfo.arguments) -> UpdaterConfiguration? {
        #if LOCAL_PREVIEW || LOCAL_QA
        return nil
        #else
        guard !arguments.contains("--preview"),
              bundle.object(forInfoDictionaryKey: "ParachuteUpdatesEnabled") as? Bool == true,
              let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
        return UpdaterConfiguration(feedURL: url, publicKey: key)
        #endif
    }
}

@MainActor
final class UpdaterService: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var startupError: String?
    let isEnabled: Bool
    private let configuration: UpdaterConfiguration?
    private var started = false

    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    private var availability: AnyCancellable?
    #endif

    override init() {
        let configuration = UpdaterConfiguration.load()
        self.configuration = configuration
        #if canImport(Sparkle)
        isEnabled = configuration != nil
        #else
        isEnabled = false
        #endif
        super.init()
    }

    /// Call after applicationDidFinishLaunching. Automatic checks follow Sparkle's
    /// normal scheduler and the user's saved setting; no extra launch check is forced.
    func start() {
        guard isEnabled, !started else { return }
        started = true
        #if canImport(Sparkle)
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        availability = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] available in self?.canCheckForUpdates = available }
        do {
            try controller.updater.start()
        } catch {
            startupError = error.localizedDescription
            canCheckForUpdates = false
        }
        #endif
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        #endif
    }
}

#if canImport(Sparkle)
extension UpdaterService: SPUUpdaterDelegate {
    /// Use the signed bundle's validated feed, ignoring old SUFeedURL defaults.
    func feedURLString(for updater: SPUUpdater) -> String? {
        configuration?.feedURL.absoluteString
    }
}
#endif
