import Darwin
import Foundation

struct SettingsRuntimeBootstrapper: Sendable {
    let applicationSupportURL: URL
    let legacyApplicationIdentifier: String
    private let legacyCaptureOverride:
        (@Sendable () -> SettingsLegacySnapshot)?
    private let containerACLHook: @Sendable (Int32) -> SettingsPrimaryACLDirective
    private let beforeMigrationCommit: @Sendable () -> Void

    init(
        applicationSupportURL: URL,
        legacyApplicationIdentifier: String,
        legacyCaptureOverride:
            (@Sendable () -> SettingsLegacySnapshot)? = nil,
        beforeMigrationCommit: @escaping @Sendable () -> Void = {},
        containerACLHook: @escaping @Sendable (Int32) -> SettingsPrimaryACLDirective = { _ in .system }
    ) {
        self.applicationSupportURL = applicationSupportURL
        self.legacyApplicationIdentifier = legacyApplicationIdentifier
        self.legacyCaptureOverride = legacyCaptureOverride
        self.beforeMigrationCommit = beforeMigrationCommit
        self.containerACLHook = containerACLHook
    }

    func bootstrap() -> SettingsRuntimeBootstrapResult {
        bootstrapOutcome().result
    }

    func bootstrapOutcome() -> SettingsRuntimeBootstrapOutcome {
        var trustedContainer: TrustedParallaxContainer?
        let result = bootstrap(adoptedContainer: &trustedContainer)
        guard let trustedContainer else {
            return SettingsRuntimeBootstrapOutcome(
                result: result,
                trustedContainer: nil
            )
        }
        do {
            try trustedContainer.validate()
            return SettingsRuntimeBootstrapOutcome(
                result: result,
                trustedContainer: trustedContainer
            )
        } catch let error as TrustedParallaxContainerError {
            return SettingsRuntimeBootstrapOutcome(
                result: .recoveryRequired(
                    .container(.trustedContainer(error))
                ),
                trustedContainer: nil
            )
        } catch {
            return SettingsRuntimeBootstrapOutcome(
                result: .recoveryRequired(
                    .container(
                        .systemCall(
                            operation: "validate trusted Parallax container",
                            code: EIO
                        )
                    )
                ),
                trustedContainer: nil
            )
        }
    }

    private func bootstrap(
        adoptedContainer: inout TrustedParallaxContainer?
    ) -> SettingsRuntimeBootstrapResult {
        let trustedContainerURL = applicationSupportURL.appendingPathComponent(
            "Parallax",
            isDirectory: true
        )
        do {
            try establishTrustedContainer(at: trustedContainerURL)
        } catch let error as SettingsRuntimeContainerFailure {
            return .recoveryRequired(.container(error))
        } catch {
            return .recoveryRequired(
                .container(
                    .systemCall(
                        operation: "establish settings container",
                        code: errno
                    )
                )
            )
        }

        let mutationLock = SettingsPrimaryMutationLock(
            trustedContainerURL: trustedContainerURL
        )
        let lockedInspector = SettingsLockedPrimaryInspector()
        let initialInspection: SettingsRepositoryInspection
        do {
            initialInspection = try mutationLock.withMutationLock {
                authority in
                adoptedContainer = try authority.adoptTrustedContainer()
                return lockedInspector.inspect(authority.readPrimary())
            }
        } catch {
            adoptedContainer = nil
            return .recoveryRequired(
                .container(
                    .mutationLock(settingsMutationLockFailure(error))
                )
            )
        }
        let legacyReader = SettingsLegacySnapshotReader(
            applicationIdentifier: legacyApplicationIdentifier
        )
        let capture: @Sendable () -> SettingsLegacySnapshot =
            legacyCaptureOverride ?? { legacyReader.capture() }
        let current = SettingsCurrentMigrationAssessor(
            source: initialInspection
        ).assess()
        let legacy = SettingsLegacyMigrationAssessor(
            source: SettingsLegacySnapshotDecoder(
                source: capture()
            ).decode()
        ).assess()
        let plan = SettingsMigrationPlanner(
            current: current,
            legacy: legacy
        ).plan()
        beforeMigrationCommit()
        if case .useCurrent(let ready) = plan {
            return adoptCurrent(
                ready,
                plan: plan,
                mutationLock: mutationLock,
                inspector: lockedInspector
            )
        }
        let result = SettingsMigrationCommitter(
            mutationLock: mutationLock,
            legacyCapture: capture
        ).commit(plan)

        let snapshot: SettingsRepositorySnapshot
        let ready: SettingsMigrationReadyPlan
        switch result {
        case .notRequired:
            return .recoveryRequired(
                .migration(
                    inconsistentCommitEvidence(
                        plan: plan,
                        failure: .inconsistentPlan
                    )
                )
            )
        case .committed(let receipt):
            ready = SettingsMigrationReadyPlan(
                state: plan.readyState ?? .defaults,
                evidence: receipt.migrationEvidence
            )
            snapshot = receipt.snapshot
        case .recoveryRequired(let evidence):
            return .recoveryRequired(.migration(evidence))
        }

        let writer = SettingsRepositoryWriter(mutationLock: mutationLock)
        return .ready(
            SettingsRuntime(
                initialState: ready.state,
                initialSnapshot: snapshot,
                migrationEvidence: ready.evidence,
                coordinator: SettingsMutationCoordinator(
                    initialState: ready.state,
                    initialSnapshot: snapshot,
                    writer: writer
                )
            )
        )
    }

    private func adoptCurrent(
        _ ready: SettingsMigrationReadyPlan,
        plan: SettingsMigrationPlan,
        mutationLock: SettingsPrimaryMutationLock,
        inspector: SettingsLockedPrimaryInspector
    ) -> SettingsRuntimeBootstrapResult {
        let expected = ready.evidence.current.source
        var observed: SettingsRepositoryInspection?
        do {
            let adopted: SettingsRepositorySnapshot? =
                try mutationLock.withMutationLock { authority in
                let value = inspector.inspect(authority.readPrimary())
                observed = value
                guard value == expected,
                      case .current(let snapshot) = value
                else { return nil }
                return snapshot
            }
            guard let snapshot = adopted else {
                return .recoveryRequired(
                    .migration(
                        migrationEvidence(
                            plan: plan,
                            failure: .currentPrimaryChanged(
                                observed ?? .unavailable(
                                    .primaryFile(
                                        .systemCall(
                                            operation:
                                                "adopt current settings",
                                            code: EIO
                                        )
                                    )
                                )
                            ),
                            lockedPrimary: observed
                        )
                    )
                )
            }
            let writer = SettingsRepositoryWriter(
                mutationLock: mutationLock
            )
            return .ready(
                SettingsRuntime(
                    initialState: ready.state,
                    initialSnapshot: snapshot,
                    migrationEvidence: ready.evidence,
                    coordinator: SettingsMutationCoordinator(
                        initialState: ready.state,
                        initialSnapshot: snapshot,
                            writer: writer
                    )
                )
            )
        } catch {
            return .recoveryRequired(
                .migration(
                    migrationEvidence(
                        plan: plan,
                        failure: .lock(
                            settingsMutationLockFailure(error)
                        ),
                        lockedPrimary: observed
                    )
                )
            )
        }
    }

    private func establishTrustedContainer(at url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw SettingsRuntimeContainerFailure.invalidURL(url.path)
        }
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw SettingsRuntimeContainerFailure.systemCall(
                    operation: "inspect settings container",
                    code: errno
                )
            }
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else {
                throw SettingsRuntimeContainerFailure.systemCall(
                    operation: "create settings container",
                    code: errno
                )
            }
            guard lstat(url.path, &metadata) == 0 else {
                throw SettingsRuntimeContainerFailure.systemCall(
                    operation: "reinspect settings container",
                    code: errno
                )
            }
        }

        let type = metadata.st_mode & S_IFMT
        guard type == S_IFDIR,
              metadata.st_uid == geteuid()
        else {
            throw SettingsRuntimeContainerFailure.unsafeExistingItem(
                path: url.path
            )
        }
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else {
            throw SettingsRuntimeContainerFailure.systemCall(
                operation: "canonicalize settings container parent", code: errno
            )
        }
        defer { free(parent) }
        let canonical = URL(fileURLWithPath: String(cString: parent))
            .appendingPathComponent(url.lastPathComponent, isDirectory: true)
        let descriptor = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SettingsRuntimeContainerFailure.systemCall(
                operation: "open settings container", code: errno
            )
        }
        defer { close(descriptor) }
        var pinned = stat()
        guard fstat(descriptor, &pinned) == 0 else {
            throw SettingsRuntimeContainerFailure.systemCall(
                operation: "inspect pinned settings container", code: errno
            )
        }
        guard pinned.st_dev == metadata.st_dev, pinned.st_ino == metadata.st_ino,
              pinned.st_uid == geteuid(), pinned.st_mode & S_IFMT == S_IFDIR
        else {
            throw SettingsRuntimeContainerFailure.unsafeExistingItem(path: url.path)
        }
        switch SettingsPrimaryDescriptorSecurity.extendedACL(
            descriptor: descriptor, directive: containerACLHook(descriptor)
        ) {
        case .absent:
            break
        case .present:
            throw SettingsRuntimeContainerFailure.unsafeExistingItem(path: url.path)
        case .failure(let code):
            throw SettingsRuntimeContainerFailure.systemCall(
                operation: "inspect settings container ACL", code: code
            )
        }
        if pinned.st_mode & 0o7777 != 0o700 {
            var interruptions = 0
            while fchmod(descriptor, 0o700) != 0 {
                let code = errno
                guard code == EINTR, interruptions < 64 else {
                    throw SettingsRuntimeContainerFailure.systemCall(
                        operation: "secure settings container", code: code
                    )
                }
                interruptions += 1
            }
        }
        var final = stat()
        guard lstat(canonical.path, &final) == 0,
              final.st_dev == pinned.st_dev, final.st_ino == pinned.st_ino,
              final.st_uid == geteuid(), final.st_mode & 0o7777 == 0o700,
              final.st_mode & S_IFMT == S_IFDIR
        else {
            throw SettingsRuntimeContainerFailure.unsafeExistingItem(path: url.path)
        }
    }

    private func inconsistentCommitEvidence(
        plan: SettingsMigrationPlan,
        failure: SettingsMigrationCommitFailure
    ) -> SettingsMigrationCommitEvidence {
        migrationEvidence(plan: plan, failure: failure)
    }

    private func migrationEvidence(
        plan: SettingsMigrationPlan,
        failure: SettingsMigrationCommitFailure,
        lockedPrimary: SettingsRepositoryInspection? = nil
    ) -> SettingsMigrationCommitEvidence {
        SettingsMigrationCommitEvidence(
            classification: .indeterminate,
            failure: failure,
            planned: plan.evidence,
            lockedPrimary: lockedPrimary,
            lockedReadFailure: nil,
            residualInventory: nil,
            recapturedLegacy: nil,
            targetToken: nil,
            publicationResidual: nil
        )
    }
}

private extension SettingsMigrationPlan {
    var readyState: SettingsState? {
        switch self {
        case .useCurrent(let ready),
             .publishLegacy(let ready),
             .publishDefaults(let ready):
            return ready.state
        case .recoveryRequired:
            return nil
        }
    }

    var evidence: SettingsMigrationEvidence {
        switch self {
        case .useCurrent(let ready),
             .publishLegacy(let ready),
             .publishDefaults(let ready):
            return ready.evidence
        case .recoveryRequired(let recovery):
            return recovery.evidence
        }
    }
}
