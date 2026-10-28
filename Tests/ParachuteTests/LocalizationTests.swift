import Foundation

/// Run the test executable inside a bundle containing the same .lproj resources:
///   LocalizationTests -AppleLanguages '(en)' --expect-language en
///   LocalizationTests -AppleLanguages '(zh-Hans)' --expect-language zh
///   LocalizationTests -AppleLanguages '(zh-Hant)' --expect-language zh
///   LocalizationTests -AppleLanguages '(fr)' --expect-language en
/// AppleLanguages is a per-process launch argument; these tests never write defaults.
@main
struct LocalizationTests {
    @MainActor static func main() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let option = arguments.firstIndex(of: "--expect-language"),
              arguments.indices.contains(option + 1) else {
            fatalError("Pass --expect-language en or zh")
        }
        let expected = arguments[option + 1]
        let store = LanguageStore()
        precondition(store.language == expected, "Expected \(expected), got \(store.language); bundle selected \(Bundle.main.preferredLocalizations)")
        let selected = Bundle.main.preferredLocalizations.first ?? "en"
        let expectedTitle = selected.hasPrefix("zh-Hant") ? "編輯經緯度" : (expected == "zh" ? "编辑经纬度" : "Edit coordinates")
        precondition(store.t("coordinate.title") == expectedTitle)
        for key in ["device.connected", "device.tryUSB", "device.connectionChanged"] {
            precondition(!store.t(key).isEmpty && store.t(key) != key, "Missing localized connection guidance: \(key)")
        }
        for key in ["NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription", "NSLocationAlwaysUsageDescription"] {
            precondition(Bundle.main.object(forInfoDictionaryKey: key) == nil, "The app must not request current-location permission")
        }
        print("Native bundle selection passed: \(Bundle.main.preferredLocalizations)")
    }
}
