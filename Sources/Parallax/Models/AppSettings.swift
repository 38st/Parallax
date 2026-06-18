import Foundation
import Observation

enum AppAppearance: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: String(localized: "Match System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

@Observable
@MainActor
final class AppSettings {
    var profileTemplateNames: [String] {
        didSet { persist() }
    }
    var defaultBaseStoragePath: String {
        didSet { persist() }
    }
    var confirmBeforeLaunch: Bool {
        didSet { persist() }
    }
    var appearance: AppAppearance {
        didSet { persist() }
    }

    private static let defaults = UserDefaults.standard
    private static let templatesKey = "settings.profileTemplateNames"
    private static let basePathKey = "settings.defaultBaseStoragePath"
    private static let confirmLaunchKey = "settings.confirmBeforeLaunch"
    private static let appearanceKey = "settings.appearance"

    init() {
        let templates = Self.defaults.array(forKey: Self.templatesKey) as? [String]
        if let templates, !templates.isEmpty {
            self.profileTemplateNames = templates
        } else {
            self.profileTemplateNames = ["Personal", "Work", "Testing", "Throwaway"]
        }
        self.defaultBaseStoragePath = Self.defaults.string(forKey: Self.basePathKey) ?? ""
        self.confirmBeforeLaunch = Self.defaults.bool(forKey: Self.confirmLaunchKey)
        self.appearance = AppAppearance(rawValue: Self.defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
    }

    private func persist() {
        Self.defaults.set(profileTemplateNames, forKey: Self.templatesKey)
        Self.defaults.set(defaultBaseStoragePath, forKey: Self.basePathKey)
        Self.defaults.set(confirmBeforeLaunch, forKey: Self.confirmLaunchKey)
        Self.defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
    }
}
