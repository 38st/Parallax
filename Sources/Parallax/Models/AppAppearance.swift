import Foundation

enum AppAppearance:
    String,
    CaseIterable,
    Codable,
    Identifiable,
    Equatable,
    Sendable
{
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
