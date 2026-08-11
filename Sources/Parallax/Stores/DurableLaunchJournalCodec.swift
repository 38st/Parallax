import Foundation

struct DurableLaunchJournalCodec: Sendable {
    private enum MaterializationError: Error {
        case invalid
    }

    struct EncodedFile: Sendable {
        let name: String
        let data: Data
    }

    enum NamedData: Sendable {
        case bytes(Data)
        case unreadable
    }

    struct Snapshot: Sendable {
        let directoryName: String
        let directoryURL: URL
        let presentNames: Set<String>
        let namedData: [String: NamedData]
    }

    private struct RequestRecord: Codable {
        let schemaVersion: Int
        let requestID: UUID
        let identity: ProfileActivityIdentityRecord
        let ownerProcess: ProcessStartIdentity
    }

    private struct ProfileActivityIdentityRecord: Codable {
        let applicationID: UUID
        let applicationStorageID: UUID
        let profileID: UUID
        let profileStorageID: UUID

        init(_ identity: ProfileActivityIdentity) {
            applicationID = identity.applicationID
            applicationStorageID = identity.applicationStorageID
            profileID = identity.profileID
            profileStorageID = identity.profileStorageID
        }

        var value: ProfileActivityIdentity {
            ProfileActivityIdentity(
                applicationID: applicationID,
                applicationStorageID: applicationStorageID,
                profileID: profileID,
                profileStorageID: profileStorageID
            )
        }
    }

    private struct MarkerRecord: Codable {
        let schemaVersion: Int
        let requestID: UUID
    }

    private struct ProcessRecord: Codable {
        let schemaVersion: Int
        let requestID: UUID
        let process: ProcessStartIdentity
    }

    private struct CompletionRecord: Codable {
        let schemaVersion: Int
        let requestID: UUID
        let completion: DurableLaunchCompletion
    }

    private static let schemaVersion = 1
    private static let requestFile = "request.json"
    private static let openingFile = "opening.json"
    private static let processFile = "process.json"
    private static let completionFile = "completion.json"
    private static let allowedFiles: Set<String> = [
        requestFile,
        openingFile,
        processFile,
        completionFile,
    ]

    var completionFileName: String {
        Self.completionFile
    }

    func encodeRequest(
        requestID: UUID,
        identity: ProfileActivityIdentity,
        ownerProcess: ProcessStartIdentity
    ) throws -> EncodedFile {
        EncodedFile(
            name: Self.requestFile,
            data: try encode(
                RequestRecord(
                    schemaVersion: Self.schemaVersion,
                    requestID: requestID,
                    identity: ProfileActivityIdentityRecord(identity),
                    ownerProcess: ownerProcess
                )
            )
        )
    }

    func encodeOpening(requestID: UUID) throws -> EncodedFile {
        EncodedFile(
            name: Self.openingFile,
            data: try encode(
                MarkerRecord(
                    schemaVersion: Self.schemaVersion,
                    requestID: requestID
                )
            )
        )
    }

    func encodeProcess(
        requestID: UUID,
        process: ProcessStartIdentity
    ) throws -> EncodedFile {
        EncodedFile(
            name: Self.processFile,
            data: try encode(
                ProcessRecord(
                    schemaVersion: Self.schemaVersion,
                    requestID: requestID,
                    process: process
                )
            )
        )
    }

    func encodeCompletion(
        requestID: UUID,
        completion: DurableLaunchCompletion
    ) throws -> EncodedFile {
        EncodedFile(
            name: Self.completionFile,
            data: try encode(
                CompletionRecord(
                    schemaVersion: Self.schemaVersion,
                    requestID: requestID,
                    completion: completion
                )
            )
        )
    }

    func requiredFileNames(in presentNames: Set<String>) -> [String] {
        guard presentNames.isSubset(of: Self.allowedFiles) else {
            return []
        }
        var names = [Self.requestFile]
        if presentNames.contains(Self.completionFile) {
            names.append(Self.completionFile)
        } else if presentNames.contains(Self.processFile) {
            names.append(Self.processFile)
        } else if presentNames.contains(Self.openingFile) {
            names.append(Self.openingFile)
        }
        return names
    }

    func materialize(_ snapshot: Snapshot) -> DurableLaunchArtifact {
        var requestID: UUID?
        var identity: ProfileActivityIdentity?
        do {
            guard snapshot.presentNames.isSubset(of: Self.allowedFiles) else {
                throw MaterializationError.invalid
            }
            let request = try decode(
                RequestRecord.self,
                named: Self.requestFile,
                from: snapshot
            )
            guard
                request.schemaVersion == Self.schemaVersion,
                snapshot.directoryName
                    == request.requestID.uuidString.lowercased()
            else {
                throw MaterializationError.invalid
            }
            requestID = request.requestID
            identity = request.identity.value

            if snapshot.presentNames.contains(Self.completionFile) {
                let record = try decode(
                    CompletionRecord.self,
                    named: Self.completionFile,
                    from: snapshot
                )
                guard
                    record.schemaVersion == Self.schemaVersion,
                    record.requestID == request.requestID
                else {
                    throw MaterializationError.invalid
                }
                return artifact(
                    requestID: requestID,
                    identity: identity,
                    state: .completed,
                    snapshot: snapshot
                )
            }

            if snapshot.presentNames.contains(Self.processFile) {
                let record = try decode(
                    ProcessRecord.self,
                    named: Self.processFile,
                    from: snapshot
                )
                guard
                    record.schemaVersion == Self.schemaVersion,
                    record.requestID == request.requestID,
                    record.process.processIdentifier > 0
                else {
                    throw MaterializationError.invalid
                }
                return artifact(
                    requestID: requestID,
                    identity: identity,
                    state: .running(record.process),
                    snapshot: snapshot
                )
            }

            if snapshot.presentNames.contains(Self.openingFile) {
                let marker = try decode(
                    MarkerRecord.self,
                    named: Self.openingFile,
                    from: snapshot
                )
                guard
                    marker.schemaVersion == Self.schemaVersion,
                    marker.requestID == request.requestID
                else {
                    throw MaterializationError.invalid
                }
                return artifact(
                    requestID: requestID,
                    identity: identity,
                    state: .opening,
                    snapshot: snapshot
                )
            }

            return artifact(
                requestID: requestID,
                identity: identity,
                state: .requestOnly(owner: request.ownerProcess),
                snapshot: snapshot
            )
        } catch {
            return artifact(
                requestID: requestID,
                identity: identity,
                state: .corrupt,
                snapshot: snapshot
            )
        }
    }

    private func decode<Record: Decodable>(
        _ type: Record.Type,
        named name: String,
        from snapshot: Snapshot
    ) throws -> Record {
        guard case .bytes(let data) = snapshot.namedData[name] else {
            throw MaterializationError.invalid
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func encode<Record: Encodable>(_ record: Record) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    private func artifact(
        requestID: UUID?,
        identity: ProfileActivityIdentity?,
        state: DurableLaunchArtifact.State,
        snapshot: Snapshot
    ) -> DurableLaunchArtifact {
        DurableLaunchArtifact(
            requestID: requestID,
            identity: identity,
            state: state,
            directoryURL: snapshot.directoryURL
        )
    }
}
