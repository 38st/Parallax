import Darwin
import Foundation

/// A local launch preference, not an imported library field or a copy of
/// provider data. Codex owns this workspace, including its credential lifecycle.
struct CodexSharedWorkspace: Codable, Equatable, Sendable {
    let path: String
    let device: Int32
    let inode: UInt64

    var isWellFormed: Bool {
        path.hasPrefix("/") && path != "/" && !path.contains("\0")
            && !path.contains("\n") && !path.contains("\r")
            && URL(fileURLWithPath: path).standardizedFileURL.path == path && inode > 0
    }

    static func bind(_ url: URL) throws -> Self {
        let path = url.standardizedFileURL.path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw CodexSharedWorkspaceError.unavailable
        }
        let binding = Self(path: path, device: info.st_dev, inode: info.st_ino)
        guard binding.isWellFormed else { throw CodexSharedWorkspaceError.unavailable }
        return binding
    }

    func validate() throws {
        guard isWellFormed, try Self.bind(URL(fileURLWithPath: path)) == self else {
            throw CodexSharedWorkspaceError.unavailable
        }
    }

    /// Preserve the saved space configuration. Only this launch snapshot uses
    /// the main home and the app's normal desktop storage. No native file is
    /// read, copied, migrated, indexed, or rewritten here.
    func project(_ original: LaunchConfigurationSource) throws -> LaunchConfigurationSource {
        try validate()
        let arguments = LaunchArgumentParser.parse(original.argumentsText)
        let environment = LaunchEnvironmentParser.parse(original.environmentText)
        let userData = UserDataDirectoryOptionResolver.resolve(in: arguments.tokens)
        guard !arguments.hasErrors, !environment.hasErrors,
              userData.occurrences.count <= 1, userData.diagnostics.isEmpty else {
            throw CodexSharedWorkspaceError.configuration
        }
        let text = NSMutableString(string: original.argumentsText)
        for occurrence in userData.occurrences.reversed() {
            let start = occurrence.optionRange.start.utf16Offset
            let end = occurrence.valueRange?.end.utf16Offset ?? occurrence.optionRange.end.utf16Offset
            text.deleteCharacters(in: NSRange(location: start, length: end - start))
        }
        let routedKeys: Set<String> = ["CODEX_HOME", "CODEX_SQLITE_HOME", "CODEX_ELECTRON_USER_DATA_PATH"]
        let env = NSMutableString(string: original.environmentText)
        for entry in environment.entries.reversed() where routedKeys.contains(entry.name) {
            env.deleteCharacters(in: NSRange(location: entry.range.start.utf16Offset,
                length: entry.range.end.utf16Offset - entry.range.start.utf16Offset))
        }
        var source = original
        source.argumentsText = text as String
        source.environmentText = (env as String) + "\nCODEX_HOME=\(path)\nunset CODEX_SQLITE_HOME\nunset CODEX_ELECTRON_USER_DATA_PATH\n"
        guard !LaunchEnvironmentParser.parse(source.environmentText).hasErrors else {
            throw CodexSharedWorkspaceError.configuration
        }
        source.isolationOwnership.userData = .explicit
        source.isolationOwnership.codexHome = .explicit
        // Every space intentionally names this same workspace. Peer collision
        // checks for the saved, separate homes do not describe this launch.
        source.peerProfiles = []
        source.codexSharedWorkspace = self
        return source
    }
}

enum CodexSharedWorkspaceError: LocalizedError {
    case unavailable, configuration, linkedGroup

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "The main Codex history folder is missing or has changed. Open Codex normally, then turn shared history off and on to reconnect it. No history was changed.")
        case .configuration:
            String(localized: "Fix this space’s launch settings before opening the main Codex history.")
        case .linkedGroup:
            String(localized: "Turn off the older Codex history-copy group before choosing one main workspace. Its existing chat copies will stay in place.")
        }
    }
}
