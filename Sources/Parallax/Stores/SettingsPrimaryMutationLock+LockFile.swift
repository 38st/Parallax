import Darwin
import Foundation

extension SettingsPrimaryMutationLock {
    func openOrCreateLock(
        _ resources: Resources
    ) throws {
        let preflight = pathMetadata(
            parent: resources.settings,
            name: Self.lockName,
            call: .inspectLockPath
        )
        var existing: SettingsPrimaryFileMetadata?
        switch preflight {
        case .metadata(let metadata):
            try validateLock(metadata)
            existing = metadata
        case .failure(let code):
            guard code == ENOENT else {
                throw system("inspect settings lock path", code)
            }
        }
        boundaryHook(.afterLockPreflight)

        var lock: Int32
        if existing == nil {
            let created = createLock(parent: resources.settings)
            if created.descriptor >= 0 {
                lock = created.descriptor
                resources.lockCreated = true
            } else if created.errorCode == EEXIST {
                let raced = try requiredPathMetadata(
                    parent: resources.settings,
                    name: Self.lockName,
                    call: .inspectLockPath,
                    operation: "reinspect existing settings lock"
                )
                try validateLock(raced)
                existing = raced
                lock = try reopenLock(parent: resources.settings)
            } else {
                throw system("create settings lock", created.errorCode)
            }
        } else {
            lock = try reopenLock(parent: resources.settings)
        }
        resources.lock = lock

        let opened = try descriptorMetadata(
            lock,
            call: .inspectLock,
            operation: "inspect opened settings lock"
        )
        if resources.lockCreated {
            resources.lockIdentity = opened
            try callStatus(
                .setLockMode,
                operation: "set created settings lock mode"
            ) {
                fchmod(lock, 0o600)
            }
        } else {
            try validateLock(opened)
            guard opened.hasSameLockFacts(as: existing) else {
                throw changed(.lock)
            }
        }

        let final = try descriptorMetadata(
            lock,
            call: .reinspectLock,
            operation: "reinspect settings lock"
        )
        try validateLock(final)
        try validateACL(
            lock,
            item: .lock,
            operation: "inspect settings lock ACL"
        )
        let path = try requiredPathMetadata(
            parent: resources.settings,
            name: Self.lockName,
            call: .reinspectLockPath,
            operation: "reinspect settings lock path"
        )
        guard final.hasSameLockFacts(as: path) else {
            throw changed(.lock)
        }
        resources.lockIdentity = final
        boundaryHook(.afterLockOpen)

        if resources.lockCreated {
            try fullSync(
                resources.settings,
                call: .syncSettings,
                operation: "synchronize Settings directory"
            )
        }
    }

    func acquireFlock(
        _ descriptor: Int32
    ) throws {
        let started = monotonicNow()
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
        var consecutiveNoProgress = 0
        while true {
            let status: Int32
            let code: Int32
            if let injected = systemCallHook(.flock) {
                status = -1
                code = injected
            } else {
                status = flock(descriptor, LOCK_EX | LOCK_NB)
                code = status == 0 ? 0 : errno
            }
            if status == 0 {
                return
            }
            guard code == EINTR
                    || code == EWOULDBLOCK
                    || code == EAGAIN
            else {
                throw system("acquire settings lock", code)
            }
            let (next, overflow) =
                consecutiveNoProgress.addingReportingOverflow(1)
            guard !overflow,
                  next <= maximumConsecutiveFlockNoProgress
            else {
                throw SettingsPrimaryMutationLockError.timedOut(
                    timeout: timeout
                )
            }
            consecutiveNoProgress = next
            let now = monotonicNow()
            let elapsed = now >= started ? now - started : UInt64.max
            guard elapsed < timeoutNanoseconds else {
                throw SettingsPrimaryMutationLockError.timedOut(
                    timeout: timeout
                )
            }
            sleeper(
                min(
                    pollIntervalNanoseconds,
                    timeoutNanoseconds - elapsed
                )
            )
        }
    }

    func createLock(
        parent: Int32
    ) -> (descriptor: Int32, errorCode: Int32) {
        if let code = systemCallHook(.createLock) {
            return (-1, code)
        }
        let descriptor = openat(
            parent,
            Self.lockName,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        return (descriptor, descriptor < 0 ? errno : 0)
    }

    private func reopenLock(
        parent: Int32
    ) throws -> Int32 {
        if let code = systemCallHook(.reopenLock) {
            if code == ELOOP {
                throw unsafe(.lock, .symbolicLink)
            }
            throw system("open existing settings lock", code)
        }
        let descriptor = openat(
            parent,
            Self.lockName,
            O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                | Self.uniqueOpenFlag
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw unsafe(.lock, .symbolicLink)
            }
            throw system("open existing settings lock", errno)
        }
        return descriptor
    }

    /// Newer Darwin kernels can reject multiply-linked files atomically while
    /// opening them. Xcode 16's macOS 14 SDK does not expose that flag, so the
    /// supported fallback relies on the surrounding pre-open, descriptor, and
    /// path metadata checks, each of which requires an exact link count of one.
    private static var uniqueOpenFlag: Int32 {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return O_UNIQUE
        }
#endif
        return 0
    }
}
