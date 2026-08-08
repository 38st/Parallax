import AppKit
import Darwin
import Foundation

struct ConnectedAIAccountStatus: Sendable, Equatable {
    let email: String?
    let planName: String?
    let usagePercent: Int?
    let resetsAt: Date?
    let lifetimeTokens: Int?
}

enum AIAccountConnectionError: LocalizedError {
    case executableMissing(String)
    case notAuthenticated
    case loginFailed
    case statusUnavailable

    var errorDescription: String? {
        switch self {
        case let .executableMissing(name):
            "A trusted \(name) executable was not found in an approved system location."
        case .notAuthenticated:
            "This account is not signed in yet."
        case .loginFailed:
            "Sign-in did not complete. Try again."
        case .statusUnavailable:
            "Account status is unavailable. Try again."
        }
    }
}

enum ProviderExecutableLocatorError: Error, Equatable {
    case missing(String)
    case noLongerTrusted(String)
}

/// A provider executable plus the trust root that authorized it. The same
/// validation is repeated immediately before `Process.run()` to narrow the
/// discovery-to-execution race.
struct TrustedProviderExecutable: Sendable, Equatable {
    let url: URL
    fileprivate let trustRoot: URL?
    fileprivate let currentUserID: uid_t
    fileprivate let allowsGroupWritableAncestors: Bool

    func revalidatedURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let validated = ProviderExecutableTrustPolicy.validate(
            url,
            beneath: trustRoot,
            allowsGroupWritableAncestors: allowsGroupWritableAncestors,
            fileManager: fileManager,
            currentUserID: currentUserID
        ) else {
            throw ProviderExecutableLocatorError.noLongerTrusted(url.path)
        }
        return validated
    }
}

private enum ProviderExecutableTrustPolicy {
    static func validate(
        _ candidate: URL,
        beneath trustRoot: URL?,
        allowsGroupWritableAncestors: Bool,
        fileManager: FileManager,
        currentUserID: uid_t
    ) -> URL? {
        guard
            let canonical = canonicalURL(candidate),
            trustedItem(
                canonical,
                expectedType: .typeRegular,
                executable: true,
                allowsGroupWrite: false,
                requiredGroupID: nil,
                fileManager: fileManager,
                currentUserID: currentUserID
            )
        else {
            return nil
        }

        guard
            let trustRoot,
            let canonicalRoot = canonicalURL(trustRoot),
            canonical.path.hasPrefix(canonicalRoot.path + "/"),
            let rootAttributes = try? fileManager.attributesOfItem(
                atPath: canonicalRoot.path
            ),
            let trustedGroupID =
                (rootAttributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value
        else {
            return nil
        }

        var directory = canonical.deletingLastPathComponent()
        while true {
            guard trustedItem(
                directory,
                expectedType: .typeDirectory,
                executable: false,
                allowsGroupWrite: allowsGroupWritableAncestors,
                requiredGroupID: trustedGroupID,
                fileManager: fileManager,
                currentUserID: currentUserID
            ) else {
                return nil
            }
            if directory == canonicalRoot { break }
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { return nil }
            directory = parent
        }
        return canonical
    }

    private static func canonicalURL(_ url: URL) -> URL? {
        guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
        guard let resolvedPath = realpath(url.path, nil) else { return nil }
        defer { free(resolvedPath) }
        return URL(fileURLWithPath: String(cString: resolvedPath))
    }

    private static func trustedItem(
        _ url: URL,
        expectedType: FileAttributeType,
        executable: Bool,
        allowsGroupWrite: Bool,
        requiredGroupID: gid_t?,
        fileManager: FileManager,
        currentUserID: uid_t
    ) -> Bool {
        guard
            let attributes = try? fileManager.attributesOfItem(
                atPath: url.path
            ),
            attributes[.type] as? FileAttributeType == expectedType,
            !executable || fileManager.isExecutableFile(atPath: url.path),
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
            owner == 0 || owner == currentUserID,
            let permissions =
                (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
            permissions & (allowsGroupWrite ? 0o002 : 0o022) == 0
        else {
            return false
        }
        if permissions & 0o020 != 0 {
            guard
                allowsGroupWrite,
                let requiredGroupID,
                let groupID =
                    (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value,
                groupID == requiredGroupID
            else {
                return false
            }
        }
        return true
    }
}

/// Resolves provider tools only from explicit system installation roots. It
/// intentionally does not search `PATH`, `~/.local`, NVM, or other automatic
/// user-managed locations. Known Homebrew roots are a local-admin boundary:
/// group-writable ancestors are accepted only within that root, only for the
/// root's group, and never for the executable leaf. Parallax cannot defend
/// against another process already running as the same user or local admin.
struct ProviderExecutableLocator {
    private struct SearchLocation {
        let directory: URL
        let trustRoot: URL
        let allowsGroupWritableAncestors: Bool
    }

    private let fileManager: FileManager
    private let currentUserID: uid_t
    private let locations: [SearchLocation]

    init(
        fileManager: FileManager = .default,
        currentUserID: uid_t = getuid(),
        fixedDirectories: [URL]? = nil,
        homebrewRoots: [URL]? = nil
    ) {
        self.fileManager = fileManager
        self.currentUserID = currentUserID
        if fixedDirectories != nil || homebrewRoots != nil {
            let strictLocations = (fixedDirectories ?? []).map {
                SearchLocation(
                    directory: $0,
                    trustRoot: $0,
                    allowsGroupWritableAncestors: false
                )
            }
            let homebrewLocations = (homebrewRoots ?? []).map {
                SearchLocation(
                    directory: $0.appendingPathComponent("bin"),
                    trustRoot: $0,
                    allowsGroupWritableAncestors: true
                )
            }
            locations = strictLocations + homebrewLocations
        } else {
            locations = [
                SearchLocation(
                    directory: URL(fileURLWithPath: "/opt/homebrew/bin"),
                    trustRoot: URL(fileURLWithPath: "/opt/homebrew"),
                    allowsGroupWritableAncestors: true
                ),
                SearchLocation(
                    directory: URL(fileURLWithPath: "/usr/local/bin"),
                    trustRoot: URL(fileURLWithPath: "/usr/local"),
                    allowsGroupWritableAncestors: true
                ),
                SearchLocation(
                    directory: URL(fileURLWithPath: "/usr/bin"),
                    trustRoot: URL(fileURLWithPath: "/usr"),
                    allowsGroupWritableAncestors: false
                ),
            ]
        }
    }

    func locate(
        named name: String
    ) throws -> TrustedProviderExecutable {
        for location in locations {
            let candidate = location.directory.appendingPathComponent(
                name,
                isDirectory: false
            )
            if let validated = ProviderExecutableTrustPolicy.validate(
                candidate,
                beneath: location.trustRoot,
                allowsGroupWritableAncestors:
                    location.allowsGroupWritableAncestors,
                fileManager: fileManager,
                currentUserID: currentUserID
            ) {
                return TrustedProviderExecutable(
                    url: validated,
                    trustRoot: location.trustRoot,
                    currentUserID: currentUserID,
                    allowsGroupWritableAncestors:
                        location.allowsGroupWritableAncestors
                )
            }
        }

        throw ProviderExecutableLocatorError.missing(name)
    }
}

struct ProviderSubprocessEnvironment {
    private static let safePath =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private static let inheritedLocaleKeys: Set<String> = [
        "LANG",
        "LC_ALL",
        "LC_COLLATE",
        "LC_CTYPE",
        "LC_MESSAGES",
        "LC_MONETARY",
        "LC_NUMERIC",
        "LC_TIME",
        "__CF_USER_TEXT_ENCODING",
    ]
    private static let allowedAdditions: Set<String> = ["CODEX_HOME"]

    static func make(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        identity: ChildEnvironmentIdentity = .current,
        additions: [String: String] = [:]
    ) -> [String: String] {
        var environment = processEnvironment.filter {
            inheritedLocaleKeys.contains($0.key)
        }
        environment["PATH"] = safePath
        environment["HOME"] = identity.homeDirectory
        environment["USER"] = identity.userName
        environment["LOGNAME"] = identity.userName
        environment["TMPDIR"] = identity.temporaryDirectory
        for (key, value) in additions where allowedAdditions.contains(key) {
            environment[key] = value
        }
        return environment
    }
}

struct ProviderAuthURLPolicy {
    private static let allowedRegistrableDomains = [
        "openai.com",
        "chatgpt.com",
    ]

    static func validatedCodexURL(_ value: String) -> URL? {
        guard
            value.count <= 8_192,
            let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            components.user == nil,
            components.password == nil,
            let host = components.host?.lowercased(),
            allowedRegistrableDomains.contains(where: {
                host == $0 || host.hasSuffix(".\($0)")
            }),
            let url = components.url
        else {
            return nil
        }
        return url
    }
}

struct ProviderAuthURLOpener: Sendable {
    private let operation: @MainActor @Sendable (URL) -> Bool

    init(operation: @escaping @MainActor @Sendable (URL) -> Bool) {
        self.operation = operation
    }

    @MainActor
    func open(_ url: URL) -> Bool {
        operation(url)
    }

    static let workspace = ProviderAuthURLOpener { url in
        NSWorkspace.shared.open(url)
    }
}

private final class ProviderProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()

    init(maximumBytes: Int = 64 * 1_024) {
        self.maximumBytes = maximumBytes
    }

    func append(_ incoming: Data) {
        guard !incoming.isEmpty else { return }
        lock.withLock {
            data.append(incoming)
            if data.count > maximumBytes {
                data = Data(data.suffix(maximumBytes))
            }
        }
    }

    func string() -> String {
        lock.withLock {
            String(data: data, encoding: .utf8) ?? ""
        }
    }
}

struct ProviderDeadline: Sendable {
    private let uptime: TimeInterval

    init(after seconds: TimeInterval) {
        uptime = ProcessInfo.processInfo.systemUptime + max(0, seconds)
    }

    var hasExpired: Bool {
        ProcessInfo.processInfo.systemUptime >= uptime
    }
}

enum ProviderProcessFailure: Error, Equatable {
    case unsafeExecutable
    case launchFailed
    case timedOut
    case cancelled
}

struct ProviderProcessResult: Equatable {
    let status: Int32
    let output: String
}

enum ProviderProcessLifecycle {
    static func terminateAndReap(
        _ process: Process,
        gracePeriod: TimeInterval = 0.25
    ) {
        if process.isRunning {
            process.terminate()
            let deadline = ProviderDeadline(after: gracePeriod)
            while process.isRunning && !deadline.hasExpired {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
    }
}

struct ProviderProcessRunner {
    static func run(
        executable: TrustedProviderExecutable,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        cancellationCheck: @escaping @Sendable () -> Bool = { false },
        startedHandler: (@Sendable (pid_t) -> Void)? = nil
    ) throws -> ProviderProcessResult {
        guard timeout.isFinite, timeout > 0 else {
            throw ProviderProcessFailure.timedOut
        }

        let executableURL: URL
        do {
            executableURL = try executable.revalidatedURL()
        } catch {
            throw ProviderProcessFailure.unsafeExecutable
        }
        guard !cancellationCheck() else {
            throw ProviderProcessFailure.cancelled
        }

        let process = Process()
        let output = Pipe()
        let collector = ProviderProcessOutputCollector()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProviderSubprocessEnvironment.make(
            additions: environment
        )
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }

        do {
            try process.run()
            startedHandler?(process.processIdentifier)
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw ProviderProcessFailure.launchFailed
        }

        let deadline = ProviderDeadline(after: timeout)
        var failure: ProviderProcessFailure?
        while process.isRunning {
            if cancellationCheck() {
                failure = .cancelled
                break
            }
            if deadline.hasExpired {
                failure = .timedOut
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if failure != nil {
            ProviderProcessLifecycle.terminateAndReap(process)
        } else {
            process.waitUntilExit()
        }
        output.fileHandleForReading.readabilityHandler = nil
        collector.append(output.fileHandleForReading.readDataToEndOfFile())
        if let failure { throw failure }
        return ProviderProcessResult(
            status: process.terminationStatus,
            output: collector.string().trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        )
    }
}

enum ProviderNumericDecoder {
    static let maximumExactInteger = 9_007_199_254_740_991.0
    static let maximumUnixTimestamp = 32_503_680_000.0

    static func percentage(_ value: Any?) -> Int? {
        guard
            let number = finiteDouble(value),
            (0...100).contains(number)
        else {
            return nil
        }
        return Int(number.rounded())
    }

    static func tokenCount(_ value: Any?) -> Int? {
        guard
            let number = finiteDouble(value),
            number >= 0,
            number <= maximumExactInteger,
            number.rounded(.towardZero) == number
        else {
            return nil
        }
        return Int(number)
    }

    static func unixDate(_ value: Any?) -> Date? {
        guard
            let number = finiteDouble(value),
            (0...maximumUnixTimestamp).contains(number)
        else {
            return nil
        }
        return Date(timeIntervalSince1970: number)
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        let number: Double?
        if let value = value as? NSNumber {
            number = value.doubleValue
        } else if let value = value as? String {
            number = Double(value)
        } else {
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }
}

enum AIAccountConnectionService {
    static func login(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus {
        try await runCancellableWorker(priority: .userInitiated) {
            switch provider {
            case .codex:
                try await runCodexLogin(accountID: accountID)
                return try readCodexStatus(accountID: accountID)
            case .claude:
                try runClaudeLogin()
                return try readClaudeStatus()
            }
        }
    }

    static func refresh(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus {
        try await runCancellableWorker(priority: .utility) {
            switch provider {
            case .codex:
                try readCodexStatus(accountID: accountID)
            case .claude:
                try readClaudeStatus()
            }
        }
    }

    private static func runCodexLogin(
        accountID: UUID,
        urlOpener: ProviderAuthURLOpener = .workspace
    ) async throws {
        try Task.checkCancellation()
        let executable = try trustedExecutable(named: "codex")
        let home = try codexHome(accountID: accountID)
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let collector = JSONLineResponseCollector()
        let errorCollector = ProviderProcessOutputCollector()

        do {
            process.executableURL = try executable.revalidatedURL()
        } catch {
            throw AIAccountConnectionError.executableMissing("Codex")
        }
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = ProviderSubprocessEnvironment.make(
            additions: ["CODEX_HOME": home.path]
        )
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            errorCollector.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw AIAccountConnectionError.loginFailed
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            ProviderProcessLifecycle.terminateAndReap(process)
        }

        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "parallax",
                        "title": "Parallax",
                        "version": "0.1.0"
                    ]
                ]
            ],
            ["method": "initialized", "params": [:]],
            [
                "method": "account/login/start",
                "id": 4,
                "params": [
                    "type": "chatgpt",
                    "useHostedLoginSuccessPage": true,
                    "appBrand": "codex"
                ]
            ]
        ]
        for message in messages {
            let data = try JSONSerialization.data(withJSONObject: message)
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write(Data([0x0A]))
        }

        let startDeadline = ProviderDeadline(after: 15)
        while !startDeadline.hasExpired && collector.response(id: 4) == nil {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw AIAccountConnectionError.loginFailed
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let startResponse = collector.response(id: 4) else {
            throw AIAccountConnectionError.loginFailed
        }
        if startResponse["error"] != nil {
            throw AIAccountConnectionError.loginFailed
        }
        guard
            let result = startResponse["result"] as? [String: Any],
            let loginID = result["loginId"] as? String,
            let authURL = result["authUrl"] as? String,
            let validatedAuthURL = ProviderAuthURLPolicy
                .validatedCodexURL(authURL)
        else {
            throw AIAccountConnectionError.loginFailed
        }

        guard await urlOpener.open(validatedAuthURL) else {
            throw AIAccountConnectionError.loginFailed
        }

        let completionDeadline = ProviderDeadline(after: 300)
        while !completionDeadline.hasExpired {
            try Task.checkCancellation()
            if let notification = collector.loginCompletion(loginID: loginID) {
                if notification["success"] as? Bool == true { return }
                throw AIAccountConnectionError.loginFailed
            }
            if !process.isRunning {
                throw AIAccountConnectionError.loginFailed
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AIAccountConnectionError.loginFailed
    }

    private static func runClaudeLogin() throws {
        let executable = try trustedExecutable(named: "claude")
        let result: ProviderProcessResult
        do {
            result = try ProviderProcessRunner.run(
                executable: executable,
                arguments: ["auth", "login", "--claudeai"],
                environment: [:],
                timeout: 300,
                cancellationCheck: { Task.isCancelled }
            )
        } catch ProviderProcessFailure.cancelled {
            throw CancellationError()
        } catch {
            throw AIAccountConnectionError.loginFailed
        }
        guard result.status == 0 else {
            throw AIAccountConnectionError.loginFailed
        }
    }

    private static func readClaudeStatus() throws -> ConnectedAIAccountStatus {
        let executable = try trustedExecutable(named: "claude")
        let result: ProviderProcessResult
        do {
            result = try ProviderProcessRunner.run(
                executable: executable,
                arguments: ["auth", "status", "--json"],
                environment: [:],
                timeout: 15,
                cancellationCheck: { Task.isCancelled }
            )
        } catch ProviderProcessFailure.cancelled {
            throw CancellationError()
        } catch {
            throw AIAccountConnectionError.statusUnavailable
        }
        guard result.status == 0 else {
            throw AIAccountConnectionError.notAuthenticated
        }
        guard
            let data = result.output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            throw AIAccountConnectionError.statusUnavailable
        }

        let loggedIn = json["loggedIn"] as? Bool
            ?? json["isAuthenticated"] as? Bool
            ?? true
        guard loggedIn else {
            throw AIAccountConnectionError.notAuthenticated
        }
        let email = json["email"] as? String
            ?? (json["account"] as? [String: Any])?["email"] as? String
        let plan = json["subscriptionType"] as? String
            ?? json["plan"] as? String
            ?? json["authMethod"] as? String

        return ConnectedAIAccountStatus(
            email: email,
            planName: plan,
            usagePercent: nil,
            resetsAt: nil,
            lifetimeTokens: nil
        )
    }

    private static func readCodexStatus(
        accountID: UUID
    ) throws -> ConnectedAIAccountStatus {
        try Task.checkCancellation()
        let executable = try trustedExecutable(named: "codex")
        let home = try codexHome(accountID: accountID)
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let collector = JSONLineResponseCollector()
        let errorCollector = ProviderProcessOutputCollector()

        do {
            process.executableURL = try executable.revalidatedURL()
        } catch {
            throw AIAccountConnectionError.executableMissing("Codex")
        }
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = ProviderSubprocessEnvironment.make(
            additions: ["CODEX_HOME": home.path]
        )
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            errorCollector.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw AIAccountConnectionError.statusUnavailable
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            ProviderProcessLifecycle.terminateAndReap(process)
        }

        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "parallax",
                        "title": "Parallax",
                        "version": "0.1.0"
                    ]
                ]
            ],
            ["method": "initialized", "params": [:]],
            [
                "method": "account/read",
                "id": 1,
                "params": ["refreshToken": false]
            ],
            ["method": "account/rateLimits/read", "id": 2],
            ["method": "account/usage/read", "id": 3]
        ]

        do {
            for message in messages {
                let data = try JSONSerialization.data(withJSONObject: message)
                input.fileHandleForWriting.write(data)
                input.fileHandleForWriting.write(Data([0x0A]))
            }
        } catch {
            throw AIAccountConnectionError.statusUnavailable
        }

        let deadline = ProviderDeadline(after: 15)
        while !deadline.hasExpired {
            try Task.checkCancellation()
            if collector.response(id: 1) != nil,
               collector.response(id: 2) != nil,
               collector.response(id: 3) != nil
            {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard
            let accountResponse = collector.response(id: 1),
            let result = accountResponse["result"] as? [String: Any],
            let account = result["account"] as? [String: Any]
        else {
            throw AIAccountConnectionError.notAuthenticated
        }

        let accountType = account["type"] as? String
        guard accountType == "chatgpt" || accountType == "chatgptAuthTokens" else {
            throw AIAccountConnectionError.statusUnavailable
        }

        var usedPercent: Int?
        var resetsAt: Date?
        if
            let rateResponse = collector.response(id: 2),
            let rateResult = rateResponse["result"] as? [String: Any]
        {
            let multi = rateResult["rateLimitsByLimitId"] as? [String: Any]
            let codexBucket = multi?["codex"] as? [String: Any]
            let fallback = rateResult["rateLimits"] as? [String: Any]
            let bucket = codexBucket ?? fallback
            let primary = bucket?["primary"] as? [String: Any]
            usedPercent = ProviderNumericDecoder.percentage(
                primary?["usedPercent"]
            )
            resetsAt = ProviderNumericDecoder.unixDate(primary?["resetsAt"])
        }

        var lifetimeTokens: Int?
        if
            let usageResponse = collector.response(id: 3),
            let usageResult = usageResponse["result"] as? [String: Any],
            let summary = usageResult["summary"] as? [String: Any]
        {
            lifetimeTokens = ProviderNumericDecoder.tokenCount(
                summary["lifetimeTokens"]
            )
        }

        return ConnectedAIAccountStatus(
            email: account["email"] as? String,
            planName: account["planType"] as? String,
            usagePercent: usedPercent,
            resetsAt: resetsAt,
            lifetimeTokens: lifetimeTokens
        )
    }

    private static func codexHome(accountID: UUID) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("AccountSessions", isDirectory: true)
            .appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("CodexHome", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return directory
    }

    private static func trustedExecutable(
        named name: String
    ) throws -> TrustedProviderExecutable {
        do {
            return try ProviderExecutableLocator().locate(named: name)
        } catch {
            throw AIAccountConnectionError.executableMissing(name.capitalized)
        }
    }

    private static func runCancellableWorker<T: Sendable>(
        priority: TaskPriority,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let worker = Task.detached(priority: priority, operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

private final class JSONLineResponseCollector: @unchecked Sendable {
    private static let maximumBufferedBytes = 256 * 1_024
    private static let maximumLineBytes = 64 * 1_024
    private static let maximumStoredMessages = 16
    private let lock = NSLock()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var loginCompletions: [String: [String: Any]] = [:]

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        guard buffer.count <= Self.maximumBufferedBytes else {
            buffer.removeAll(keepingCapacity: true)
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard
                !line.isEmpty,
                line.count <= Self.maximumLineBytes,
                let object = try? JSONSerialization.jsonObject(with: line),
                let message = object as? [String: Any]
            else { continue }
            if let id = message["id"] as? NSNumber {
                guard responses[id.intValue] != nil
                    || responses.count < Self.maximumStoredMessages
                else { continue }
                responses[id.intValue] = message
            } else if
                message["method"] as? String == "account/login/completed",
                let params = message["params"] as? [String: Any],
                let loginID = params["loginId"] as? String
            {
                guard loginCompletions[loginID] != nil
                    || loginCompletions.count < Self.maximumStoredMessages
                else { continue }
                loginCompletions[loginID] = params
            }
        }
    }

    func response(id: Int) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return responses[id]
    }

    func loginCompletion(loginID: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return loginCompletions[loginID]
    }
}
