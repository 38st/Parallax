import Foundation

enum ApplicationRemovalTransactionPhase: String, Codable {
    case prepared
    case metadataCommitted
}

struct ApplicationRemovalTransactionEntry: Codable {
    let profileID: UUID
    let profileStorageID: UUID
    let baseRootPath: String
    let sourcePath: String
    let stagedPath: String
    let archivePath: String
    let expectedDevice: UInt64?
    let expectedInode: UInt64?
    var sourceExisted: Bool
}

struct ApplicationRemovalTransactionManifest: Codable {
    let transactionID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let dataChoice: ApplicationRemovalDataChoice
    let priorRevision: UInt64
    let priorSHA256: String?
    let targetRevision: UInt64
    let targetSHA256: String?
    let stagingRootPath: String
    var phase: ApplicationRemovalTransactionPhase
    var entries: [ApplicationRemovalTransactionEntry]
}

struct ApplicationRemovalTransactionCompletedRecord: Codable {
    let transactionID: UUID
    let completion: ApplicationRemovalTransactionCompletion
    let dataChoice: ApplicationRemovalDataChoice
    let archivePaths: [String: String]
}
