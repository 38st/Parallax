import Foundation

/// Everything needed to open one app instance for one space.
struct LaunchPlan: Equatable {
    var arguments: [String]
    var environment: [String: String]
    /// Folders Parallax owns and creates (mode 0700) before opening.
    var folders: [String]
    var newInstance: Bool
}

enum LaunchPlanner {
    static let userDataOptions = ["--user-data-dir", "-user-data-dir"]
    static let firefoxProfileOptions = ["-profile", "--profile", "-P", "--P", "-ProfileManager", "--ProfileManager", "-CreateProfile", "--CreateProfile"]
    private static let localeKeys: Set<String> = [
        "LANG", "LC_ADDRESS", "LC_ALL", "LC_COLLATE", "LC_CTYPE", "LC_IDENTIFICATION", "LC_MEASUREMENT",
        "LC_MESSAGES", "LC_MONETARY", "LC_NAME", "LC_NUMERIC", "LC_PAPER", "LC_TELEPHONE", "LC_TIME",
        "__CF_USER_TEXT_ENCODING",
    ]
    /// Variables that would silently redirect an app's data away from its space.
    private static let redirectingKeys: Set<String> = [
        "CLAUDE_CONFIG_DIR", "CODEX_HOME", "CODEX_SQLITE_HOME", "CODEX_ELECTRON_USER_DATA_PATH",
        "VSCODE_PORTABLE", "VSCODE_APPDATA", "VSCODE_DEV", "XRE_PROFILE_PATH", "ELECTRON_RUN_AS_NODE",
    ]

    /// Builds the launch for a space. Pass `space: nil` to open the shared Codex history.
    static func plan(
        app: ManagedApp,
        space: Space?,
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) throws -> LaunchPlan {
        var words = try LaunchText.words(space?.arguments ?? "").map { expandUserDataTilde($0, home: home) }
        let custom = LaunchText.environment(space?.environment ?? "")

        var environment: [String: String]
        if space?.inheritEnvironment == true {
            environment = parentEnvironment.filter { key, _ in
                !redirectingKeys.contains(key) && !key.hasPrefix("DYLD_") && !key.hasPrefix("LD_") && !key.hasPrefix("__XPC_DYLD_")
            }
            if environment["PATH"] == nil { environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        } else {
            environment = parentEnvironment.filter { localeKeys.contains($0.key) }
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        environment["HOME"] = home
        environment["USER"] = NSUserName()
        environment["LOGNAME"] = NSUserName()
        environment["TMPDIR"] = NSTemporaryDirectory()
        for (key, value) in custom.values {
            environment[key] = ["CLAUDE_CONFIG_DIR", "CODEX_HOME"].contains(key) ? expandTilde(value, home: home) : value
        }
        for key in custom.unset { environment[key] = nil }

        var folders: [String] = []
        var newInstance = true

        if app.kind == .codex && app.sharedCodexHistory {
            words = words.removingOption(userDataOptions)
            environment["CODEX_HOME"] = (home as NSString).appendingPathComponent(".codex")
            environment["CODEX_SQLITE_HOME"] = nil
            environment["CODEX_ELECTRON_USER_DATA_PATH"] = nil
            return LaunchPlan(arguments: words, environment: environment, folders: [], newInstance: false)
        }

        guard let space else {
            return LaunchPlan(arguments: words, environment: environment, folders: [], newInstance: newInstance)
        }
        let root = URL(fileURLWithPath: space.folder, isDirectory: true)
        let userData = root.appendingPathComponent("UserData").path

        func addUserData() {
            guard !words.containsOption(userDataOptions) else { return }
            insert("--user-data-dir=\(userData)", into: &words)
            folders.append(userData)
        }

        switch app.kind {
        case .claude:
            addUserData()
            if custom.values["CLAUDE_CONFIG_DIR"] == nil {
                let config = root.appendingPathComponent("UserData/ClaudeConfig").path
                environment["CLAUDE_CONFIG_DIR"] = config
                if !folders.contains(userData) { folders.append(userData) }
                folders.append(config)
            }
        case .codex:
            addUserData()
            if custom.values["CODEX_HOME"] == nil {
                let codexHome = root.appendingPathComponent("CodexHome").path
                environment["CODEX_HOME"] = codexHome
                folders.append(codexHome)
            }
        case .chromium:
            addUserData()
        case .vscode:
            addUserData()
            if !words.containsOption(["--extensions-dir"]) {
                let extensions = root.appendingPathComponent("Extensions").path
                insert("--extensions-dir=\(extensions)", into: &words)
                folders.append(extensions)
            }
        case .firefox:
            if !words.containsOption(firefoxProfileOptions) && environment["XRE_PROFILE_PATH"] == nil {
                let profile = root.appendingPathComponent("FirefoxProfile").path
                insert("-profile", into: &words)
                insert(profile, into: &words)
                folders.append(profile)
            }
            if !words.contains("-no-remote") && !words.contains("--no-remote") { insert("-no-remote", into: &words) }
        case .other:
            newInstance = true
        }
        return LaunchPlan(arguments: words, environment: environment, folders: folders, newInstance: newInstance)
    }

    /// The data folder a running instance of this space would be using, for matching processes.
    static func isolationMarker(app: ManagedApp, space: Space) -> String? {
        guard let words = try? LaunchText.words(space.arguments) else { return nil }
        let root = URL(fileURLWithPath: space.folder, isDirectory: true)
        switch app.kind {
        case .firefox:
            if let index = words.firstIndex(of: "-profile"), index + 1 < words.count { return words[index + 1] }
            return root.appendingPathComponent("FirefoxProfile").path
        case .other:
            return nil
        default:
            if let word = words.first(where: { w in userDataOptions.contains { w.hasPrefix($0 + "=") } }),
               let equals = word.firstIndex(of: "=") {
                return expandTilde(String(word[word.index(after: equals)...]), home: NSHomeDirectory())
            }
            return root.appendingPathComponent("UserData").path
        }
    }

    private static func insert(_ word: String, into words: inout [String]) {
        if let separator = words.firstIndex(of: "--") { words.insert(word, at: separator) } else { words.append(word) }
    }

    static func expandTilde(_ value: String, home: String) -> String {
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home + value.dropFirst() }
        return value
    }

    private static func expandUserDataTilde(_ word: String, home: String) -> String {
        for option in userDataOptions where word.hasPrefix(option + "=~") {
            return option + "=" + expandTilde(String(word.dropFirst(option.count + 1)), home: home)
        }
        return word
    }
}
