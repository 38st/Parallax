import CryptoKit
import Foundation

struct SettingsSourceSHA256: Hashable, Sendable {
    let hex: String

    fileprivate init(_ data: Data) {
        hex = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct SettingsVersionToken: Hashable, Sendable {
    let revision: SettingsRevision
    let sourceSHA256: SettingsSourceSHA256
}

struct SettingsRepositorySnapshot: Equatable, Sendable {
    let document: SettingsDocument
    let versionToken: SettingsVersionToken
    let originalBytes: Data
}

struct SettingsRepositoryEvidence: Equatable, Sendable {
    let originalBytes: Data
    let sourceSHA256: SettingsSourceSHA256
}

enum SettingsRepositoryUnavailable: Equatable, Sendable {
    case primaryFile(SettingsPrimaryFileAccessError)
}

enum SettingsRepositoryInspection: Equatable, Sendable {
    case missing
    case current(SettingsRepositorySnapshot)
    case future(schemaVersion: UInt64, evidence: SettingsRepositoryEvidence)
    case recoveryRequired(
        failure: SettingsDocumentCodecFailure,
        sourceSHA256: SettingsSourceSHA256
    )
    case unavailable(SettingsRepositoryUnavailable)
}

protocol SettingsRepositoryInspecting: Sendable {
    func inspect() -> SettingsRepositoryInspection
}

struct SettingsRepository: SettingsRepositoryInspecting, Sendable {
    static let maximumPrimaryBytes = 4 * 1_024 * 1_024

    private let primaryFileAccess: any SettingsPrimaryFileAccessing
    private let codec: SettingsDocumentCodec

    init(
        primaryFileAccess: any SettingsPrimaryFileAccessing,
        codec: SettingsDocumentCodec = SettingsDocumentCodec()
    ) {
        self.primaryFileAccess = primaryFileAccess
        self.codec = codec
    }

    func inspect() -> SettingsRepositoryInspection {
        switch primaryFileAccess.read(
            maximumBytes: Self.maximumPrimaryBytes
        ) {
        case .failure(let error):
            return .unavailable(.primaryFile(error))
        case .success(.missing):
            return .missing
        case .success(.bytes(let bytes)):
            let sourceSHA256 = SettingsSourceSHA256(bytes)
            switch codec.decode(bytes) {
            case .current(let document):
                return .current(
                    SettingsRepositorySnapshot(
                        document: document,
                        versionToken: SettingsVersionToken(
                            revision: document.revision,
                            sourceSHA256: sourceSHA256
                        ),
                        originalBytes: bytes
                    )
                )
            case .future(let schemaVersion, let originalBytes):
                return .future(
                    schemaVersion: schemaVersion,
                    evidence: SettingsRepositoryEvidence(
                        originalBytes: originalBytes,
                        sourceSHA256: sourceSHA256
                    )
                )
            case .invalid(let failure):
                return .recoveryRequired(
                    failure: failure,
                    sourceSHA256: sourceSHA256
                )
            }
        }
    }
}
