import Foundation
import Observation
import XCTest

@testable import Parallax

@MainActor
final class AccountsAuditRegressionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSuccessfulCodexRefreshClearsMissingLifetimeTokens() throws {
        var original = account()
        original.lifetimeTokens = 123
        let store = try store([original])
        let generation = try XCTUnwrap(
            store.recordRefreshAttempt(accountID: original.id, kind: .refresh))
        let application = CorporateAccountRefreshApplication(status: status(), account: original)
        XCTAssertNil(application.failure)
        XCTAssertTrue(
            store.recordRefreshSuccess(application.account, operationGeneration: generation))
        XCTAssertNil(store.trackedAccounts.first?.lifetimeTokens)
    }

    func testHealthyDueToleratesSmallBackwardClockSlew() throws {
        let account = account()
        let coordinator = CorporateAccountOperationCoordinator(store: try store([account]))
        XCTAssertTrue(coordinator.isDue(account, now: now.addingTimeInterval(299.5)))
        XCTAssertFalse(coordinator.isDue(account, now: now.addingTimeInterval(290)))
        coordinator.consecutiveFailures[account.id] = 1
        XCTAssertFalse(coordinator.isDue(account, now: now.addingTimeInterval(299.5)))
    }

    func testCancelledCodexLoginCompletionPublishesAdmissionChange() async throws {
        var first = account()
        first.isConnected = false
        var second = account()
        second.isConnected = false
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: try store([first, second]), service: service)
        let token = try XCTUnwrap(coordinator.startConnect(first))
        let login = call(first, .login)
        await until { service.callCount(login) == 1 }
        coordinator.cancelAll()
        let observed = CancellationFlag()
        withObservationTracking {
            XCTAssertTrue(coordinator.isMutationScopeBusy(for: second))
        } onChange: {
            observed.cancel()
        }
        service.failOldest(login, with: CancellationError())
        await coordinator.waitForCompletion(token)
        XCTAssertFalse(coordinator.isMutationScopeBusy(for: second))
        XCTAssertTrue(observed.isCancelled)
    }

    func testFailedUserSaveSurvivesUnrelatedBackgroundSave() throws {
        let original = account()
        let other = account()
        let store = try store([original, other])
        var invalid = original
        invalid.resetsAt = Date(timeIntervalSince1970: .infinity)
        XCTAssertFalse(store.saveTrackedAccount(invalid))
        let generation = try XCTUnwrap(
            store.recordRefreshAttempt(accountID: other.id, kind: .refresh))
        XCTAssertTrue(store.recordRefreshSuccess(other, operationGeneration: generation))
        XCTAssertNotNil(store.persistenceErrorMessage)
        XCTAssertTrue(store.saveTrackedAccount(other))
        XCTAssertNotNil(store.persistenceErrorMessage)
        XCTAssertTrue(store.saveTrackedAccount(original))
        XCTAssertNil(store.persistenceErrorMessage)
    }

    func testDiscardedFailedDraftClearsOnlyItsOwnSaveError() throws {
        let store = try store([])
        var first = account()
        first.resetsAt = Date(timeIntervalSince1970: .infinity)
        var second = account()
        second.resetsAt = first.resetsAt
        XCTAssertFalse(store.saveTrackedAccount(first))
        XCTAssertFalse(store.saveTrackedAccount(second))
        store.discardFailedUserSave(accountID: first.id)
        XCTAssertNotNil(store.persistenceErrorMessage)
        store.discardFailedUserSave(accountID: second.id)
        XCTAssertNil(store.persistenceErrorMessage)
        XCTAssertTrue(store.trackedAccounts.isEmpty)
    }

    func testRejectedRefreshResultIsCompletedWithSaveFailure() throws {
        let original = account()
        let store = try store([original])
        let generation = try XCTUnwrap(
            store.recordRefreshAttempt(accountID: original.id, kind: .refresh))
        var invalid = original
        invalid.providerResetsAt = Date(timeIntervalSince1970: .infinity)
        XCTAssertFalse(store.recordRefreshSuccess(invalid, operationGeneration: generation))
        let updated = try XCTUnwrap(store.trackedAccounts.first)
        XCTAssertNotNil(updated.lastRefreshCompletedAt)
        XCTAssertNotNil(updated.lastRefreshFailure)
        XCTAssertNotEqual(updated.lastRefreshFailure, .interrupted)
        XCTAssertNil(store.inFlightAttemptKind(for: original.id))
        XCTAssertNotNil(store.persistenceErrorMessage)
    }

    func testEditorAndNewAccountsStoreNoPlanPlaceholder() throws {
        var draft = TrackedAccountEditorDraft(account: nil, now: now)
        XCTAssertEqual(draft.planName, "")
        draft.planName = "  "
        XCTAssertEqual(draft.account(id: UUID()).planName, "")
        let original = account()
        draft = TrackedAccountEditorDraft(account: original, now: now)
        draft.planName = " "
        XCTAssertEqual(draft.merging(into: original).planName, "")
        let store = try store([])
        for provider in AIProvider.allCases {
            XCTAssertEqual(store.addTrackedAccount(provider: provider)?.planName, "")
        }
    }

    func testUnavailableClaudeStatusAfterLoginDoesNotClaimFailedSignInOrSignOut() async throws {
        var original = account()
        original.provider = .claude
        original.isConnected = false
        original.lastCheckedAt = nil
        let store = try store([original])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(store: store, service: service)
        let token = try XCTUnwrap(coordinator.startConnect(original))
        let login = call(original, .login)
        await until { service.callCount(login) == 1 }
        service.failOldest(login, with: AIAccountConnectionError.statusUnavailable)
        await coordinator.waitForCompletion(token)
        let updated = try XCTUnwrap(store.trackedAccounts.first)
        XCTAssertEqual(updated.lastRefreshFailure, .statusUnavailable)
        XCTAssertFalse(updated.isSignedIn)
        XCTAssertNotEqual(updated.signInRequired, true)
        let presentation = CorporateAccountFailurePresentation(
            account: updated, failure: .statusUnavailable)
        XCTAssertNotEqual(presentation.statusLabel, String(localized: "Sign-in failed"))
    }

    func testClaudeSignInsRemainConcurrent() async throws {
        var first = account()
        first.provider = .claude
        var second = account()
        second.provider = .claude
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: try store([first, second]), service: service)
        let one = try XCTUnwrap(coordinator.startConnect(first))
        let two = try XCTUnwrap(coordinator.startConnect(second))
        let firstCall = call(first, .login)
        let secondCall = call(second, .login)
        await until { service.callCount(firstCall) == 1 && service.callCount(secondCall) == 1 }
        service.completeOldest(firstCall, with: status())
        service.completeOldest(secondCall, with: status())
        await coordinator.waitForCompletion(one)
        await coordinator.waitForCompletion(two)
    }

    func testOverviewDoesNotClaimCapacityWithoutCurrentUsage() throws {
        let empty = try store([])
        XCTAssertEqual(
            CorporateLiveAccountOverviewContent(store: empty).attentionDescription,
            String(localized: "No current usage data is available.")
        )
        var stale = account()
        stale.lastCheckedAt = now.addingTimeInterval(-1800)
        XCTAssertEqual(
            CorporateLiveAccountOverviewContent(store: try store([stale])).attentionDescription,
            String(localized: "No current usage data is available.")
        )
    }

    func testDefaultLabelsAndWeeklyFallbackUseLocalization() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Parallax/Resources")
        for language in ["en"] {
            let bundle = try XCTUnwrap(
                Bundle(path: resources.appendingPathComponent("\(language).lproj").path))
            let store = try store([])
            XCTAssertEqual(
                store.addTrackedAccount(provider: .codex, localizationBundle: bundle)?.label,
                "Codex Account 1")
            XCTAssertEqual(
                store.addTrackedAccount(provider: .claude, localizationBundle: bundle)?.label,
                "Claude Account 1")
            let view = CorporateAccountTrackerContent(
                store: store,
                operationCoordinator: CorporateAccountOperationCoordinator(store: store))
            XCTAssertEqual(
                view.usageWindowTitle(.init(kind: .weeklyModel, usagePercent: 10), bundle: bundle),
                "Weekly · Model")
        }
    }

    func testFailedEditorSaveKeepsDraftOpenUntilSuccessfulSave() throws {
        let original = account()
        let store = try store([original])
        var draft = TrackedAccountEditorDraft(account: original, now: now)
        draft.label = "Edited"
        draft.resetsAt = Date(timeIntervalSince1970: .infinity)
        var dismissed = false
        XCTAssertFalse(draft.save(to: store, id: original.id) { dismissed = true })
        XCTAssertFalse(dismissed)
        XCTAssertEqual(draft.label, "Edited")
        XCTAssertEqual(store.trackedAccounts.first?.label, original.label)
        draft.resetsAt = original.resetsAt
        XCTAssertTrue(draft.save(to: store, id: original.id) { dismissed = true })
        XCTAssertTrue(dismissed)
        XCTAssertEqual(store.trackedAccounts.first?.label, "Edited")
    }

    func testAddAndConnectExplainsBusyCodexLoginWithoutAddingSilentRow() async throws {
        let original = account()
        let store = try store([original])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(store: store, service: service)
        let token = try XCTUnwrap(coordinator.startConnect(original))
        let login = call(original, .login)
        await until { service.callCount(login) == 1 }
        CorporateAccountTrackerContent(store: store, operationCoordinator: coordinator)
            .addAndConnect(.codex)
        XCTAssertEqual(store.trackedAccounts.count, 1)
        XCTAssertNotNil(coordinator.admissionMessage)
        service.completeOldest(login, with: status())
        await coordinator.waitForCompletion(token)
        XCTAssertNil(coordinator.admissionMessage)
    }

    func testApplicationQuitSynchronouslyRequestsProviderTermination() throws {
        let service = AuditTerminationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: try store([]), service: service)
        coordinator.prepareForTermination()
        XCTAssertTrue(service.wasTerminated)
    }

    func testNearLimitTileRetainsRefreshingAccount() throws {
        let account = account()
        let store = try store([account])
        let coordinator = CorporateAccountOperationCoordinator(store: store)
        XCTAssertNotNil(store.recordRefreshAttempt(accountID: account.id, kind: .refresh))
        let view = CorporateAccountTrackerContent(store: store, operationCoordinator: coordinator)
        XCTAssertEqual(view.currentNearLimitCount, 1)
    }

    func testSignedOutAccountNeverShowsCurrentUsageDuringEitherAttempt() {
        var account = account()
        account.signInRequired = true
        for kind in [TrackedAccountAttemptKind.refresh, .signIn] {
            let presentation = CorporateAccountMetadataPresentation(
                account: account, now: now, inFlightAttemptKind: kind
            )
            XCTAssertFalse(presentation.hasCurrentUsage)
            XCTAssertFalse(presentation.freshness.isCurrent)
            XCTAssertEqual(presentation.retainedUsagePercent, 95)
        }
    }

    func testHealthyAccountIsDueAtFiveMinutes() throws {
        let account = account()
        let store = try store([account])
        let coordinator = CorporateAccountOperationCoordinator(store: store)
        XCTAssertFalse(coordinator.isDue(account, now: now.addingTimeInterval(297)))
        XCTAssertTrue(coordinator.isDue(account, now: now.addingTimeInterval(300)))
        coordinator.consecutiveFailures[account.id] = 10
        XCTAssertFalse(coordinator.isDue(account, now: now.addingTimeInterval(3599)))
        XCTAssertTrue(coordinator.isDue(account, now: now.addingTimeInterval(3600)))
    }

    func testCancelledTransportErrorDoesNotIncreaseBackoff() async throws {
        let account = account()
        let store = try store([account])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(store: store, service: service)
        let token = try XCTUnwrap(coordinator.startRefresh(account))
        let call = call(account, .refresh)
        await until { service.callCount(call) == 1 }
        coordinator.cancelAll()
        service.failOldest(call, with: AIAccountConnectionError.statusUnavailable)
        await coordinator.waitForCompletion(token)
        XCTAssertEqual(coordinator.consecutiveFailures[account.id, default: 0], 0)
        XCTAssertEqual(store.trackedAccounts.first?.lastRefreshFailure, .interrupted)
    }

    func testAutomaticPassRechecksDueAfterManualRefresh() async throws {
        var first = account()
        first.label = "A"
        first.lastCheckedAt = now.addingTimeInterval(-1800)
        var second = account(id: UUID())
        second.label = "B"
        second.lastCheckedAt = first.lastCheckedAt
        let store = try store([first, second])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(store: store, service: service)
        let firstCall = call(first, .refresh)
        let secondCall = call(second, .refresh)
        let sweep = Task { await coordinator.refreshDueAccounts() }
        await until { service.callCount(firstCall) == 1 }
        let manual = try XCTUnwrap(coordinator.startRefresh(second))
        await until { service.callCount(secondCall) == 1 }
        service.completeOldest(secondCall, with: status())
        await coordinator.waitForCompletion(manual)
        service.completeOldest(firstCall, with: status())
        // Release a duplicate if the buggy pass starts one, without leaving a
        // suspended continuation behind when this regression fails.
        await until { coordinator.runningOperationCount == 0 || service.callCount(secondCall) == 2 }
        for _ in 0..<100 { await Task.yield() }
        if service.callCount(secondCall) == 2 {
            service.completeOldest(secondCall, with: status())
        }
        await sweep.value
        XCTAssertEqual(service.callCount(secondCall), 1)
    }

    func testCodexSignInsSerializeButRefreshesRemainIndependent() async throws {
        let first = account()
        let second = account()
        let store = try store([first, second])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(store: store, service: service)
        let token = try XCTUnwrap(coordinator.startConnect(first))
        await until { service.callCount(self.call(first, .login)) == 1 }
        let secondLogin = coordinator.startConnect(second)
        XCTAssertNil(secondLogin)
        if let secondLogin {
            await until { service.callCount(self.call(second, .login)) == 1 }
            service.completeOldest(call(second, .login), with: status())
            await coordinator.waitForCompletion(secondLogin)
        }
        let refresh = try XCTUnwrap(coordinator.startRefresh(second))
        await until { service.callCount(self.call(second, .refresh)) == 1 }
        service.completeOldest(call(first, .login), with: status())
        service.completeOldest(call(second, .refresh), with: status())
        await coordinator.waitForCompletion(token)
        await coordinator.waitForCompletion(refresh)

    }

    func testCancelledRefreshCannotQueueSignInBesideAnotherCodexLogin() async throws {
        let first = account()
        let second = account()
        let store = try store([first, second])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(store: store, service: service)
        let login = try XCTUnwrap(coordinator.startConnect(first))
        let refresh = try XCTUnwrap(coordinator.startRefresh(second))
        await until {
            service.callCount(self.call(first, .login)) == 1
                && service.callCount(self.call(second, .refresh)) == 1
        }
        coordinator.cancelOperations(accountID: second.id)
        let queued = coordinator.startConnect(second)
        XCTAssertNil(queued)
        service.failOldest(call(second, .refresh), with: CancellationError())
        await coordinator.waitForCompletion(refresh)
        if let queued {
            await until { service.callCount(self.call(second, .login)) == 1 }
            service.completeOldest(call(second, .login), with: status())
            await coordinator.waitForCompletion(queued)
        }
        service.completeOldest(call(first, .login), with: status())
        await coordinator.waitForCompletion(login)
    }

    func testQueuedCodexSignInReservesCallbackUntilCancelledRefreshFinishes() async throws {
        let first = account()
        let second = account()
        let store = try store([first, second])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(store: store, service: service)
        let refresh = try XCTUnwrap(coordinator.startRefresh(first))
        await until { service.callCount(self.call(first, .refresh)) == 1 }
        coordinator.cancelOperations(accountID: first.id)
        let queued = try XCTUnwrap(coordinator.startConnect(first))
        let other = coordinator.startConnect(second)
        XCTAssertNil(other)
        if let other {
            await until { service.callCount(self.call(second, .login)) == 1 }
            service.completeOldest(call(second, .login), with: status())
            await coordinator.waitForCompletion(other)
        }
        service.failOldest(call(first, .refresh), with: CancellationError())
        await coordinator.waitForCompletion(refresh)
        await until { service.callCount(self.call(first, .login)) == 1 }
        service.completeOldest(call(first, .login), with: status())
        await coordinator.waitForCompletion(queued)
    }

    func testNewerSchemaLoadsWithoutRewritingUnknownFields() throws {
        let defaults = try defaults()
        let data = try JSONEncoder().encode(
            LegacyCorporateWorkspaceEnvelope.fresh(trackedAccounts: [account()]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["trackedAccountSchemaVersion"] = 99
        object["futureField"] = ["preserve": true]
        let original = try JSONSerialization.data(withJSONObject: object)
        defaults.set(original, forKey: "workspace")
        let store = CorporateUsageStore(
            userDefaults: defaults, persistenceKey: "workspace",
            freshnessScheduler: AuditFreshnessScheduler())
        XCTAssertEqual(store.trackedAccounts.count, 1)
        XCTAssertEqual(defaults.data(forKey: "workspace"), original)
        var account = try XCTUnwrap(store.trackedAccounts.first)
        let generation = try XCTUnwrap(
            store.recordRefreshAttempt(accountID: account.id, kind: .refresh))
        XCTAssertTrue(store.recordRefreshSuccess(account, operationGeneration: generation))
        XCTAssertEqual(defaults.data(forKey: "workspace"), original)
        account.label = "Explicit edit"
        XCTAssertTrue(store.saveTrackedAccount(account))
        XCTAssertEqual(defaults.data(forKey: "workspace.newer-schema"), original)
        let saved = try JSONDecoder().decode(
            LegacyCorporateWorkspaceEnvelope.self,
            from: XCTUnwrap(defaults.data(forKey: "workspace")))
        XCTAssertEqual(saved.trackedAccounts?.first?.label, "Explicit edit")
    }

    func testInvalidAccountDoesNotSilentlySucceedOrPoisonLaterSaves() throws {
        let original = account()
        let store = try store([original])
        XCTAssertTrue(store.saveTrackedAccount(original))
        var invalid = original
        invalid.providerResetsAt = Date(timeIntervalSince1970: .infinity)
        XCTAssertFalse(store.saveTrackedAccount(invalid))
        XCTAssertNotNil(store.persistenceErrorMessage)
        XCTAssertEqual(store.trackedAccounts, [original])
        var edited = original
        edited.label = "Edited"
        XCTAssertTrue(store.saveTrackedAccount(edited))
        XCTAssertNil(store.persistenceErrorMessage)
    }

    func testIncompleteSignInClearsSignInRequiredAndRetainsLastKnownValues() async throws {
        for provider in AIProvider.allCases {
            var account = account()
            account.provider = provider
            account.signInRequired = true
            account.lifetimeTokens = provider == .codex ? 123 : nil
            account.usageWindows = [.init(kind: .session, usagePercent: 95)]
            let store = try store([account])
            let service = ControlledCorporateAccountOperationService()
            let coordinator = CorporateAccountOperationCoordinator(store: store, service: service)
            let token = try XCTUnwrap(coordinator.startConnect(account))
            let login = call(account, .login)
            await until { service.callCount(login) == 1 }
            service.completeOldest(
                login,
                with: .init(
                    email: nil, planName: nil, usagePercent: nil, resetsAt: nil, lifetimeTokens: nil
                ))
            await coordinator.waitForCompletion(token)
            let updated = try XCTUnwrap(store.trackedAccounts.first)
            XCTAssertTrue(updated.isSignedIn)
            XCTAssertEqual(updated.lastRefreshFailure, .incompleteProviderData)
            XCTAssertEqual(updated.usageWindows, account.usageWindows)
            XCTAssertEqual(updated.lifetimeTokens, account.lifetimeTokens)
            XCTAssertEqual(updated.lastSuccessfulRefreshAt, account.lastSuccessfulRefreshAt)
        }
    }

    func testProviderErrorsUseLocalizedFailureMessages() {
        let pairs: [(AIAccountConnectionError, TrackedAccountRefreshFailure)] = [
            (.notAuthenticated, .authenticationRequired),
            (.executableMissing("Claude"), .providerToolUnavailable),
            (.loginFailed, .signInFailed), (.statusUnavailable, .statusUnavailable),
        ]
        for (error, failure) in pairs {
            XCTAssertEqual(error.errorDescription, failure.userMessage)
        }
    }

    private func account(id: UUID = UUID()) -> TrackedAIAccount {
        TrackedAIAccount(
            id: id, provider: .codex, label: "Account", email: "", planName: "Plus",
            usagePercent: 95, resetsAt: now.addingTimeInterval(3600), lastCheckedAt: now,
            isConnected: true, lifetimeTokens: nil)
    }

    private func defaults() throws -> UserDefaults {
        let suite = "AccountsAuditRegressionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func store(_ accounts: [TrackedAIAccount]) throws -> CorporateUsageStore {
        CorporateUsageStore(
            userDefaults: try defaults(), persistenceKey: "workspace", initialAccounts: accounts,
            clock: { self.now }, freshnessScheduler: AuditFreshnessScheduler())
    }

    private func call(
        _ account: TrackedAIAccount, _ kind: ControlledCorporateAccountOperationService.Call.Kind
    ) -> ControlledCorporateAccountOperationService.Call {
        .init(kind: kind, provider: account.provider, accountID: account.id)
    }

    private func status() -> ConnectedAIAccountStatus {
        .init(email: nil, planName: nil, usagePercent: 20, resetsAt: nil, lifetimeTokens: nil)
    }

    private func until(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<10000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Controlled operation did not reach expected state")
    }
}

@MainActor
private final class AuditFreshnessScheduler: CorporateFreshnessScheduling {
    func schedule(_ invalidate: @escaping @MainActor () -> Void) {}
}

private final class AuditTerminationService: CorporateAccountOperationServicing, @unchecked Sendable
{
    private let lock = NSLock()
    private var terminated = false
    var wasTerminated: Bool { lock.withLock { terminated } }
    func terminateProviderProcesses() { lock.withLock { terminated = true } }
    func login(provider: AIProvider, accountID: UUID) async throws -> ConnectedAIAccountStatus {
        throw CancellationError()
    }
    func refresh(provider: AIProvider, accountID: UUID) async throws -> ConnectedAIAccountStatus {
        throw CancellationError()
    }
}
