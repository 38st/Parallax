import Darwin
import Foundation

struct SettingsPrimaryLockedInspectionAuthority: Sendable {
    let lease: SettingsPrimaryLockedInspectionLease

    func readPrimary() -> Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    > {
        lease.readPrimary()
    }
}

/// The escape is structural: `ownerThread` is a `pthread_t`. Safety does not
/// rest on it. `lock` guards `active` and `inFlight` on every read and write,
/// and the gate in `readPrimary` fails closed — a caller on any thread other
/// than the one that constructed the lease, a reentrant caller, or a caller
/// arriving after `invalidate()` is refused with `.expiredAuthority` instead of
/// reaching the operation.
final class SettingsPrimaryLockedInspectionLease:
    @unchecked Sendable
{
    typealias Operation = @Sendable () -> Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    >

    private let lock = NSLock()
    private var active = true
    private var inFlight = false
    private let operation: Operation
    private let ownerThread: pthread_t

    init(operation: @escaping Operation) {
        self.operation = operation
        ownerThread = pthread_self()
    }

    func readPrimary() -> Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    > {
        lock.lock()
        guard active,
              pthread_equal(pthread_self(), ownerThread) != 0
        else {
            lock.unlock()
            return .failure(.expiredAuthority)
        }
        guard !inFlight else {
            lock.unlock()
            return .failure(.reentrantAuthorityOperation)
        }
        inFlight = true
        lock.unlock()

        let result = operation()
        lock.withLock {
            inFlight = false
        }
        return result
    }

    func invalidate() {
        lock.withLock {
            active = false
        }
    }
}

struct SettingsPrimaryMutationAuthority: Sendable {
    let lease: SettingsPrimaryMutationAuthorityLease

    func readPrimary() -> Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    > {
        lease.readPrimary()
    }

    func publishPrepared(
        _ request: SettingsPrimaryPreparedPublication
    ) -> SettingsPrimaryPublicationResult {
        lease.publishPrepared(request)
    }

    func inspectPublicationResiduals() -> Result<
        SettingsPublicationResidualInventorySnapshot,
        SettingsPrimaryLockedInspectionError
    > {
        lease.inspectPublicationResiduals()
    }

    func preservePublicationResiduals() throws -> SettingsPublicationResidualInventorySnapshot {
        try lease.preservePublicationResiduals()
    }

    func adoptTrustedContainer() throws -> TrustedParallaxContainer {
        try lease.adoptTrustedContainer()
    }
}

/// Same invariant as `SettingsPrimaryLockedInspectionLease`, applied uniformly
/// to all operations: the escape exists only for the `pthread_t`, and
/// every operation is `guard begin() … finish()`, so a wrong-thread, reentrant
/// or post-`invalidate()` caller is refused under the lock rather than served.
final class SettingsPrimaryMutationAuthorityLease:
    @unchecked Sendable
{
    typealias ReadOperation = @Sendable () -> Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    >
    typealias PublishOperation = @Sendable (
        SettingsPrimaryPreparedPublication
    ) -> SettingsPrimaryPublicationResult
    typealias ResidualInventoryOperation = @Sendable () -> Result<
        SettingsPublicationResidualInventorySnapshot,
        SettingsPrimaryLockedInspectionError
    >
    typealias AdoptTrustedContainerOperation = @Sendable () throws
        -> TrustedParallaxContainer

    private let lock = NSLock()
    private var active = true
    private var inFlight = false
    private let ownerThread = pthread_self()
    private let readOperation: ReadOperation
    private let publishOperation: PublishOperation
    private let residualInventoryOperation: ResidualInventoryOperation
    private let preserveResidualsOperation: @Sendable () throws -> SettingsPublicationResidualInventorySnapshot
    private let adoptTrustedContainerOperation: AdoptTrustedContainerOperation

    init(
        readOperation: @escaping ReadOperation,
        publishOperation: @escaping PublishOperation,
        residualInventoryOperation:
            @escaping ResidualInventoryOperation,
        adoptTrustedContainerOperation:
            @escaping AdoptTrustedContainerOperation,
        preserveResidualsOperation: @escaping @Sendable () throws -> SettingsPublicationResidualInventorySnapshot = {
            throw SettingsPrimaryLockedInspectionError.expiredAuthority
        }
    ) {
        self.preserveResidualsOperation = preserveResidualsOperation
        self.readOperation = readOperation
        self.publishOperation = publishOperation
        self.residualInventoryOperation = residualInventoryOperation
        self.adoptTrustedContainerOperation = adoptTrustedContainerOperation
    }

    func preservePublicationResiduals() throws -> SettingsPublicationResidualInventorySnapshot {
        guard begin() else { throw authorityError() }
        defer { finish() }
        return try preserveResidualsOperation()
    }

    func adoptTrustedContainer() throws -> TrustedParallaxContainer {
        guard begin() else {
            throw SettingsPrimaryLockedInspectionError.expiredAuthority
        }
        do {
            let capability = try adoptTrustedContainerOperation()
            finish()
            return capability
        } catch {
            finish()
            throw error
        }
    }

    func readPrimary() -> Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    > {
        guard begin() else {
            return .failure(authorityError())
        }
        let result = readOperation()
        finish()
        return result
    }

    func inspectPublicationResiduals() -> Result<
        SettingsPublicationResidualInventorySnapshot,
        SettingsPrimaryLockedInspectionError
    > {
        guard begin() else {
            return .failure(authorityError())
        }
        let result = residualInventoryOperation()
        finish()
        return result
    }

    func publishPrepared(
        _ request: SettingsPrimaryPreparedPublication
    ) -> SettingsPrimaryPublicationResult {
        guard begin() else {
            return .failed(
                .init(
                    classification: .indeterminate,
                    targetProofEligible: false,
                    failure: .lockedRead(authorityError()),
                    classificationReadFailure: nil,
                    closeFailures: [],
                    residual: nil
                )
            )
        }
        let result = publishOperation(request)
        finish()
        return result
    }

    func invalidate() {
        lock.withLock {
            active = false
        }
    }

    private func begin() -> Bool {
        lock.withLock {
            guard active,
                  pthread_equal(pthread_self(), ownerThread) != 0,
                  !inFlight
            else {
                return false
            }
            inFlight = true
            return true
        }
    }

    private func finish() {
        lock.withLock {
            inFlight = false
        }
    }

    private func authorityError() -> SettingsPrimaryLockedInspectionError {
        lock.withLock {
            if active,
               pthread_equal(pthread_self(), ownerThread) != 0,
               inFlight
            {
                return .reentrantAuthorityOperation
            }
            return .expiredAuthority
        }
    }
}
