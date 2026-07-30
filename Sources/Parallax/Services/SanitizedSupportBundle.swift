import Foundation

enum SanitizedSupportBundleError: LocalizedError {
    case encodedSizeLimitExceeded

    var errorDescription: String? {
        "The sanitized support bundle exceeded its safe size limit."
    }
}

struct SanitizedSupportBundle: Codable, Equatable, Sendable {
    struct Runtime: Codable, Equatable, Sendable {
        let parallaxVersion: String
        let operatingSystem: String
        let architecture: String
    }

    struct Settings: Codable, Equatable, Sendable {
        let automaticCrashRecoveryEnabled: Bool
        let confirmBeforeLaunch: Bool
        let appearance: String
    }

    struct PersistenceHealth: Codable, Equatable, Sendable {
        let libraryHistoryAvailable: Bool
        let recoveryLedgerAvailable: Bool
        let workaroundStateAvailable: Bool
    }

    struct Application: Codable, Equatable, Sendable {
        let bundleIdentifier: String?
        let preset: String
        let profileCount: Int
    }

    struct Activity: Codable, Equatable, Sendable {
        let profileIndex: Int?
        let state: String
        let openingDelaySeconds: Int?
        let durationSeconds: Int?
        let terminationDisposition: String?
        let crashExceptionType: String?
        let crashSignal: String?
    }

    struct Workaround: Codable, Equatable, Sendable {
        let profileIndex: Int?
        let identifier: String
        let definitionVersion: Int
        let state: String
    }

    let schemaVersion: Int
    let generatedAt: Date
    let runtime: Runtime
    let settings: Settings
    let persistenceHealth: PersistenceHealth
    let application: Application
    let activity: [Activity]
    let workarounds: [Workaround]
    let redactedFields: [String]
}

struct SanitizedSupportBundleService: Sendable {
    private static let schemaVersion = 1
    private static let maximumActivityCount = 200
    private static let maximumWorkaroundCount = 200
    private static let maximumEncodedBytes = 256 * 1_024
    private static let recognizedWorkaroundIdentifiers = [
        "openai.remote-hosted-pip.hide.v1"
    ]

    func makeBundle(
        application: ManagedApplication,
        history: [LaunchHistoryEntry],
        crashReports: [UUID: ApplicationCrashReport],
        workaroundRecords: [ManagedAppWorkaroundRecord],
        settings: AppSettingsSnapshot,
        persistenceHealth:
            SanitizedSupportBundle.PersistenceHealth,
        generatedAt: Date = Date(),
        runtime: SanitizedSupportBundle.Runtime =
            currentRuntime()
    ) -> SanitizedSupportBundle {
        let profileIndexes = Dictionary(
            uniqueKeysWithValues:
                application.profiles.enumerated().map {
                    ($0.element.storageID, $0.offset + 1)
                }
        )
        let activity = history
            .prefix(Self.maximumActivityCount)
            .map { entry in
                let crash = crashReports[entry.requestID]
                return SanitizedSupportBundle.Activity(
                    profileIndex:
                        profileIndexes[entry.profileStorageID],
                    state: entry.state.rawValue,
                    openingDelaySeconds: entry.startedAt.map {
                        roundedSeconds(
                            $0.timeIntervalSince(entry.requestedAt)
                        )
                    },
                    durationSeconds: entry.duration.map(
                        roundedSeconds
                    ),
                    terminationDisposition:
                        entry.terminationDisposition?.rawValue,
                    crashExceptionType:
                        sanitizedDiagnosticToken(
                            crash?.exceptionType
                        ),
                    crashSignal:
                        sanitizedDiagnosticToken(crash?.signal)
                )
            }
        let workarounds = workaroundRecords
            .prefix(Self.maximumWorkaroundCount)
            .map {
                SanitizedSupportBundle.Workaround(
                    profileIndex:
                        profileIndexes[$0.profileStorageID],
                    identifier:
                        Self.recognizedWorkaroundIdentifiers
                        .contains($0.workaroundID)
                        ? $0.workaroundID
                        : "unrecognized",
                    definitionVersion: $0.definitionVersion,
                    state: $0.state.rawValue
                )
            }

        return SanitizedSupportBundle(
            schemaVersion: Self.schemaVersion,
            generatedAt: generatedAt,
            runtime: runtime,
            settings: .init(
                automaticCrashRecoveryEnabled:
                    settings.automaticCrashRecoveryEnabled,
                confirmBeforeLaunch:
                    settings.confirmBeforeLaunch,
                appearance: settings.appearance
            ),
            persistenceHealth: persistenceHealth,
            application: .init(
                bundleIdentifier:
                    sanitizedBundleIdentifier(
                        application.bundleIdentifier
                    ),
                preset: application.preset.rawValue,
                profileCount: application.profiles.count
            ),
            activity: activity,
            workarounds: workarounds,
            redactedFields: [
                "application and profile names",
                "logical and storage UUIDs",
                "application and storage paths",
                "process identifiers and start times",
                "launch arguments and environment values",
                "profile notes and Keychain references",
                "crash report paths, incident IDs, and free-form reasons",
                "workaround operator notes and configuration references",
                "library and recovery error messages",
            ]
        )
    }

    func encode(_ bundle: SanitizedSupportBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let data = try encoder.encode(bundle)
        guard data.count <= Self.maximumEncodedBytes else {
            throw SanitizedSupportBundleError
                .encodedSizeLimitExceeded
        }
        return data
    }

    private func roundedSeconds(_ value: TimeInterval) -> Int {
        Int(max(0, min(value.rounded(), 31_536_000)))
    }

    private func sanitizedBundleIdentifier(
        _ value: String?
    ) -> String? {
        guard
            let value,
            value.count <= 255,
            value.unicodeScalars.allSatisfy({
                CharacterSet(
                    charactersIn:
                        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"
                ).contains($0)
            })
        else {
            return nil
        }
        return value
    }

    private func sanitizedDiagnosticToken(
        _ value: String?
    ) -> String? {
        guard let value else { return nil }
        let sanitized = String(
            value.unicodeScalars.filter {
                CharacterSet(
                    charactersIn:
                        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-. "
                ).contains($0)
            }.prefix(100)
        )
        return sanitized.isEmpty ? nil : sanitized
    }

    private static func currentRuntime()
        -> SanitizedSupportBundle.Runtime
    {
        let info = Bundle.main.infoDictionary
        let version =
            [
                info?["CFBundleShortVersionString"] as? String,
                info?["CFBundleVersion"] as? String,
            ]
            .compactMap { $0 }
            .joined(separator: " (")
        let normalizedVersion = version.isEmpty
            ? "development"
            : version + (version.contains("(") ? ")" : "")
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return SanitizedSupportBundle.Runtime(
            parallaxVersion: normalizedVersion,
            operatingSystem:
                ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture
        )
    }
}

struct AppSettingsSnapshot: Equatable, Sendable {
    let automaticCrashRecoveryEnabled: Bool
    let confirmBeforeLaunch: Bool
    let appearance: String
}
