import Foundation
import Combine

@MainActor
final class LanguageStore: ObservableObject {
    /// Native bundle selection respects macOS preferred and per-app languages.
    /// A language change takes effect when macOS relaunches the app.
    let language: String
    private let resourceBundle: Bundle

    init(resourceBundle: Bundle = .main) {
        self.resourceBundle = resourceBundle
        let localization = resourceBundle.preferredLocalizations.first ?? "en"
        language = localization.lowercased().hasPrefix("zh") ? "zh" : "en"
    }

    func t(_ key: String) -> String {
        resourceBundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
