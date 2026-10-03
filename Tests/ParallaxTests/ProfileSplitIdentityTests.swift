import AppKit
import SwiftUI
import XCTest
@testable import Parallax

@MainActor
final class ProfileSplitIdentityTests: XCTestCase {
    func testLayoutChangesRetainEditorSessionAndPendingSecretOperation() async throws {
        let client = EditorAuditClient()
        let capture = SplitSessionCapture()
        let host = NSHostingView(rootView: SplitSessionHarness(isCompact: false, client: client, capture: capture))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        host.layoutSubtreeIfNeeded()
        let original = try XCTUnwrap(capture.session)
        original.beginAddingKeychainSecret()
        original.keychainEnvironmentKey = "SYNTHETIC_TOKEN"
        original.keychainSecretValue = "synthetic input"
        original.draft.notes = "unsaved notes"

        host.rootView = SplitSessionHarness(isCompact: true, client: client, capture: capture)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(capture.session === original)
        XCTAssertTrue(original.isSecretSheetPresented)
        XCTAssertEqual(original.keychainSecretValue, "synthetic input")
        XCTAssertEqual(original.draft.notes, "unsaved notes")

        client.suspendStaging = true
        original.saveKeychainSecret()
        while client.stageContinuation == nil { await Task.yield() }
        host.rootView = SplitSessionHarness(isCompact: false, client: client, capture: capture)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(capture.session === original)
        XCTAssertTrue(original.isSavingKeychainSecret)
        client.finishStage()
        await client.editorDraftRegistry.waitForSecretTasks(for: client)
        XCTAssertEqual(original.stagedKeychainReferences.count, 1)
        XCTAssertTrue(client.deleted.isEmpty)
        XCTAssertFalse(original.isSecretSheetPresented)
    }
}

@MainActor
private final class SplitSessionCapture {
    var session: ProfileEditorSession?
}

private struct SplitSessionHarness: View {
    let isCompact: Bool
    let client: EditorAuditClient
    let capture: SplitSessionCapture

    var body: some View {
        ProfileSplitLayout(isCompact: isCompact) {
            Color.clear.frame(width: 100, height: 100)
            Color.clear.frame(width: 12, height: 12)
            SplitSessionProbe(client: client, capture: capture)
        }
    }
}

private struct SplitSessionProbe: View {
    @State private var session: ProfileEditorSession
    let capture: SplitSessionCapture

    init(client: EditorAuditClient, capture: SplitSessionCapture) {
        _session = State(initialValue: client.session())
        self.capture = capture
    }

    var body: some View {
        SplitSessionReader(session: session, capture: capture)
            .onAppear { session.activate() }
            .onDisappear { session.deactivate() }
    }
}

private struct SplitSessionReader: NSViewRepresentable {
    let session: ProfileEditorSession
    let capture: SplitSessionCapture

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { capture.session = session }
}
