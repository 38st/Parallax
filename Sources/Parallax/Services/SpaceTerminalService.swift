import Darwin
import Foundation

struct SpaceTerminalCommand: Sendable {
    let url: URL
    private let reservation: ProfileActivityReservation

    fileprivate init(url: URL, reservation: ProfileActivityReservation) {
        self.url = url
        self.reservation = reservation
    }

    func finishHandoff() {
        reservation.release()
    }

    func cleanup() {
        _ = unlink(url.path)
        // Never recursively remove a directory that another process may have changed.
        _ = rmdir(url.deletingLastPathComponent().path)
        reservation.release()
    }
}

enum SpaceTerminalError: LocalizedError, Equatable {
    case storageReserved(String)
    case unavailable
    case sensitiveDirectory
    case invalidShell
    case terminalUnavailable
    case changed

    var errorDescription: String? {
        switch self {
        case .storageReserved(let name):
            String(localized: "Parallax cannot open Terminal for “\(name)” while its storage is reserved by a data operation. Wait for the operation to finish.")
        case .changed:
            String(localized: "The launch configuration changed while it was being inspected. Try again.")
        case .unavailable:
            String(localized: "Terminal requires a Codex or Claude space with a configured tool directory.")
        case .sensitiveDirectory:
            String(localized: "Parallax cannot open Terminal for this space because its tool directory is stored in Keychain or marked as sensitive.")
        case .invalidShell:
            String(localized: "Your login shell is unavailable. Check your macOS account’s shell setting.")
        case .terminalUnavailable:
            String(localized: "Terminal could not be opened for this space.")
        }
    }
}

struct SpaceTerminalService: Sendable {
    let activityRegistry: ProfileActivityRegistry
    var identity: ChildEnvironmentIdentity = .current

    static func supports(_ preset: AppPreset) -> Bool {
        preset.needsCodexHome || preset.needsClaudeConfig
    }

    static var loginShell: String {
        var buffer = [CChar](repeating: 0, count: 16_384)
        return buffer.withUnsafeMutableBufferPointer { buffer in
            var entry = passwd()
            var result: UnsafeMutablePointer<passwd>?
            guard let base = buffer.baseAddress,
                getpwuid_r(getuid(), &entry, base, buffer.count, &result) == 0,
                result != nil, let shell = entry.pw_shell
            else { return "" }
            return String(cString: shell)
        }
    }

    func prepare(
        _ source: LaunchConfigurationSource,
        preset: AppPreset,
        profileName: String = String(localized: "Space"),
        loginShell: String = Self.loginShell,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> SpaceTerminalCommand {
        guard Self.supports(preset) else { throw SpaceTerminalError.unavailable }
        guard loginShell.hasPrefix("/"), !loginShell.contains("\0"),
            FileManager.default.isExecutableFile(atPath: loginShell)
        else { throw SpaceTerminalError.invalidShell }
        let key = preset.needsCodexHome ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
        let pathResolver = ManagedPathResolver(fileSystem: LocalFileSystem())
        let context = LaunchConfigurationAnalyzer(
            pathResolver: pathResolver,
            healthService: LaunchHealthService(activityProvider: activityRegistry),
            identity: identity,
            processEnvironment: [:]
        ).analyze(for: source)
        let classifier = SensitiveEnvironmentKeyClassifier(explicitSensitiveKeys: Set(source.sensitiveEnvironmentKeys))
        // Check the stored value too: generated-path projection must not hide a
        // Keychain reference or sensitivity marker before the disk boundary.
        if let stored = LaunchConfigurationProjection.effectiveEnvironment(context.analysis.environmentResult.entries)
            .assignments.first(where: { $0.key == key }) {
            guard case .literal(let value) = stored.value,
                !classifier.isSensitive(key, value: value)
            else { throw SpaceTerminalError.sensitiveDirectory }
        }
        guard !classifier.isSensitive(key) else { throw SpaceTerminalError.sensitiveDirectory }
        let blocking = context.analysis.diagnostics.filter { diagnostic in
            guard diagnostic.severity == .error else { return false }
            switch diagnostic.code {
            case .applicationHealth, .profileHealth(.profileActive): return false
            default: return true
            }
        }
        if blocking.contains(where: { $0.code == .profileHealth(.storageReservedForDataOperation) }) {
            throw SpaceTerminalError.storageReserved(profileName)
        }
        guard blocking.isEmpty else { throw LaunchPreparationError.blocked(blocking) }
        guard !context.unsetKeys.contains(key),
            let assignment = context.assignments.first(where: { $0.key == key }),
            case .literal(let literal) = assignment.value
        else { throw SpaceTerminalError.unavailable }
        let value = PathSpecificTildeExpander(homeDirectory: identity.homeDirectory)
            .environmentValue(literal, forKey: key)
        guard value.hasPrefix("/"), !value.contains("\0"),
            !classifier.isSensitive(key, value: value)
        else { throw SpaceTerminalError.sensitiveDirectory }

        let reservation: ProfileActivityReservation
        do {
            reservation = try activityRegistry.acquireTerminalHandoffLease(identity:
                ProfileActivityIdentity(applicationID: source.applicationID, applicationStorageID: source.applicationStorageID,
                                        profileID: source.profileID, profileStorageID: source.profileStorageID))
        } catch ProfileActivityRegistryError.storageReservedForDataOperation {
            throw SpaceTerminalError.storageReserved(profileName)
        }
        do {
            if let managedPaths = context.managedPaths {
                try LaunchManagedDirectoryPreparer(pathResolver: pathResolver)
                    .prepare(context.directoryPreparationPlan, managedPaths: managedPaths)
            }
            let url = try writeCommand(environmentKey: key, value: value, profileName: profileName, loginShell: loginShell,
                                       temporaryDirectory: temporaryDirectory)
            return SpaceTerminalCommand(url: url, reservation: reservation)
        } catch {
            reservation.release()
            throw error
        }
    }

    func writeCommand(environmentKey: String, value: String, profileName: String, loginShell: String,
                              temporaryDirectory: URL) throws -> URL {
        var template = Array(temporaryDirectory.appendingPathComponent("Parallax-Terminal-XXXXXX").path.utf8CString)
        let directory = try template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, let path = mkdtemp(base) else { throw posixError() }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        let url = directory.appendingPathComponent("Open.command")
        do {
            guard chmod(directory.path, 0o700) == 0 else { throw posixError() }
            let displayName = String(profileName.unicodeScalars.map {
                CharacterSet.controlCharacters.union(.newlines).contains($0) ? " " : String($0)
            }.joined())
            let banner = String(localized: "Parallax space “\(displayName)”: \(environmentKey) is exported. Login startup files may override it.")
            let script = """
            #!/bin/sh
            /bin/rm -f -- \(quote(url.path)) || :
            cd -- \(quote(identity.homeDirectory)) || exit 1
            /bin/rmdir -- \(quote(directory.path)) 2>/dev/null || :
            export \(environmentKey)=\(quote(value))
            /usr/bin/printf '%s\\n' \(quote(banner))
            exec \(quote(loginShell)) -l

            """
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
            guard descriptor >= 0 else { throw posixError() }
            defer { close(descriptor) }
            guard fchmod(descriptor, 0o700) == 0 else { throw posixError() }
            try Data(script.utf8).withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw posixError() }
                    offset += count
                }
            }
            return url
        } catch {
            _ = unlink(url.path)
            _ = rmdir(directory.path)
            throw error
        }
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
