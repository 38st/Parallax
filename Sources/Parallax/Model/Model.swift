import Foundation

/// How an app is isolated per space.
enum AppKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case chromium
    case vscode
    case firefox
    case other

    var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .chromium: "Chromium browser or Electron app"
        case .vscode: "VS Code family"
        case .firefox: "Firefox"
        case .other: "Other (no isolation)"
        }
    }

    static func detect(name: String, bundleID: String?) -> AppKind {
        let bundle = bundleID?.lowercased() ?? ""
        let name = name.lowercased()
        if bundle == "com.anthropic.claudefordesktop" || name.contains("claude") { return .claude }
        if bundle.contains("codex") || name.contains("codex") || bundle == "com.openai.codex" { return .codex }
        if bundle.hasPrefix("org.mozilla.") { return .firefox }
        if ["com.microsoft.vscode", "com.microsoft.vscodeinsiders", "com.vscodium",
            "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"].contains(bundle) { return .vscode }
        if bundle == "company.thebrowser.browser" { return .other }
        let chromium = ["chrome", "chromium", "brave", "edgemac", "vivaldi", "opera", "electron"]
        if chromium.contains(where: { bundle.contains($0) || name.contains($0) }) { return .chromium }
        return .other
    }
}

struct ManagedApp: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var path: String
    var bundleID: String?
    var kind: AppKind
    /// Folder that holds this app's space folders.
    var dataFolder: String
    /// Codex only: open every account with the one main history in ~/.codex.
    var sharedCodexHistory = false
    var spaces: [Space] = []
}

struct Space: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// Root folder of this space's data. Never moved after creation.
    var folder: String
    var email = ""
    /// Extra launch arguments, written like a shell command line.
    var arguments = ""
    /// Extra environment, one KEY=VALUE per line. `unset KEY` removes a variable.
    var environment = ""
    /// Pass Parallax's own environment through instead of a minimal one.
    var inheritEnvironment = false
    var lastOpened: Date?
}

enum Provider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    var label: String { self == .claude ? "Claude" : "Codex" }
}

struct UsageWindow: Codable, Hashable, Sendable {
    var title: String
    var percent: Int
    var resetsAt: Date?
}

struct UsageAccount: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var provider: Provider
    var label: String
    var email = ""
    var plan = ""
    var windows: [UsageWindow] = []
    var lastRefreshed: Date?
    var lastError: String?
    var signedIn = false

    /// The window closest to its limit.
    var headline: UsageWindow? { windows.max { $0.percent < $1.percent } }

    /// Private CLI login folder used only to read usage.
    var homeFolder: URL {
        Paths.support
            .appendingPathComponent("AccountSessions", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(provider == .claude ? "ClaudeConfig" : "CodexHome", isDirectory: true)
    }
}

struct SavedState: Codable, Sendable {
    var version = 1
    var apps: [ManagedApp] = []
    var accounts: [UsageAccount] = []
}

enum Paths {
    /// `PARALLAX_SUPPORT_DIR` points a development run at a scratch folder instead of real data.
    static var support: URL {
        if let override = ProcessInfo.processInfo.environment["PARALLAX_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Parallax", isDirectory: true)
    }

    static var defaultSpacesRoot: URL {
        support.appendingPathComponent("Profiles/.parallax/Applications", isDirectory: true)
    }

    static func newAppFolder(id: UUID) -> String {
        defaultSpacesRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true).path
    }

    static func newSpaceFolder(app: ManagedApp, spaceID: UUID) -> String {
        URL(fileURLWithPath: app.dataFolder)
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(spaceID.uuidString.lowercased(), isDirectory: true).path
    }
}
