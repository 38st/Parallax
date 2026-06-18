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
    static let defaultProfileTemplateNames = ["Personal", "Work", "Testing", "Throwaway"]

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

    private let userDefaults: UserDefaults
    private static let templatesKey = "settings.profileTemplateNames"
    private static let basePathKey = "settings.defaultBaseStoragePath"
    private static let confirmLaunchKey = "settings.confirmBeforeLaunch"
    private static let appearanceKey = "settings.appearance"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let templates = userDefaults.array(forKey: Self.templatesKey) as? [String]
        if let templates, !templates.isEmpty {
            self.profileTemplateNames = templates
        } else {
            self.profileTemplateNames = Self.defaultProfileTemplateNames
        }
        self.defaultBaseStoragePath = userDefaults.string(forKey: Self.basePathKey) ?? ""
        self.confirmBeforeLaunch = userDefaults.bool(forKey: Self.confirmLaunchKey)
        self.appearance = AppAppearance(rawValue: userDefaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
    }

    private func persist() {
        userDefaults.set(profileTemplateNames, forKey: Self.templatesKey)
        userDefaults.set(defaultBaseStoragePath, forKey: Self.basePathKey)
        userDefaults.set(confirmBeforeLaunch, forKey: Self.confirmLaunchKey)
        userDefaults.set(appearance.rawValue, forKey: Self.appearanceKey)
    }
}
