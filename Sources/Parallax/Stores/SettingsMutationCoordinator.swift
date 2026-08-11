import Foundation

actor SettingsMutationCoordinator {
    typealias Inspect = @Sendable () -> SettingsRepositoryInspection
    typealias Commit = @Sendable (
        SettingsContent,
        SettingsCommitExpectation
    ) -> SettingsRepositoryCommitResult

    private let inspect: Inspect
    private let commit: Commit
    private let maximumCASRetries: Int
    private var snapshot: SettingsRepositorySnapshot
    private var state: SettingsState

    init(
        initialState: SettingsState,
        initialSnapshot: SettingsRepositorySnapshot,
        repository: SettingsRepository,
        writer: SettingsRepositoryWriter,
        maximumCASRetries: Int = 3
    ) {
        self.init(
            initialState: initialState,
            initialSnapshot: initialSnapshot,
            inspect: { repository.inspect() },
            commit: { content, expectation in
                writer.commit(content, expecting: expectation)
            },
            maximumCASRetries: maximumCASRetries
        )
    }

    init(
        initialState: SettingsState,
        initialSnapshot: SettingsRepositorySnapshot,
        inspect: @escaping Inspect,
        commit: @escaping Commit,
        maximumCASRetries: Int = 3
    ) {
        precondition(maximumCASRetries >= 0)
        self.state = initialState
        snapshot = initialSnapshot
        self.inspect = inspect
        self.commit = commit
        self.maximumCASRetries = maximumCASRetries
    }

    func apply(
        _ mutation: SettingsMutation
    ) -> SettingsMutationCoordinatorResult {
        for attempt in 0 ... maximumCASRetries {
            let target: SettingsState
            do {
                target = try mutation.applying(to: state)
            } catch let error as SettingsMutationValidationError {
                return .recoveryRequired(
                    .invalidMutation(error),
                    lastKnownState: state
                )
            } catch {
                return .recoveryRequired(
                    .unexpected(String(describing: error)),
                    lastKnownState: state
                )
            }

            guard target != state else {
                return .unchanged(state, snapshot)
            }

            let content = SettingsContent(
                document: target.document(revision: .zero)
            )
            switch commit(content, .version(snapshot.versionToken)) {
            case .committed(let committed, _):
                do {
                    let committedState = try SettingsState(
                        document: committed.document
                    )
                    state = committedState
                    snapshot = committed
                    return .committed(committedState, committed)
                } catch let error as SettingsState.MappingError {
                    return .recoveryRequired(
                        .invalidRefreshedState(error),
                        lastKnownState: state
                    )
                } catch {
                    return .recoveryRequired(
                        .unexpected(String(describing: error)),
                        lastKnownState: state
                    )
                }
            case .recoveryRequired(let evidence):
                return .recoveryRequired(
                    .commit(evidence),
                    lastKnownState: state
                )
            case .rejected(let evidence):
                guard case .expectationMismatch = evidence.failure else {
                    return .recoveryRequired(
                        .commit(evidence),
                        lastKnownState: state
                    )
                }
                guard attempt < maximumCASRetries else {
                    return .recoveryRequired(
                        .retryLimitExceeded(
                            attempts: attempt + 1,
                            lastConflict: evidence
                        ),
                        lastKnownState: state
                    )
                }
                switch inspect() {
                case .current(let refreshed):
                    do {
                        state = try SettingsState(
                            document: refreshed.document
                        )
                        snapshot = refreshed
                    } catch let error as SettingsState.MappingError {
                        return .recoveryRequired(
                            .invalidRefreshedState(error),
                            lastKnownState: state
                        )
                    } catch {
                        return .recoveryRequired(
                            .unexpected(String(describing: error)),
                            lastKnownState: state
                        )
                    }
                case let changed:
                    return .recoveryRequired(
                        .primaryChanged(changed),
                        lastKnownState: state
                    )
                }
            }
        }
        preconditionFailure("Bounded settings CAS loop must return.")
    }

    func currentState() -> SettingsState {
        state
    }
}
