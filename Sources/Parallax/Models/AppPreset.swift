import Foundation

enum AppPreset: String, CaseIterable, Codable, Identifiable {
    private static let edgeBundleIdentifiers: Set<String> = [
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.beta",
        "com.microsoft.edgemac.canary",
        "com.microsoft.edgemac.dev",
    ]

    case automatic
    case codex
    case claude
    case chrome
    case brave
    case edge
    case chromium
    case electron
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .codex: String(localized: "Codex")
        case .claude: String(localized: "Claude")
        case .chrome: String(localized: "Chrome")
        case .brave: String(localized: "Brave")
        case .edge: String(localized: "Edge")
        case .chromium: String(localized: "Chromium")
        case .electron: String(localized: "Generic Electron")
        case .custom: String(localized: "Custom")
        }
    }

    var supportsUserDataDir: Bool {
        switch self {
        case .codex, .claude, .chrome, .brave, .edge, .chromium,
             .electron:
            true
        case .automatic, .custom:
            false
        }
    }

    var needsCodexHome: Bool {
        self == .codex
    }

    var needsClaudeConfig: Bool {
        self == .claude
    }

    static func detected(displayName: String, bundleIdentifier: String?) -> AppPreset {
        let name = displayName.lowercased()
        let bundle = bundleIdentifier?.lowercased() ?? ""

        func nameHas(_ keyword: String) -> Bool {
            Self.containsWord(keyword, in: name)
        }
        func bundleHas(_ keyword: String) -> Bool {
            bundle.contains(keyword)
        }
        func either(_ keyword: String) -> Bool {
            nameHas(keyword) || bundleHas(keyword)
        }

        if either("codex") { return .codex }
        if nameHas("claude")
            || bundle == "com.anthropic.claudefordesktop"
        {
            return .claude
        }
        if either("brave") { return .brave }
        if nameHas("edge") || edgeBundleIdentifiers.contains(bundle) {
            return .edge
        }
        if either("chromium") { return .chromium }
        if either("chrome") { return .chrome }
        if either("electron") { return .electron }

        return .custom
    }

    private static func containsWord(_ keyword: String, in text: String) -> Bool {
        let pattern = "(?:^|[^a-z0-9])\(NSRegularExpression.escapedPattern(for: keyword))(?:$|[^a-z0-9])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
