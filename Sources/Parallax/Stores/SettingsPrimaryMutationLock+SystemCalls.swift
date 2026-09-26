import Darwin
import Foundation

extension SettingsPrimaryMutationLock {
    func openContainer(
        call: SettingsPrimaryMutationLockSystemCall
    ) throws -> Int32 {
        if let code = systemCallHook(call) {
            if code == ENOENT {
                throw SettingsPrimaryMutationLockError
                    .missingTrustedContainer
            }
            throw system("open trusted settings container", code)
        }
        let descriptor = open(
            trustedContainerURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw SettingsPrimaryMutationLockError
                    .missingTrustedContainer
            }
            if errno == ELOOP {
                throw unsafe(.trustedContainer, .symbolicLink)
            }
            if errno == ENOTDIR {
                throw unsafe(.trustedContainer, .unsupportedType)
            }
            throw system("open trusted settings container", errno)
        }
        return descriptor
    }

    func descriptorMetadata(
        _ descriptor: Int32,
        call: SettingsPrimaryMutationLockSystemCall,
        operation: String
    ) throws -> SettingsPrimaryFileMetadata {
        if let code = systemCallHook(call) {
            throw system(operation, code)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw system(operation, errno)
        }
        return SettingsPrimaryDescriptorSecurity.metadata(from: status)
    }

    func requiredPathMetadata(
        parent: Int32,
        name: String,
        call: SettingsPrimaryMutationLockSystemCall,
        operation: String
    ) throws -> SettingsPrimaryFileMetadata {
        switch pathMetadata(parent: parent, name: name, call: call) {
        case .metadata(let metadata):
            return metadata
        case .failure(let code):
            throw system(operation, code)
        }
    }

    func validateACL(
        _ descriptor: Int32,
        item: SettingsPrimaryMutationLockItem,
        operation: String
    ) throws {
        let directive = aclHook(item, descriptor)
        let result = SettingsPrimaryDescriptorSecurity.extendedACL(
            descriptor: descriptor,
            directive: directive
        )
        switch result {
        case .absent:
            return
        case .present:
            throw unsafe(item, .extendedACL)
        case .failure(let code):
            throw system(operation, code)
        }
    }

    func callStatus(
        _ call: SettingsPrimaryMutationLockSystemCall,
        operation: String,
        _ body: () -> Int32
    ) throws {
        var consecutiveInterruptions = 0
        while true {
            let result: Int32
            let code: Int32
            if let injected = systemCallHook(call) {
                result = -1
                code = injected
            } else {
                result = body()
                code = result == 0 ? 0 : errno
            }
            if result == 0 {
                return
            }
            guard code == EINTR else {
                throw system(operation, code)
            }
            consecutiveInterruptions += 1
            guard consecutiveInterruptions
                    <= Self.maximumConsecutiveInterruptedStatusCalls
            else {
                throw system(operation, EINTR)
            }
        }
    }

    func fullSync(
        _ descriptor: Int32,
        call: SettingsPrimaryMutationLockSystemCall,
        operation: String
    ) throws {
        try callStatus(call, operation: operation) {
            fcntl(descriptor, F_FULLFSYNC)
        }
    }

    func sameIdentity(
        _ lhs: SettingsPrimaryFileMetadata?,
        _ rhs: SettingsPrimaryFileMetadata?
    ) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.identity == rhs.identity
    }

    func unsafe(
        _ item: SettingsPrimaryMutationLockItem,
        _ reason: SettingsPrimaryMutationLockUnsafeReason
    ) -> SettingsPrimaryMutationLockError {
        .unsafeItem(item: item, reason: reason)
    }

    func changed(
        _ item: SettingsPrimaryMutationLockItem
    ) -> SettingsPrimaryMutationLockError {
        .changedDuringAcquisition(item: item)
    }

    func system(
        _ operation: String,
        _ code: Int32
    ) -> SettingsPrimaryMutationLockError {
        .systemCall(
            SettingsPrimaryMutationLockSystemFailure(
                operation: operation,
                code: code
            )
        )
    }
}

/// Deliberately unguarded: single-owner thread confinement, enforced at
/// runtime by the leases rather than by a lock. One instance lives inside one
/// fully synchronous `withAcquiredResources` call, which has no suspension
/// point, so creation, mutation and cleanup all happen on one thread. The only
/// references that escape are inside the `@Sendable` lease operations — the
/// reason a conformance is required at all — and each of those is gated by the
/// lease's owner-thread, `active` and `!inFlight` check, which fails closed.
/// Do not add a field that outlives that call, and do not hand an instance to
/// anything that can resume on another thread.
final class Resources: @unchecked Sendable {
    var container: Int32 = -1
    var settings: Int32 = -1
    var lock: Int32 = -1
    var reopenedContainer: Int32 = -1
    var containerIdentity: SettingsPrimaryFileMetadata?
    var settingsIdentity: SettingsPrimaryFileMetadata?
    var lockIdentity: SettingsPrimaryFileMetadata?
    var lockCreated = false
    var lockAttempted = false
    var locked = false
}

enum PathMetadataResult {
    case metadata(SettingsPrimaryFileMetadata)
    case failure(Int32)
}
