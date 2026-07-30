import Foundation
import Observation

struct ManagedAppRecoveryKey: Hashable, Sendable {
    let applicationStorageID: UUID
    let profileStorageID: UUID
}

enum ManagedAppRecoveryDecision: Equatable, Sendable {
    case retry(after: TimeInterval, attempt: Int, maximumAttempts: Int)
    case circuitOpen(retryAfter: Date)
}

struct ManagedAppRecoveryPolicy: Sendable {
    let maximumAttempts: Int
    let rollingWindow: TimeInterval
    let backoff: [TimeInterval]

    private var crashDates:
        [ManagedAppRecoveryKey: [Date]] = [:]

    init(
        maximumAttempts: Int = 2,
        rollingWindow: TimeInterval = 10 * 60,
        backoff: [TimeInterval] = [2, 8]
    ) {
        self.maximumAttempts = max(0, maximumAttempts)
        self.rollingWindow = max(1, rollingWindow)
        self.backoff = backoff.isEmpty ? [0] : backoff
    }

    mutating func decision(
        for key: ManagedAppRecoveryKey,
        confirmedCrashAt date: Date
    ) -> ManagedAppRecoveryDecision {
        let cutoff = date.addingTimeInterval(-rollingWindow)
        var recent = crashDates[key, default: []]
            .filter { $0 >= cutoff && $0 <= date }
        recent.append(date)
        crashDates[key] = recent

        let attempt = recent.count
        guard attempt <= maximumAttempts else {
            let oldest = recent.min() ?? date
            return .circuitOpen(
                retryAfter: oldest.addingTimeInterval(rollingWindow)
            )
        }
        let delay = backoff[
            min(attempt - 1, backoff.count - 1)
        ]
        return .retry(
            after: delay,
            attempt: attempt,
            maximumAttempts: maximumAttempts
        )
    }

    mutating func reset(for key: ManagedAppRecoveryKey) {
        crashDates.removeValue(forKey: key)
    }
}

enum ManagedAppRecoveryLedgerError: LocalizedError {
    case invalidDocument
    case unsupportedSchema(Int)
    case persistenceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            "Automatic-recovery history could not be read."
        case let .unsupportedSchema(version):
            "Automatic-recovery history uses unsupported format \(version)."
        case let .persistenceUnavailable(detail):
            "Automatic recovery is paused because its retry history is unavailable: \(detail)"
        }
    }
}

@Observable
@MainActor
final class ManagedAppRecoveryLedger {
    private struct Record: Codable {
        let applicationStorageID: UUID
        let profileStorageID: UUID
        var confirmedCrashDates: [Date]
    }

    private struct Document: Codable {
        let schemaVersion: Int
        var records: [Record]
    }

    private static let schemaVersion = 1
    private static let fileName = "managed-app-recovery.json"
    private static let lockFileName = ".managed-app-recovery.lock"
    private static let maximumDocumentBytes = 512 * 1_024

    private(set) var persistenceErrorMessage: String?

    @ObservationIgnored private let storageURL: URL?
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let maximumAttempts: Int
    @ObservationIgnored private let rollingWindow: TimeInterval
    @ObservationIgnored private let backoff: [TimeInterval]
    @ObservationIgnored private var memoryDates:
        [ManagedAppRecoveryKey: [Date]] = [:]

    init(
        maximumAttempts: Int = 2,
        rollingWindow: TimeInterval = 10 * 60,
        backoff: [TimeInterval] = [2, 8],
        persistenceErrorMessage: String? = nil
    ) {
        storageURL = nil
        fileManager = .default
        self.maximumAttempts = max(0, maximumAttempts)
        self.rollingWindow = max(1, rollingWindow)
        self.backoff = backoff.isEmpty ? [0] : backoff
        self.persistenceErrorMessage = persistenceErrorMessage
    }

    init(
        applicationSupportURL: URL,
        maximumAttempts: Int = 2,
        rollingWindow: TimeInterval = 10 * 60,
        backoff: [TimeInterval] = [2, 8],
        fileManager: FileManager = .default
    ) throws {
        let directory = applicationSupportURL
            .appendingPathComponent("Parallax", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [
                .posixPermissions: NSNumber(value: Int16(0o700))
            ]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
        storageURL = directory.appendingPathComponent(
            Self.fileName,
            isDirectory: false
        )
        self.fileManager = fileManager
        self.maximumAttempts = max(0, maximumAttempts)
        self.rollingWindow = max(1, rollingWindow)
        self.backoff = backoff.isEmpty ? [0] : backoff
        persistenceErrorMessage = nil
    }

    func decision(
        for key: ManagedAppRecoveryKey,
        confirmedCrashAt date: Date
    ) throws -> ManagedAppRecoveryDecision {
        guard let storageURL else {
            if let persistenceErrorMessage {
                throw ManagedAppRecoveryLedgerError
                    .persistenceUnavailable(
                        persistenceErrorMessage
                    )
            }
            return memoryDecision(for: key, at: date)
        }

        do {
            return try lock(for: storageURL).withExclusiveLock {
                var document = try readDocument(from: storageURL)
                let cutoff = date.addingTimeInterval(-rollingWindow)
                document.records = document.records.compactMap {
                    record in
                    var record = record
                    record.confirmedCrashDates.removeAll {
                        $0 < cutoff
                    }
                    return record.confirmedCrashDates.isEmpty
                        ? nil
                        : record
                }
                let index = document.records.firstIndex {
                    $0.applicationStorageID
                            == key.applicationStorageID
                        && $0.profileStorageID
                            == key.profileStorageID
                }
                var dates = index.map {
                    document.records[$0].confirmedCrashDates
                } ?? []
                dates = dates.filter { $0 <= date }
                dates.append(date)
                if let index {
                    document.records[index].confirmedCrashDates =
                        dates
                } else {
                    document.records.append(
                        Record(
                            applicationStorageID:
                                key.applicationStorageID,
                            profileStorageID:
                                key.profileStorageID,
                            confirmedCrashDates: dates
                        )
                    )
                }
                try write(document, to: storageURL)
                persistenceErrorMessage = nil
                return recoveryDecision(
                    dates: dates,
                    at: date
                )
            }
        } catch {
            persistenceErrorMessage =
                ManagedAppRecoveryLedgerError
                    .persistenceUnavailable(
                        error.localizedDescription
                    ).localizedDescription
            throw error
        }
    }

    func reset(for key: ManagedAppRecoveryKey) throws {
        guard let storageURL else {
            memoryDates.removeValue(forKey: key)
            return
        }
        try lock(for: storageURL).withExclusiveLock {
            var document = try readDocument(from: storageURL)
            document.records.removeAll {
                $0.applicationStorageID == key.applicationStorageID
                    && $0.profileStorageID == key.profileStorageID
            }
            try write(document, to: storageURL)
        }
    }

    private func memoryDecision(
        for key: ManagedAppRecoveryKey,
        at date: Date
    ) -> ManagedAppRecoveryDecision {
        let cutoff = date.addingTimeInterval(-rollingWindow)
        var dates = memoryDates[key, default: []]
            .filter { $0 >= cutoff && $0 <= date }
        dates.append(date)
        memoryDates[key] = dates
        return recoveryDecision(dates: dates, at: date)
    }

    private func recoveryDecision(
        dates: [Date],
        at date: Date
    ) -> ManagedAppRecoveryDecision {
        let attempt = dates.count
        guard attempt <= maximumAttempts else {
            return .circuitOpen(
                retryAfter:
                    (dates.min() ?? date)
                    .addingTimeInterval(rollingWindow)
            )
        }
        return .retry(
            after: backoff[
                min(attempt - 1, backoff.count - 1)
            ],
            attempt: attempt,
            maximumAttempts: maximumAttempts
        )
    }

    private func readDocument(from url: URL) throws -> Document {
        guard fileManager.fileExists(atPath: url.path) else {
            return Document(
                schemaVersion: Self.schemaVersion,
                records: []
            )
        }
        let attributes = try fileManager.attributesOfItem(
            atPath: url.path
        )
        let byteCount =
            (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard
            byteCount > 0,
            byteCount <= Self.maximumDocumentBytes
        else {
            throw ManagedAppRecoveryLedgerError.invalidDocument
        }
        let document = try JSONDecoder().decode(
            Document.self,
            from: Data(contentsOf: url)
        )
        guard document.schemaVersion == Self.schemaVersion else {
            throw ManagedAppRecoveryLedgerError
                .unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    private func write(_ document: Document, to url: URL) throws {
        try JSONEncoder().encode(document)
            .write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private func lock(for url: URL) -> LibraryAdvisoryLock {
        LibraryAdvisoryLock(
            url: url.deletingLastPathComponent()
                .appendingPathComponent(Self.lockFileName),
            timeout: 2
        )
    }
}
