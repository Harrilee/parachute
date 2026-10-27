import Foundation

@main
struct UpdaterConfigurationTests {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parachute-updater-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid: [String: Any] = [
            "CFBundleIdentifier": "li.haorui.Parachute.UpdaterConfigTest",
            "ParachuteUpdatesEnabled": true,
            "SUFeedURL": "https://raw.githubusercontent.com/Harrilee/parachute/main/updates/appcast-arm64.xml",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
        ]
        func fixture(_ info: [String: Any]) throws -> Bundle {
            let folder = root.appendingPathComponent(UUID().uuidString + ".bundle")
            let contents = folder.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return Bundle(url: folder)!
        }
        let bundle = try fixture(valid)
        #if LOCAL_PREVIEW
        precondition(UpdaterConfiguration.load(from: bundle, arguments: []) == nil)
        #else
        precondition(UpdaterConfiguration.load(from: bundle, arguments: [])?.feedURL.absoluteString == valid["SUFeedURL"] as? String)
        #endif
        precondition(UpdaterConfiguration.load(from: bundle, arguments: ["Parachute", "--preview"]) == nil)
        for (key, value) in [
            ("ParachuteUpdatesEnabled", false as Any),
            ("SUFeedURL", "http://example.com/appcast.xml"),
            ("SUFeedURL", "https://user:password@example.com/appcast.xml"),
            ("SUFeedURL", "https:///"),
            ("SUPublicEDKey", "placeholder"),
            ("SUPublicEDKey", Data(repeating: 1, count: 31).base64EncodedString()),
        ] {
            var info = valid
            info[key] = value
            let invalidBundle = try fixture(info)
            precondition(UpdaterConfiguration.load(from: invalidBundle, arguments: []) == nil)
        }
        for key in ["ParachuteUpdatesEnabled", "SUFeedURL", "SUPublicEDKey"] {
            var info = valid
            info.removeValue(forKey: key)
            let invalidBundle = try fixture(info)
            precondition(UpdaterConfiguration.load(from: invalidBundle, arguments: []) == nil)
        }
        // The test executable itself has no signed update configuration. Starting
        // its service is inert, including in a build linked against real Sparkle.
        let updater = UpdaterService()
        updater.start()
        precondition(!updater.isEnabled && !updater.canCheckForUpdates && updater.startupError == nil)
        print("Passed 12 updater configuration and preview isolation checks")
    }
}
