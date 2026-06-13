import Foundation

enum AppPreset: String, CaseIterable, Codable, Identifiable {
    case automatic
    case codex
    case chrome
    case brave
    case edge
    case chromium
    case electron
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .codex: "Codex"
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Edge"
        case .chromium: "Chromium"
        case .electron: "Generic Electron"
        case .custom: "Custom"
        }
    }

    var supportsUserDataDir: Bool {
        switch self {
        case .codex, .chrome, .brave, .edge, .chromium, .electron:
            true
        case .automatic, .custom:
            false
        }
    }

    var needsCodexHome: Bool {
        self == .codex
    }

    static func detected(displayName: String, bundleIdentifier: String?) -> AppPreset {
        let name = displayName.lowercased()
        let bundle = bundleIdentifier?.lowercased() ?? ""
        let combined = "\(name) \(bundle)"

        if combined.contains("codex") { return .codex }
        if combined.contains("brave") { return .brave }
        if combined.contains("edge") || combined.contains("microsoft") { return .edge }
        if combined.contains("chromium") { return .chromium }
        if combined.contains("chrome") { return .chrome }
        if combined.contains("electron") { return .electron }

        return .custom
    }
}
