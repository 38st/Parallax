import Foundation

extension ClaudeConversationCopyService {
    /// The transcript and a private record are durable before one exclusive
    /// rename makes the new conversation visible. Interrupted staging is never
    /// treated as a published chat, overwritten, or deleted speculatively.
    /// A deterministic retry verifies and reuses the exact prepared bytes.
    func copy(
        _ plan: ClaudeConversationCopyPlan,
        destination: ClaudeConversationCopyService,
        beforePublication: () throws -> Void = {}
    ) throws -> ClaudeConversationCopyOutcome {
        guard try prepare(plan.conversation, destination: destination) == plan else {
            throw ClaudeConversationCopyError.changed
        }
        let target = destination.files
        if try target.itemState(at: plan.publishedRecord) != .missing {
            guard try target.readFile(at: plan.publishedRecord, maximumBytes: Self.maximumRecordBytes) == plan.record,
                  try target.readFile(at: plan.stagedTranscript, maximumBytes: Self.maximumTranscriptBytes) == plan.transcript else {
                throw SecureManagedFileSystemError.unexpectedDestination
            }
            return .alreadyCopied
        }
        let staging = try plan.destinationNamespace.appending("imported-staging")
        if try target.itemState(at: staging) == .missing {
            try target.createDirectory(at: staging)
        }
        do {
            try destination.writePrepared(plan.transcript, to: plan.stagedTranscript, maximumBytes: Self.maximumTranscriptBytes)
            try destination.writePrepared(plan.record, to: plan.stagedRecord, maximumBytes: Self.maximumRecordBytes)
            try beforePublication()
            // Re-read after staging, before publishing, including source hashes,
            // destination namespace identity, and account-directory ambiguity.
            guard try prepare(plan.conversation, destination: destination) == plan else {
                throw ClaudeConversationCopyError.changed
            }
            try target.rename(from: plan.stagedRecord, to: plan.publishedRecord)
            return .copied
        } catch let error as ClaudeConversationCopyError {
            throw error
        } catch {
            // rename may have published before a sync failed. Keep both files;
            // retry determines the actual state instead of removing live data.
            throw ClaudeConversationCopyError.interrupted
        }
    }

    private func writePrepared(_ data: Data, to path: SecureManagedPath, maximumBytes: Int) throws {
        if try files.itemState(at: path) == .missing {
            try files.write(data, to: path)
        } else {
            guard try files.readFile(at: path, maximumBytes: maximumBytes) == data else {
                throw SecureManagedFileSystemError.unexpectedDestination
            }
        }
    }
}
