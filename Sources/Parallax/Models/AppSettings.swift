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
    static let defaultProfileTemplateNames = ProfileTemplate.defaultNames

    var profileTemplates: [ProfileTemplate] {
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
    private static let templatesKey = "settings.profileTemplates"
    private static let basePathKey = "settings.defaultBaseStoragePath"
    private static let confirmLaunchKey = "settings.confirmBeforeLaunch"
    private static let appearanceKey = "settings.appearance"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.templatesKey),
           let templates = try? JSONDecoder().decode([ProfileTemplate].self, from: data),
           !templates.isEmpty {
            self.profileTemplates = templates
        } else {
            self.profileTemplates = ProfileTemplate.defaults
        }
        self.defaultBaseStoragePath = userDefaults.string(forKey: Self.basePathKey) ?? ""
        self.confirmBeforeLaunch = userDefaults.bool(forKey: Self.confirmLaunchKey)
        self.appearance = AppAppearance(rawValue: userDefaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
    }

    var profileTemplateNames: [String] {
        profileTemplates.map(\.name)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profileTemplates) {
            userDefaults.set(data, forKey: Self.templatesKey)
        }
        userDefaults.set(defaultBaseStoragePath, forKey: Self.basePathKey)
        userDefaults.set(confirmBeforeLaunch, forKey: Self.confirmLaunchKey)
        userDefaults.set(appearance.rawValue, forKey: Self.appearanceKey)
    }
}
