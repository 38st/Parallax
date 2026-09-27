import Foundation
import Darwin

typealias LibraryMutationSession = LibraryMutationCommitCapability

enum LibraryExclusiveAccessResult<Value> {
    case acquired(Value)
    case busy
}

protocol LibraryRepositoryPersisting: Sendable {
    var persistence: any LibraryRepositoryPersistence { get }

    /// Tries the library's interprocess lock once, without waiting. The body
    /// may inspect/recover missing, legacy, or current libraries. It must not
    /// acquire this lock again (including via save or withExclusiveMutation).
    /// Errors from the body propagate unchanged; busy never runs the body.
    func tryWithExclusiveAccess<T>(
        _ body: (LibraryExclusiveAccess) throws -> T
    ) throws -> LibraryExclusiveAccessResult<T>

    func load() -> LibraryRepositoryLoadOutcome

    func prepare(
        _ applications: [ManagedApplication],
        expectedVersion: LibraryVersionToken
    ) throws -> PreparedLibraryCommit

    func withExclusiveMutation<T>(
        expectedVersion: LibraryVersionToken,
        _ body: (LibraryMutationCommitCapability) throws -> T
    ) throws -> T

    @discardableResult
    func save(
        _ applications: [ManagedApplication],
        expectedVersion: LibraryVersionToken,
        backupReason: LibraryBackupReason?
    ) throws -> LibraryRepositorySnapshot
}

extension LibraryRepositoryPersisting {
    func tryWithExclusiveAccess<T>(
        _ body: () throws -> T
    ) throws -> LibraryExclusiveAccessResult<T> {
        try tryWithExclusiveAccess { _ in try body() }
    }

    @discardableResult
    func save(
        _ applications: [ManagedApplication],
        expectedVersion: LibraryVersionToken
    ) throws -> LibraryRepositorySnapshot {
        try save(
            applications,
            expectedVersion: expectedVersion,
            backupReason: nil
        )
    }
}

