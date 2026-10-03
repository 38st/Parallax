import AppKit
import Foundation
import XCTest
@testable import Parallax

@MainActor
final class SettingsDraftAuditRegressionTests: XCTestCase {
    private func fixture() throws -> (AppSettings, SettingsRuntimeBootstrapper) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bootstrapper = SettingsRuntimeBootstrapper(
            applicationSupportURL: root, legacyApplicationIdentifier: "audit.drafts",
            legacyCaptureOverride: { SettingsLegacySnapshotClassifier.classify([:]) }
        )
        return (AppSettings(production: bootstrapper.bootstrap()), bootstrapper)
    }

    func testBasePathDraftWithholdsAuthorityUntilIdleCommitIsVerified() async throws {
        let (settings, bootstrapper) = try fixture()
        let clock = DraftTestScheduler()
        let draft = SettingsTextDraft(
            settings: settings, read: { settings.defaultBaseStoragePath },
            write: { settings.defaultBaseStoragePath = $0 }, scheduler: clock.scheduler
        )
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: bootstrapper.applicationSupportURL), settings: settings
        )
        draft.edit("/new")
        XCTAssertFalse(store.canUseSettingsAuthority())
        store.beginAddingApplication()
        XCTAssertFalse(store.isShowingAppImporter)
        XCTAssertFalse(settings.canProvideVerifiedSettings)
        XCTAssertTrue(settings.hasPendingVersionedMutations)
        XCTAssertEqual(settings.pendingTextDraftCount, 1)
        clock.advance(.milliseconds(300))
        draft.edit("/new/path")
        clock.advance(.milliseconds(399))
        XCTAssertEqual(settings.defaultBaseStoragePath, "")
        clock.advance(.milliseconds(1))
        XCTAssertEqual(settings.defaultBaseStoragePath, "/new/path")
        XCTAssertEqual(settings.pendingTextDraftCount, 0)
        XCTAssertEqual(settings.pendingVersionedMutationCount, 1)
        XCTAssertFalse(settings.canProvideVerifiedSettings)
        await settings.waitForPendingPersistence()
        XCTAssertTrue(settings.canProvideVerifiedSettings)
        XCTAssertEqual(AppSettings(production: bootstrapper.bootstrap()).defaultBaseStoragePath, "/new/path")
    }

    func testArgumentsEnvironmentAndNotesDebounceAndFlush() async throws {
        for field in [\ProfileTemplate.argumentsText, \.environmentText, \.notes] {
            let (settings, bootstrapper) = try fixture()
            let clock = DraftTestScheduler()
            let draft = SettingsTextDraft(
                settings: settings, read: { settings.profileTemplates[0][keyPath: field] },
                write: { settings.profileTemplates[0][keyPath: field] = $0 }, scheduler: clock.scheduler
            )
            draft.edit("draft")
            XCTAssertFalse(settings.canProvideVerifiedSettings)
            clock.advance(.milliseconds(400))
            XCTAssertEqual(settings.profileTemplates[0][keyPath: field], "draft")
            await settings.waitForPendingPersistence()
            for suffix in ["submit", "focus loss", "disappear"] {
                draft.edit(suffix)
                draft.commit()
                await settings.waitForPendingPersistence()
                XCTAssertEqual(settings.profileTemplates[0][keyPath: field], suffix)
                XCTAssertTrue(settings.canProvideVerifiedSettings)
            }
            draft.edit("resign key")
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: nil)
            await settings.waitForPendingPersistence()
            XCTAssertEqual(settings.profileTemplates[0][keyPath: field], "resign key")
            draft.edit("terminate")
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            XCTAssertEqual(settings.pendingVersionedMutationCount, 0)
            XCTAssertEqual(AppSettings(production: bootstrapper.bootstrap()).profileTemplates[0][keyPath: field], "terminate")
            clock.advance(.seconds(1))
            await settings.waitForPendingPersistence()
            XCTAssertEqual(settings.pendingVersionedMutationCount, 0)
        }
    }

    func testTemplateNameDebouncesNormalizesAndRejectsInvalidDraft() async throws {
        let (settings, _) = try fixture()
        let clock = DraftTestScheduler()
        let draft = SettingsTextDraft(
            settings: settings, read: { settings.profileTemplates[0].name },
            write: { settings.profileTemplates[0].name = $0 },
            normalize: { DisplayNameValidator.normalized($0) }, scheduler: clock.scheduler
        )
        let original = settings.profileTemplates[0].name
        draft.edit("Renamed ")
        XCTAssertFalse(settings.canProvideVerifiedSettings)
        clock.advance(.milliseconds(400))
        XCTAssertEqual(settings.profileTemplates[0].name, original, "A pause must not trim text while typing")
        XCTAssertEqual(draft.value, "Renamed ")
        draft.edit("")
        clock.advance(.milliseconds(400))
        XCTAssertEqual(draft.value, "", "A pause must not restore the saved name while typing")
        draft.edit("Renamed")
        clock.advance(.milliseconds(400))
        await settings.waitForPendingPersistence()
        XCTAssertEqual(settings.profileTemplates[0].name, "Renamed")
        draft.edit("  Spaced  ")
        draft.commit()
        await settings.waitForPendingPersistence()
        XCTAssertEqual(settings.profileTemplates[0].name, "Spaced")
        XCTAssertEqual(draft.value, "Spaced")
        draft.edit("..")
        draft.commit()
        XCTAssertEqual(draft.value, "Spaced")
        XCTAssertTrue(settings.canProvideVerifiedSettings)
    }

    func testDraftSynchronizationHonorsAuthoritativeChangesAndCancelledTimer() throws {
        let (settings, _) = try fixture()
        let clock = DraftTestScheduler()
        let draft = SettingsTextDraft(
            settings: settings, read: { settings.defaultBaseStoragePath },
            write: { settings.defaultBaseStoragePath = $0 }, scheduler: clock.scheduler
        )
        draft.edit("/stale")
        settings.defaultBaseStoragePath = "/authoritative"
        draft.synchronize()
        clock.advance(.seconds(1))
        XCTAssertEqual(draft.value, "/authoritative")
        XCTAssertEqual(settings.defaultBaseStoragePath, "/authoritative")
        XCTAssertEqual(settings.pendingTextDraftCount, 0)
        settings.flushForTermination()
    }

    func testTerminationFlushesQueuedMutationsExactlyOnceAndPreservesOrder() async throws {
        let (settings, bootstrapper) = try fixture()
        settings.defaultBaseStoragePath = "/first"
        settings.defaultBaseStoragePath = "/last"
        settings.confirmBeforeLaunch = true
        settings.flushForTermination()
        XCTAssertEqual(settings.pendingVersionedMutationCount, 0)
        guard case .ready(let runtime) = bootstrapper.bootstrap() else { return XCTFail("Expected saved settings") }
        XCTAssertEqual(runtime.initialSnapshot.versionToken.revision.rawValue, 4)
        XCTAssertEqual(runtime.initialState.defaultBaseStoragePath, "/last")
        XCTAssertTrue(runtime.initialState.confirmBeforeLaunch)
        await settings.waitForPendingPersistence()
        guard case .ready(let after) = bootstrapper.bootstrap() else { return XCTFail("Expected saved settings") }
        XCTAssertEqual(after.initialSnapshot, runtime.initialSnapshot)
    }

    func testAlertBindingIgnoresImplicitDismissalAndUsesAccurateTitle() throws {
        let (settings, _) = try fixture()
        settings.defaultBaseStoragePath = String(repeating: "x", count: 4_097)
        var exporting = false
        let binding = SettingsIssuePresentation.binding(settings: settings) { exporting }
        XCTAssertTrue(binding.wrappedValue)
        binding.wrappedValue = false
        XCTAssertTrue(binding.wrappedValue)
        let issue = try XCTUnwrap(settings.persistenceIssues.first)
        XCTAssertEqual(issue.presentationTitle, String(localized: "Settings Change Not Saved"))
        exporting = true
        XCTAssertFalse(binding.wrappedValue)
        exporting = false
        XCTAssertTrue(binding.wrappedValue)
        settings.dismissPersistenceIssue(id: issue.id)
        XCTAssertFalse(binding.wrappedValue)
    }

    func testUndoResetShortcutDefersToTextResponders() throws {
        let settings = AppSettings()
        settings.profileTemplates = [ProfileTemplate(name: "Custom")]
        settings.resetProfileTemplatesToDefaults()
        XCTAssertFalse(SettingsUndoResetShortcut.perform(settings: settings, firstResponder: NSTextView()))
        XCTAssertFalse(SettingsUndoResetShortcut.perform(settings: settings, firstResponder: NSTextField()))
        XCTAssertTrue(settings.canUndoProfileTemplateReset)
        XCTAssertTrue(SettingsUndoResetShortcut.perform(settings: settings, firstResponder: NSView()))
        XCTAssertEqual(settings.profileTemplateNames, ["Custom"])
    }
}

@MainActor
private final class DraftTestScheduler {
    private var now: Duration = .zero
    private var jobs: [(id: UUID, deadline: Duration, action: @MainActor () -> Void)] = []

    var scheduler: SettingsDraftScheduler {
        SettingsDraftScheduler { [self] delay, action in
            let id = UUID()
            jobs.append((id, now + delay, action))
            return { self.jobs.removeAll { $0.id == id } }
        }
    }

    func advance(_ duration: Duration) {
        now += duration
        let ready = jobs.filter { $0.deadline <= now }
        jobs.removeAll { $0.deadline <= now }
        for job in ready { job.action() }
    }
}
