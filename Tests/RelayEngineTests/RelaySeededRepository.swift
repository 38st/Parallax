import Darwin
import Foundation

struct RelaySeededRepositoryManifest: Codable, Equatable, Sendable {
    let id: String
    let revision: Int
    let objective: String
    let publicAcceptanceCommands: [[String]]
    let hiddenAcceptanceCommands: [[String]]
    let allowedPaths: [String]
    let forbiddenPaths: [String]
}

struct RelaySeededFile: Equatable, Sendable {
    let relativePath: String
    let contents: Data

    init(_ relativePath: String, contents: String) {
        self.relativePath = relativePath
        self.contents = Data(contents.utf8)
    }

    init(_ relativePath: String, contents: Data) {
        self.relativePath = relativePath
        self.contents = contents
    }
}

enum RelaySeededRepositoryError: Error, Equatable {
    case invalidRelativePath(String)
    case duplicatePath(String)
    case visibleHiddenCollision(String)
    case destinationAlreadyExists(String)
    case unsafeVerificationPath(String)
    case commandFailed(arguments: [String], status: Int32, stderr: String)
    case forbiddenChanges([String])
}

struct RelayMaterializedRepository: Equatable, Sendable {
    let url: URL
    let baselineCommit: String
}

struct RelaySeededRepositoryFixture: Sendable {
    let manifest: RelaySeededRepositoryManifest
    let visibleFiles: [RelaySeededFile]
    let hiddenOracleFiles: [RelaySeededFile]

    init(
        manifest: RelaySeededRepositoryManifest,
        visibleFiles: [RelaySeededFile],
        hiddenOracleFiles: [RelaySeededFile]
    ) throws {
        try Self.validate(files: visibleFiles)
        try Self.validate(files: hiddenOracleFiles)
        let visible = Set(visibleFiles.map(\.relativePath))
        let hidden = Set(hiddenOracleFiles.map(\.relativePath))
        if let collision = visible.intersection(hidden).sorted().first {
            throw RelaySeededRepositoryError.visibleHiddenCollision(collision)
        }
        self.manifest = manifest
        self.visibleFiles = visibleFiles
        self.hiddenOracleFiles = hiddenOracleFiles
    }

    /// Creates exactly the files visible to the Relay worker and initializes a
    /// deterministic Git baseline. Hidden oracle files are never written here.
    func materializeAgentRepository(
        at destination: URL
    ) throws -> RelayMaterializedRepository {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RelaySeededRepositoryError.destinationAlreadyExists(
                destination.path
            )
        }
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try write(visibleFiles, under: destination)
        _ = try RelayGitFixture.run(
            ["init", "--initial-branch=main"],
            in: destination
        )
        _ = try RelayGitFixture.run(
            ["config", "user.name", "Relay Fixture"],
            in: destination
        )
        _ = try RelayGitFixture.run(
            ["config", "user.email", "relay-fixture@example.invalid"],
            in: destination
        )
        _ = try RelayGitFixture.run(["config", "commit.gpgsign", "false"], in: destination)
        _ = try RelayGitFixture.run(["add", "--all"], in: destination)
        _ = try RelayGitFixture.run(
            ["commit", "--quiet", "--message", "Seed relay evaluation fixture"],
            in: destination,
            environment: [
                "GIT_AUTHOR_DATE": "2001-01-01T00:00:00Z",
                "GIT_COMMITTER_DATE": "2001-01-01T00:00:00Z",
            ]
        )
        let commit = try RelayGitFixture.run(["rev-parse", "HEAD"], in: destination)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return RelayMaterializedRepository(url: destination, baselineCommit: commit)
    }

    /// Copies a worker result to an isolated verification root, then adds the
    /// hidden oracle. The candidate repository itself remains unmodified.
    func materializeVerificationRepository(
        from candidate: URL,
        at destination: URL
    ) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RelaySeededRepositoryError.destinationAlreadyExists(
                destination.path
            )
        }
        try FileManager.default.copyItem(at: candidate, to: destination)
        try writeHiddenOracleFiles(under: destination)
    }

    func assertChangesAllowed(
        in repository: URL,
        since baselineCommit: String
    ) throws {
        let tracked = try RelayGitFixture.run(
            ["diff", "--name-only", baselineCommit, "--"],
            in: repository
        ).stdout.split(separator: "\n").map(String.init)
        let untracked = try RelayGitFixture.run(
            ["ls-files", "--others", "--exclude-standard"],
            in: repository
        ).stdout.split(separator: "\n").map(String.init)
        let changes = Set(tracked + untracked)
        let forbidden = changes.filter { path in
            manifest.forbiddenPaths.contains(where: { Self.matches(path, rule: $0) })
                || !manifest.allowedPaths.isEmpty
                    && !manifest.allowedPaths.contains(where: { Self.matches(path, rule: $0) })
        }.sorted()
        guard forbidden.isEmpty else {
            throw RelaySeededRepositoryError.forbiddenChanges(forbidden)
        }
    }

    private func write(_ files: [RelaySeededFile], under root: URL) throws {
        for file in files {
            let destination = root.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.contents.write(to: destination, options: .atomic)
        }
    }

    private func writeHiddenOracleFiles(under root: URL) throws {
        for file in hiddenOracleFiles {
            let components = file.relativePath.split(separator: "/").map(String.init)
            var directory = root
            for component in components.dropLast() {
                directory.appendPathComponent(component, isDirectory: true)
                var facts = stat()
                if lstat(directory.path, &facts) == 0 {
                    guard facts.st_mode & S_IFMT == S_IFDIR else {
                        throw RelaySeededRepositoryError.unsafeVerificationPath(
                            file.relativePath
                        )
                    }
                } else if errno == ENOENT {
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: false
                    )
                } else {
                    throw RelaySeededRepositoryError.unsafeVerificationPath(
                        file.relativePath
                    )
                }
            }

            let destination = root.appendingPathComponent(file.relativePath)
            var facts = stat()
            guard lstat(destination.path, &facts) != 0, errno == ENOENT else {
                throw RelaySeededRepositoryError.unsafeVerificationPath(
                    file.relativePath
                )
            }
            try file.contents.write(to: destination, options: .atomic)
        }
    }

    private static func validate(files: [RelaySeededFile]) throws {
        var paths = Set<String>()
        for file in files {
            let path = file.relativePath
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard
                !path.isEmpty,
                !path.hasPrefix("/"),
                components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                components.first != ".git"
            else {
                throw RelaySeededRepositoryError.invalidRelativePath(path)
            }
            guard paths.insert(path).inserted else {
                throw RelaySeededRepositoryError.duplicatePath(path)
            }
        }
    }

    private static func matches(_ path: String, rule: String) -> Bool {
        if rule == "**" { return true }
        if rule.hasSuffix("/**") {
            return path.hasPrefix(String(rule.dropLast(3)) + "/")
        }
        return path == rule
    }
}

struct RelayFixtureCommandResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let status: Int32
}

enum RelayGitFixture {
    @discardableResult
    static func run(
        _ arguments: [String],
        in directory: URL,
        environment additions: [String: String] = [:]
    ) throws -> RelayFixtureCommandResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = errors
        process.environment = ProcessInfo.processInfo.environment.merging(additions) { _, new in new }
        try process.run()
        process.waitUntilExit()
        let stdout = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let stderr = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let result = RelayFixtureCommandResult(
            stdout: stdout,
            stderr: stderr,
            status: process.terminationStatus
        )
        guard result.status == 0 else {
            throw RelaySeededRepositoryError.commandFailed(
                arguments: arguments,
                status: result.status,
                stderr: stderr
            )
        }
        return result
    }
}
