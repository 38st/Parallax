import CryptoKit
import Darwin
import Foundation

public struct RelayJournalEntry: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let taskID: UUID
    public let sequence: UInt64
    public let occurredAt: Date
    public let previousDigest: String?
    public let payload: Data
    public let digest: String

    public init(
        schemaVersion: UInt16 = 1,
        taskID: UUID,
        sequence: UInt64,
        occurredAt: Date,
        previousDigest: String?,
        payload: Data,
        digest: String
    ) {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.previousDigest = previousDigest
        self.payload = payload
        self.digest = digest
    }
}

public enum RelayEventJournalError: Error, Equatable, Sendable {
    case unsafeRoot
    case unsafeTaskDirectory
    case invalidTaskName(String)
    case invalidRecordName(String)
    case recordTooLarge
    case corruptRecord(UInt64)
    case wrongTask(UInt64)
    case brokenSequence(expected: UInt64, actual: UInt64)
    case brokenChain(UInt64)
    case duplicateRecord(UInt64)
    case sequenceOverflow
    case durableWriteFailed(Int32)
}

/// A process-local append authority backed by atomic, hash-chained records.
///
/// Relay deliberately stores one record per file. A torn or partially written
/// record cannot make an earlier accepted prefix unreadable, and projections
/// remain disposable. Cross-process execution is not part of the local MVP;
/// callers must use the single application-owned instance of this actor.
public actor RelayEventJournal {
    public static let maximumPayloadBytes = 4 * 1_024 * 1_024

    private let root: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public func prepare() throws {
        try ensureManagedDirectory(root, mode: 0o700)
    }

    public func taskIDs() throws -> [UUID] {
        try prepare()
        return try fileManager.contentsOfDirectory(atPath: root.path)
            .map { name in
                guard let identifier = UUID(uuidString: name) else {
                    throw RelayEventJournalError.invalidTaskName(name)
                }
                let directory = root.appendingPathComponent(
                    name,
                    isDirectory: true
                )
                try verifyDirectory(directory)
                return identifier
            }
            .sorted { $0.uuidString < $1.uuidString }
    }

    @discardableResult
    public func append(
        taskID: UUID,
        payload: Data,
        occurredAt: Date = Date()
    ) throws -> RelayJournalEntry {
        guard payload.count <= Self.maximumPayloadBytes else {
            throw RelayEventJournalError.recordTooLarge
        }
        try prepare()
        let taskDirectory = root.appendingPathComponent(
            taskID.uuidString.lowercased(),
            isDirectory: true
        )
        try ensureManagedDirectory(taskDirectory, mode: 0o700)
        let accepted = try load(taskID: taskID)
        guard let sequence = UInt64(exactly: accepted.count) else {
            throw RelayEventJournalError.sequenceOverflow
        }
        let previousDigest = accepted.last?.digest
        let digest = try Self.digest(
            schemaVersion: 1,
            taskID: taskID,
            sequence: sequence,
            occurredAt: occurredAt,
            previousDigest: previousDigest,
            payload: payload,
            encoder: encoder
        )
        let entry = RelayJournalEntry(
            taskID: taskID,
            sequence: sequence,
            occurredAt: occurredAt,
            previousDigest: previousDigest,
            payload: payload,
            digest: digest
        )
        let destination = taskDirectory.appendingPathComponent(
            Self.recordName(sequence),
            isDirectory: false
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RelayEventJournalError.duplicateRecord(sequence)
        }
        let bytes = try encoder.encode(entry)
        try durableExclusiveWrite(
            bytes,
            destination: destination,
            parent: taskDirectory
        )
        return entry
    }

    public func load(taskID: UUID) throws -> [RelayJournalEntry] {
        let taskDirectory = root.appendingPathComponent(
            taskID.uuidString.lowercased(),
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: taskDirectory.path) else {
            return []
        }
        try verifyDirectory(taskDirectory)
        let names = try fileManager.contentsOfDirectory(atPath: taskDirectory.path)
        let recordNames = try names.map { name -> (UInt64, String) in
            guard let sequence = Self.sequence(from: name) else {
                throw RelayEventJournalError.invalidRecordName(name)
            }
            return (sequence, name)
        }.sorted { $0.0 < $1.0 }

        var entries: [RelayJournalEntry] = []
        var previousDigest: String?
        for (offset, record) in recordNames.enumerated() {
            let expected = UInt64(offset)
            guard record.0 == expected else {
                throw RelayEventJournalError.brokenSequence(
                    expected: expected,
                    actual: record.0
                )
            }
            let url = taskDirectory.appendingPathComponent(record.1)
            var fileStatus = stat()
            guard lstat(url.path, &fileStatus) == 0,
                  fileStatus.st_mode & S_IFMT == S_IFREG,
                  fileStatus.st_uid == geteuid(),
                  fileStatus.st_mode & 0o7777 == 0o600,
                  fileStatus.st_nlink == 1
            else {
                throw RelayEventJournalError.corruptRecord(expected)
            }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber,
               size.intValue > Self.maximumPayloadBytes + 16_384
            {
                throw RelayEventJournalError.recordTooLarge
            }
            let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let entry = try? decoder.decode(RelayJournalEntry.self, from: bytes) else {
                throw RelayEventJournalError.corruptRecord(expected)
            }
            guard entry.taskID == taskID else {
                throw RelayEventJournalError.wrongTask(expected)
            }
            guard entry.sequence == expected else {
                throw RelayEventJournalError.brokenSequence(
                    expected: expected,
                    actual: entry.sequence
                )
            }
            guard entry.previousDigest == previousDigest else {
                throw RelayEventJournalError.brokenChain(expected)
            }
            let expectedDigest = try Self.digest(
                schemaVersion: entry.schemaVersion,
                taskID: entry.taskID,
                sequence: entry.sequence,
                occurredAt: entry.occurredAt,
                previousDigest: entry.previousDigest,
                payload: entry.payload,
                encoder: encoder
            )
            guard entry.digest == expectedDigest else {
                throw RelayEventJournalError.brokenChain(expected)
            }
            entries.append(entry)
            previousDigest = entry.digest
        }
        return entries
    }

    private func ensureManagedDirectory(_ url: URL, mode: Int16) throws {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard url.standardizedFileURL.path.hasPrefix(parent.path + "/") else {
            throw RelayEventJournalError.unsafeRoot
        }
        if !fileManager.fileExists(atPath: url.path) {
            try createManagedDirectoryChain(url, mode: mode)
        }
        try verifyDirectory(url)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )
    }

    private func createManagedDirectoryChain(_ url: URL, mode: Int16) throws {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.path != url.standardizedFileURL.path else {
            throw RelayEventJournalError.unsafeRoot
        }
        if !fileManager.fileExists(atPath: parent.path) {
            try createManagedDirectoryChain(parent, mode: mode)
        } else {
            try verifyDirectory(parent)
        }
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: mode)]
        )
        try verifyDirectory(url)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )
        try synchronizeDirectory(parent)
    }

    private func verifyDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RelayEventJournalError.unsafeTaskDirectory
        }
    }

    private func durableExclusiveWrite(
        _ bytes: Data,
        destination: URL,
        parent: URL
    ) throws {
        let temporary = parent.appendingPathComponent(
            ".relay-record-\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw RelayEventJournalError.durableWriteFailed(errno)
        }
        var descriptorIsOpen = true
        var shouldRemoveTemporary = true
        defer {
            if descriptorIsOpen { _ = close(descriptor) }
            if shouldRemoveTemporary { _ = unlink(temporary.path) }
        }
        do {
            try bytes.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if count > 0 {
                        offset += count
                    } else if count == -1, errno == EINTR {
                        continue
                    } else {
                        throw RelayEventJournalError.durableWriteFailed(errno)
                    }
                }
            }
            guard fchmod(descriptor, 0o600) == 0 else {
                throw RelayEventJournalError.durableWriteFailed(errno)
            }
            if fcntl(descriptor, F_FULLFSYNC) != 0 {
                let fullSyncError = errno
                guard [EINVAL, ENOTSUP].contains(fullSyncError),
                      fsync(descriptor) == 0
                else {
                    throw RelayEventJournalError.durableWriteFailed(
                        fullSyncError
                    )
                }
            }
            descriptorIsOpen = false
            guard close(descriptor) == 0 else {
                throw RelayEventJournalError.durableWriteFailed(errno)
            }
            guard renamex_np(
                temporary.path,
                destination.path,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw RelayEventJournalError.durableWriteFailed(errno)
            }
            shouldRemoveTemporary = false

            try synchronizeDirectory(parent)
        } catch {
            throw error
        }
    }

    private func synchronizeDirectory(_ directoryURL: URL) throws {
        let directory = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw RelayEventJournalError.durableWriteFailed(errno)
        }
        defer { _ = close(directory) }
        guard fsync(directory) == 0 else {
            throw RelayEventJournalError.durableWriteFailed(errno)
        }
    }

    private static func recordName(_ sequence: UInt64) -> String {
        String(format: "event-%020llu.json", sequence)
    }

    private static func sequence(from name: String) -> UInt64? {
        guard name.hasPrefix("event-"), name.hasSuffix(".json") else {
            return nil
        }
        let start = name.index(name.startIndex, offsetBy: 6)
        let end = name.index(name.endIndex, offsetBy: -5)
        let digits = name[start..<end]
        guard digits.count == 20, digits.allSatisfy(\.isNumber) else {
            return nil
        }
        return UInt64(digits)
    }

    private struct DigestInput: Codable {
        let schemaVersion: UInt16
        let taskID: UUID
        let sequence: UInt64
        let occurredAt: Date
        let previousDigest: String?
        let payload: Data
    }

    private static func digest(
        schemaVersion: UInt16,
        taskID: UUID,
        sequence: UInt64,
        occurredAt: Date,
        previousDigest: String?,
        payload: Data,
        encoder: JSONEncoder
    ) throws -> String {
        let bytes = try encoder.encode(
            DigestInput(
                schemaVersion: schemaVersion,
                taskID: taskID,
                sequence: sequence,
                occurredAt: occurredAt,
                previousDigest: previousDigest,
                payload: payload
            )
        )
        return SHA256.hash(data: bytes).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
