import Darwin
import Foundation

struct SettingsRuntimeBootstrapper: Sendable {
    let applicationSupportURL: URL
    let legacyApplicationIdentifier: String
    private let legacyCaptureOverride:
        (@Sendable () -> SettingsLegacySnapshot)?
    private let beforeMigrationCommit: @Sendable () -> Void

    init(
        applicationSupportURL: URL,
        legacyApplicationIdentifier: String,
        legacyCaptureOverride:
            (@Sendable () -> SettingsLegacySnapshot)? = nil,
        beforeMigrationCommit: @escaping @Sendable () -> Void = {}
    ) {
        self.applicationSupportURL = applicationSupportURL
        self.legacyApplicationIdentifier = legacyApplicationIdentifier
        self.legacyCaptureOverride = legacyCaptureOverride
        self.beforeMigrationCommit = beforeMigrationCommit
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

        let settingsDirectoryURL = trustedContainerURL.appendingPathComponent(
            SettingsPrimaryMutationLock.settingsName,
            isDirectory: true
        )
        let repository = SettingsRepository(
            primaryFileAccess: SettingsPrimaryFileAccess(
                settingsDirectoryURL: settingsDirectoryURL
            )
        )
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
                inspector: lockedInspector,
                repository: repository
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
                    repository: repository,
                    writer: writer
                )
            )
        )
    }

    private func adoptCurrent(
        _ ready: SettingsMigrationReadyPlan,
        plan: SettingsMigrationPlan,
        mutationLock: SettingsPrimaryMutationLock,
        inspector: SettingsLockedPrimaryInspector,
        repository: SettingsRepository
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
                        repository: repository,
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
            guard mkdir(url.path, 0o700) == 0 else {
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
        let mode = metadata.st_mode & 0o7777
        guard type == S_IFDIR,
              metadata.st_uid == geteuid(),
              mode == 0o700
        else {
            throw SettingsRuntimeContainerFailure.unsafeExistingItem(
                path: url.path
            )
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
