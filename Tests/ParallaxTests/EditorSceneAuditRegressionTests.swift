import AppKit
import XCTest
@testable import Parallax

@MainActor
final class EditorSceneAuditRegressionTests: XCTestCase {
    func testStoreIsCreatedOnlyOnFirstAccessForEachScene() {
        var calls = 0
        let windows = ParallaxMainWindowRegistry()
        let makeStore: @MainActor () -> LibraryStore = {
            calls += 1
            return LibraryStore(persistence: EditorAuditPersistence(applications: []))
        }
        let first = ParallaxSceneStore(mainWindows: windows, makeStore: makeStore)
        _ = ParallaxSceneStore(mainWindows: windows, makeStore: makeStore)
        let second = ParallaxSceneStore(mainWindows: windows, makeStore: makeStore)
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(first.store === first.store)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(first.store === second.store)
        XCTAssertEqual(calls, 2)
    }

    func testWindowCapturePreservesSwiftUIIdentifierAndIgnoresEvents() {
        let window = makeWindow()
        window.identifier = NSUserInterfaceItemIdentifier("main-AppWindow-1")
        let scene = makeScene()
        let capture = ParallaxMainWindowCapture.WindowCaptureView(sceneStore: scene)
        window.contentView = capture
        XCTAssertTrue(scene.window === window)
        XCTAssertEqual(window.identifier?.rawValue, "main-AppWindow-1")
        capture.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        XCTAssertNil(capture.hitTest(NSPoint(x: 10, y: 10)))
    }

    func testWindowLookupUsesVisibilityAndMiniaturizationNotTitle() {
        let windows = ParallaxMainWindowRegistry()
        let closed = makeWindow()
        closed.title = "Parallax"
        windows.register(closed)
        XCTAssertNil(windows.availableWindow)
        let visible = makeWindow()
        visible.title = "Cuentas"
        visible.testVisible = true
        windows.register(visible)
        XCTAssertTrue(windows.availableWindow === visible)
        visible.testVisible = false
        visible.testMiniaturized = true
        XCTAssertTrue(windows.availableWindow === visible)
        visible.testMiniaturized = false
        XCTAssertNil(windows.availableWindow)
    }

    func testCloseOnlyCleansOwningSceneAndRemovesWindowFromLookup() async throws {
        let windows = ParallaxMainWindowRegistry()
        let first = makeScene(windows: windows)
        let second = makeScene(windows: windows)
        let window = makeWindow()
        window.testVisible = true
        first.captureWindow(window)
        XCTAssertNil(second.windowWillClose(window))
        XCTAssertTrue(second.store.acceptsProfileEditingDrafts)
        let cleanup = try XCTUnwrap(first.windowWillClose(window))
        XCTAssertFalse(first.store.acceptsProfileEditingDrafts)
        XCTAssertNil(windows.availableWindow)
        await cleanup.value
    }

    func testQuitWithoutPendingWorkTerminatesImmediately() {
        let coordinator = ParallaxTerminationCoordinator()
        let result = coordinator.requestTermination(registry: ProfileEditorDraftRegistry()) { _ in
            XCTFail("Immediate termination must not send a deferred reply")
        }
        XCTAssertEqual(result, .terminateNow)
    }

    func testQuitDeadlineRepliesWhileKeychainTaskIsBlocked() async throws {
        let client = EditorAuditClient()
        let session = client.session()
        session.activate()
        client.suspendStaging = true
        session.beginAddingKeychainSecret()
        session.keychainSecretValue = "synthetic"
        session.saveKeychainSecret()
        await waitUntil { client.stageContinuation != nil }
        let clock = EditorAuditDeadline()
        let coordinator = ParallaxTerminationCoordinator(waitForDeadline: clock.wait)
        let reply = expectation(description: "Quit reply")
        var replies: [Bool] = []
        XCTAssertEqual(coordinator.requestTermination(registry: client.editorDraftRegistry) {
            replies.append($0)
            reply.fulfill()
        }, .terminateLater)
        await waitUntil { clock.continuation != nil && !client.acceptsProfileEditingDrafts }
        clock.advance()
        await fulfillment(of: [reply], timeout: 2)
        XCTAssertEqual(replies, [true])
        XCTAssertNotNil(client.stageContinuation)
        client.finishStage()
        await client.editorDraftRegistry.waitForSecretTasks(for: client)
        XCTAssertEqual(client.deleted.count, 1)
        XCTAssertEqual(replies, [true])
    }

    func testQuitCleanupCanFinishBeforeDeadline() async {
        let client = EditorAuditClient()
        let session = client.session()
        session.draft.notes = "Pending"
        session.draftDidChange()
        let clock = EditorAuditDeadline()
        let coordinator = ParallaxTerminationCoordinator(waitForDeadline: clock.wait)
        let reply = expectation(description: "Cleanup reply")
        var replies: [Bool] = []
        XCTAssertEqual(coordinator.requestTermination(registry: client.editorDraftRegistry) {
            replies.append($0)
            reply.fulfill()
        }, .terminateLater)
        await fulfillment(of: [reply], timeout: 2)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertEqual(replies, [true])
        await waitUntil { clock.continuation != nil }
        clock.advance()
    }

    func testRegistryCleanupDoesNotAffectAnIndependentClient() async {
        let first = EditorAuditClient()
        let second = EditorAuditClient()
        for client in [first, second] {
            let session = client.session()
            session.draft.notes = "Pending"
            session.draftDidChange()
        }
        await first.editorDraftRegistry.discardAllDrafts()
        XCTAssertTrue(first.pending.isEmpty)
        XCTAssertFalse(first.acceptsProfileEditingDrafts)
        XCTAssertEqual(second.pending.count, 1)
        XCTAssertTrue(second.acceptsProfileEditingDrafts)
    }

    private func makeScene(
        windows: ParallaxMainWindowRegistry = ParallaxMainWindowRegistry()
    ) -> ParallaxSceneStore {
        ParallaxSceneStore(mainWindows: windows) {
            LibraryStore(persistence: EditorAuditPersistence(applications: []))
        }
    }

    private func makeWindow() -> EditorAuditWindow {
        _ = NSApplication.shared
        return EditorAuditWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true
        )
    }
}

@MainActor
private final class EditorAuditWindow: NSWindow {
    var testVisible = false
    var testMiniaturized = false
    override var isVisible: Bool { testVisible }
    override var isMiniaturized: Bool { testMiniaturized }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class EditorAuditDeadline {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async throws {
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
    }
    func advance() {
        continuation?.resume()
        continuation = nil
    }
}
