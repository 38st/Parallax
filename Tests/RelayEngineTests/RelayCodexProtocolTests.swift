import Foundation
import RelayCore
import RelayEngine
import XCTest

final class RelayCodexProtocolTests: XCTestCase {
    func testDecoderHandlesFragmentedAndMultipleMessages() throws {
        var decoder = RelayJSONLDecoder()
        let first = Data(#"{"id":1,"result":{"thread":{"id":"t"}}}"#.utf8)
        let second = Data(#"{"method":"turn/completed","params":{"turn":{"status":"completed"}}}"#.utf8)
        let split = first.count / 2

        XCTAssertEqual(
            try decoder.append(Data(first[..<split])),
            []
        )
        var remainder = Data(first[split...])
        remainder.append(0x0A)
        remainder.append(second)
        remainder.append(0x0A)
        let messages = try decoder.append(remainder)

        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].isResponse)
        XCTAssertEqual(messages[1].method, "turn/completed")
        try decoder.finish()
    }

    func testMalformedLineFailsInsteadOfBeingSkipped() throws {
        var decoder = RelayJSONLDecoder()
        XCTAssertThrowsError(try decoder.append(Data("not-json\n".utf8))) {
            XCTAssertEqual(
                $0 as? RelayCodexProtocolError,
                .malformedMessage
            )
        }
    }

    func testShapeWithoutMethodOrResponseFails() throws {
        var decoder = RelayJSONLDecoder()
        XCTAssertThrowsError(try decoder.append(Data("{\"id\":1}\n".utf8))) {
            XCTAssertEqual(
                $0 as? RelayCodexProtocolError,
                .invalidMessageShape
            )
        }
    }

    func testIncompleteFinalFrameFails() throws {
        var decoder = RelayJSONLDecoder()
        _ = try decoder.append(Data("{\"id\":1".utf8))
        XCTAssertThrowsError(try decoder.finish()) {
            XCTAssertEqual(
                $0 as? RelayCodexProtocolError,
                .malformedMessage
            )
        }
    }

    func testReadOnlyTurnHasRestrictedReadAndNoWriteRoot() throws {
        let fixture = try RelayCodexTestContextFixture(
            stage: .scout,
            authority: .scout
        )
        defer { fixture.remove() }
        let message = try RelayCodexMessages.startTurn(
            id: 2,
            threadID: "thread",
            prompt: "Scout",
            context: fixture.context,
            outputSchema: .object(["type": .string("object")])
        )
        let sandbox = message.params?["sandboxPolicy"]

        XCTAssertEqual(sandbox?["type"], .string("readOnly"))
        XCTAssertEqual(
            sandbox?["access"]?["type"],
            .string("restricted")
        )
        XCTAssertEqual(
            sandbox?["access"]?["includePlatformDefaults"],
            .boolean(false)
        )
        XCTAssertNil(sandbox?["writableRoots"])
    }

    func testWritableTurnIsBoundToWorkspaceWithNetworkOff() throws {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }
        let message = try RelayCodexMessages.startTurn(
            id: 2,
            threadID: "thread",
            prompt: "Implement",
            context: fixture.context,
            outputSchema: .object(["type": .string("object")])
        )
        let sandbox = message.params?["sandboxPolicy"]

        XCTAssertEqual(sandbox?["type"], .string("workspaceWrite"))
        XCTAssertEqual(sandbox?["networkAccess"], .boolean(false))
        XCTAssertEqual(
            sandbox?["writableRoots"],
            .array([.string(fixture.root.path)])
        )
    }

    func testWorkspaceReplacementInvalidatesMessageAuthority() throws {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(
            try RelayCodexMessages.startThread(
                id: 1,
                workspace: fixture.context.workspace
            )
        ) {
            XCTAssertEqual(
                $0 as? RelayCodexProtocolError,
                .workspaceIdentityChanged
            )
        }
    }

    func testControlContextRejectsTaskIdentityMismatch() throws {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try RelayCodexControlContext(
                taskID: RelayTaskID(),
                stageID: fixture.context.stageID,
                attemptID: fixture.context.attemptID,
                workspace: fixture.context.workspace,
                stage: .implement,
                authority: .implementer
            )
        ) {
            XCTAssertEqual(
                $0 as? RelayCodexProtocolError,
                .stageAuthorityMismatch
            )
        }
    }

    func testApprovalResponseNeverGrantsSessionAuthority() throws {
        let message = RelayCodexMessages.approvalResponse(
            id: .integer(9),
            accepted: true
        )
        let encoded = try RelayCodexMessages.encode(message)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertTrue(text.contains("accept"))
        XCTAssertFalse(text.contains("acceptForSession"))
    }

    func testInterruptUsesStableMethodAndExactTurnIdentity() {
        let message = RelayCodexMessages.interruptTurn(
            id: 7,
            threadID: "thread-a",
            turnID: "turn-b"
        )
        XCTAssertEqual(message.method, "turn/interrupt")
        XCTAssertEqual(message.params?["threadId"], .string("thread-a"))
        XCTAssertEqual(message.params?["turnId"], .string("turn-b"))
    }
}
