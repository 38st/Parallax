import Foundation

enum ChildEnvironmentPolicy: String, Codable, CaseIterable, Sendable {
    case safeDefault
    case inheritProcessEnvironment

    private static let safePath = "/usr/bin:/bin:/usr/sbin:/sbin"
    private static let inheritedLocaleKeys: Set<String> = [
        "LANG",
        "LC_ADDRESS",
        "LC_ALL",
        "LC_COLLATE",
        "LC_CTYPE",
        "LC_IDENTIFICATION",
        "LC_MEASUREMENT",
        "LC_MESSAGES",
        "LC_MONETARY",
        "LC_NAME",
        "LC_NUMERIC",
        "LC_PAPER",
        "LC_TELEPHONE",
        "LC_TIME",
        "__CF_USER_TEXT_ENCODING",
    ]
    private static let scrubbedInheritedKeys: Set<String> = [
        "CODEX_HOME",
    ]
    private static let scrubbedInheritedPrefixes = [
        "DYLD_",
        "LD_",
    ]

    func baseEnvironment(
        processEnvironment: [String: String],
        identity: ChildEnvironmentIdentity
    ) -> [String: String] {
        var result: [String: String]
        switch self {
        case .safeDefault:
            result = processEnvironment.filter {
                Self.inheritedLocaleKeys.contains($0.key)
            }
            result["PATH"] = Self.safePath
        case .inheritProcessEnvironment:
            result = processEnvironment
            result = result.filter { key, _ in
                !Self.scrubbedInheritedKeys.contains(key)
                    && !Self.scrubbedInheritedPrefixes.contains {
                        key.hasPrefix($0)
                    }
            }
            if result["PATH"] == nil {
                result["PATH"] = Self.safePath
            }
        }

        // These values come from trusted process APIs rather than a possibly
        // modified shell environment.
        result["HOME"] = identity.homeDirectory
        result["USER"] = identity.userName
        result["LOGNAME"] = identity.userName
        result["TMPDIR"] = identity.temporaryDirectory
        return result
    }
}

struct ChildEnvironmentIdentity: Sendable, Equatable {
    let homeDirectory: String
    let userName: String
    let temporaryDirectory: String

    static var current: ChildEnvironmentIdentity {
        ChildEnvironmentIdentity(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            userName: NSUserName(),
            temporaryDirectory: FileManager.default.temporaryDirectory.path
        )
    }
}

struct PathSpecificTildeExpander: Sendable {
    private let homeDirectory: String
    private let environmentPathKeys: Set<String>
    private let argumentPathOptions: Set<String>

    init(
        homeDirectory: String,
        environmentPathKeys: Set<String> = ["CODEX_HOME"],
        argumentPathOptions: Set<String> = ["--user-data-dir"]
    ) {
        self.homeDirectory = URL(
            fileURLWithPath: homeDirectory,
            isDirectory: true
        ).standardizedFileURL.path
        self.environmentPathKeys = environmentPathKeys
        self.argumentPathOptions = argumentPathOptions
    }

    func environmentValue(_ value: String, forKey key: String) -> String {
        guard environmentPathKeys.contains(key) else { return value }
        return expandPathValue(value)
    }

    func argumentValue(_ value: String, forOption option: String) -> String {
        guard argumentPathOptions.contains(option) else { return value }
        return expandPathValue(value)
    }

    private func expandPathValue(_ value: String) -> String {
        if value == "~" {
            return homeDirectory
        }
        guard value.hasPrefix("~/") else {
            // Named-user expansion is deliberately unsupported. The launch
            // configuration retains the literal value for validation.
            return value
        }
        return homeDirectory + String(value.dropFirst())
    }
}

struct LaunchEnvironmentPreparer: Sendable {
    private let policy: ChildEnvironmentPolicy
    private let identity: ChildEnvironmentIdentity
    private let processEnvironment: [String: String]
    private let secretResolver: any SecretResolving
    private let tildeExpander: PathSpecificTildeExpander

    init(
        policy: ChildEnvironmentPolicy,
        identity: ChildEnvironmentIdentity = .current,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        secretResolver: any SecretResolving = KeychainSecretStore()
    ) {
        self.policy = policy
        self.identity = identity
        self.processEnvironment = processEnvironment
        self.secretResolver = secretResolver
        tildeExpander = PathSpecificTildeExpander(
            homeDirectory: identity.homeDirectory
        )
    }

    func prepare(
        _ assignments: [StoredEnvironmentAssignment],
        unsetKeys: Set<String> = []
    ) async throws -> [String: String] {
        var environment = policy.baseEnvironment(
            processEnvironment: processEnvironment,
            identity: identity
        )

        for assignment in assignments {
            let value: String
            switch assignment.value {
            case .literal(let literal):
                value = literal
            case .secretReference(let reference):
                let secret = try await secretResolver.resolve(reference)
                value = secret.withValue { $0 }
            }
            environment[assignment.key] = tildeExpander.environmentValue(
                value,
                forKey: assignment.key
            )
        }
        for key in unsetKeys {
            environment.removeValue(forKey: key)
        }
        return environment
    }
}
