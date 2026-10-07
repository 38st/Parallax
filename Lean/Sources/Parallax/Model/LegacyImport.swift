import Foundation

/// Reads the previous Parallax's library, usage accounts, and Codex setting. Never writes them.
enum LegacyImport {
    struct Result {
        var apps: [ManagedApp]
        var accounts: [UsageAccount]
    }

    static func load(
        support: URL = Paths.support,
        defaults: UserDefaults = .standard
    ) -> Result {
        let library = support.appendingPathComponent("library.json")
        let sharedHistory = support.appendingPathComponent("shared-history.json")
        var apps = (try? Data(contentsOf: library)).flatMap { try? apps(fromLibrary: $0, support: support) } ?? []
        if let data = try? Data(contentsOf: sharedHistory) {
            let sharedCodexApps = sharedCodexAppStorageIDs(data)
            for index in apps.indices where apps[index].kind == .codex {
                let storageID = URL(fileURLWithPath: apps[index].dataFolder).lastPathComponent
                apps[index].sharedCodexHistory = sharedCodexApps.contains(storageID)
            }
        }
        let accounts = (defaults.data(forKey: "corporate.workspace.v1")).flatMap { try? self.accounts(fromWorkspace: $0) } ?? []
        // Spaces that use a usage account's Codex login get that account's email, so its usage shows beside them.
        for appIndex in apps.indices {
            for spaceIndex in apps[appIndex].spaces.indices where apps[appIndex].spaces[spaceIndex].email.isEmpty {
                let home = LaunchText.environment(apps[appIndex].spaces[spaceIndex].environment).values["CODEX_HOME"]
                if let account = accounts.first(where: { $0.provider == .codex && $0.homeFolder.path == home }) {
                    apps[appIndex].spaces[spaceIndex].email = account.email
                }
            }
        }
        return Result(apps: apps, accounts: accounts)
    }

    // MARK: Library

    private struct LibraryFile: Decodable {
        var version: Int
        var applications: [App]

        struct App: Decodable {
            var id: UUID
            var storageID: UUID
            var displayName: String
            var bundleIdentifier: String?
            var appPath: String
            var preset: String?
            var baseStoragePath: String?
            var profiles: [Profile]
        }

        struct Profile: Decodable {
            var id: UUID
            var storageID: UUID
            var name: String
            var argumentsText: String
            var environmentText: String
            var isolationOwnership: [String: String]?
            var childEnvironmentPolicy: String?
            var lastLaunchedAt: Date?
            var accountLink: AccountLink?
        }

        struct AccountLink: Decodable {
            var expectedEmail: String?
        }
    }

    static func apps(fromLibrary data: Data, support: URL) throws -> [ManagedApp] {
        let file = try JSONDecoder().decode(LibraryFile.self, from: data)
        guard file.version == 2 else { return [] }
        let defaultBase = support.appendingPathComponent("Profiles", isDirectory: true).path
        return file.applications.map { old in
            let base = old.baseStoragePath.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? defaultBase
            let appFolder = URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent(".parallax/Applications", isDirectory: true)
                .appendingPathComponent(old.storageID.uuidString.lowercased(), isDirectory: true)
            let kind = kind(preset: old.preset, name: old.displayName, bundleID: old.bundleIdentifier)
            var app = ManagedApp(
                id: old.id, name: old.displayName, path: old.appPath, bundleID: old.bundleIdentifier,
                kind: kind, dataFolder: appFolder.path
            )
            app.spaces = old.profiles.map { profile in
                let folder = appFolder.appendingPathComponent("Profiles", isDirectory: true)
                    .appendingPathComponent(profile.storageID.uuidString.lowercased(), isDirectory: true)
                let owned = profile.isolationOwnership ?? [:]
                return Space(
                    id: profile.id,
                    name: profile.name,
                    folder: folder.path,
                    email: profile.accountLink?.expectedEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    arguments: cleanedArguments(profile.argumentsText, kind: kind, ownership: owned),
                    environment: cleanedEnvironment(profile.environmentText, kind: kind, ownership: owned, folder: folder),
                    inheritEnvironment: profile.childEnvironmentPolicy == "inheritProcessEnvironment",
                    lastOpened: profile.lastLaunchedAt
                )
            }
            return app
        }
    }

    private static func kind(preset: String?, name: String, bundleID: String?) -> AppKind {
        switch preset {
        case "claude": .claude
        case "codex": .codex
        case "chrome", "brave", "edge", "chromium", "electron": .chromium
        case "visualStudioCode": .vscode
        case "firefox": .firefox
        case "custom": .other
        default: AppKind.detect(name: name, bundleID: bundleID)
        }
    }

    /// Drops isolation options the old app generated; the new launcher adds them from the space folder.
    static func cleanedArguments(_ text: String, kind: AppKind, ownership: [String: String]) -> String {
        guard var words = try? LaunchText.words(text) else { return text }
        if ownership["userData"] == "generated" { words = words.removingOption(LaunchPlanner.userDataOptions) }
        if ownership["extensions"] == "generated" { words = words.removingOption(["--extensions-dir"]) }
        if kind == .firefox, ownership["firefoxProfile"] == "generated" {
            words = words.removingOption(["-profile"]).filter { $0 != "-no-remote" }
        }
        return LaunchText.join(words)
    }

    static func cleanedEnvironment(_ text: String, kind: AppKind, ownership: [String: String], folder: URL) -> String {
        var keys: Set<String> = []
        if ownership["codexHome"] == "generated" { keys.insert("CODEX_HOME") }
        let generatedClaudeConfig = folder.appendingPathComponent("UserData/ClaudeConfig").path
        if LaunchText.environment(text).values["CLAUDE_CONFIG_DIR"] == generatedClaudeConfig { keys.insert("CLAUDE_CONFIG_DIR") }
        return keys.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : LaunchText.removingEnvironment(keys, from: text)
    }

    static func sharedCodexAppStorageIDs(_ data: Data) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspaces = object["codexWorkspaces"] as? [String: Any]
        else { return [] }
        return Set(workspaces.keys.map { $0.lowercased() })
    }

    // MARK: Usage accounts

    private struct Workspace: Decodable {
        var trackedAccounts: [Account]?

        struct Account: Decodable {
            var id: UUID
            var provider: String
            var label: String
            var email: String
            var planName: String
            var isConnected: Bool?
            var lastSuccessfulRefreshAt: Date?
            var usageWindows: [Window]?
        }

        struct Window: Decodable {
            var kind: String
            var modelName: String?
            var usagePercent: Int
            var resetsAt: Date?
        }
    }

    static func accounts(fromWorkspace data: Data) throws -> [UsageAccount] {
        let workspace = try JSONDecoder().decode(Workspace.self, from: data)
        return (workspace.trackedAccounts ?? []).compactMap { old in
            guard old.isConnected == true, let provider = Provider(rawValue: old.provider) else { return nil }
            return UsageAccount(
                id: old.id,
                provider: provider,
                label: old.label,
                email: old.email,
                plan: old.planName,
                windows: (old.usageWindows ?? []).map { window in
                    let title = switch window.kind {
                    case "session": "Session"
                    case "weeklyAllModels": "Week"
                    default: "Week · \(window.modelName ?? "Model")"
                    }
                    return UsageWindow(title: title, percent: window.usagePercent, resetsAt: window.resetsAt)
                },
                lastRefreshed: old.lastSuccessfulRefreshAt,
                signedIn: true
            )
        }
    }
}
