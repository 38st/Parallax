import Darwin
import Foundation

extension SecureManagedFileSystem {
    /// Publish a complete replacement while retaining the previous file at a
    /// private recovery path. Callers hold inactive-profile reservations. An
    /// ambiguous outcome is retained and reported, never destructively undone.
    func replaceHistoryFile(at destination: SecureManagedPath, expected: Data?, with data: Data) throws {
        let maximum = ClaudeConversationCopyService.maximumTranscriptBytes
        if let expected {
            guard try readFile(at: destination, maximumBytes: maximum) == expected else { throw SharedHistoryError.changed }
            if expected == data { return }
        } else {
            guard try itemState(at: destination) == .missing else { throw SharedHistoryError.changed }
        }
        let recovery = try SecureManagedPath([".parallax-history-recovery"])
        if try itemState(at: recovery) == .missing { try createDirectory(at: recovery) }
        let staged = try recovery.appending(UUID().uuidString.lowercased())
        try write(data, to: staged)
        guard let expected else {
            try rename(from: staged, to: destination)
            return
        }
        let (sourceParent, sourceLeaf) = try openParent(of: staged, createMissing: false)
        defer { close(sourceParent) }
        let (parent, leaf) = try openParent(of: destination, createMissing: false)
        defer { close(parent) }
        let old = try preflight(path: destination)
        let new = try preflight(path: staged)
        try performBoundary(.beforeRename)
        try verifyRootIdentity()
        try revalidateParent(of: destination, expectedDescriptor: parent)
        try revalidateParent(of: staged, expectedDescriptor: sourceParent)
        guard try readFile(at: destination, maximumBytes: maximum) == expected,
              Self.isSameObject(old, try preflight(path: destination)),
              Self.isSameObject(new, try preflight(path: staged)) else { throw SharedHistoryError.changed }
        guard renameatx_np(sourceParent, sourceLeaf, parent, leaf, UInt32(RENAME_SWAP)) == 0 else {
            throw Self.systemError("publish history replacement", errno)
        }
        try performBoundary(.afterRename)
        guard Self.isSameObject(old, try preflight(path: staged)),
              Self.isSameObject(new, try preflight(path: destination)),
              try readFile(at: staged, maximumBytes: maximum) == expected,
              try readFile(at: destination, maximumBytes: maximum) == data else { throw SharedHistoryError.changed }
        try synchronize(sourceParent, operation: "fsync history recovery")
        try synchronize(parent, operation: "fsync history publication")
        try verifyRootIdentity()
    }
}
