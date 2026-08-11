import Foundation
import RelayCore
import RelayEngine
import XCTest

final class RelayCodexSessionTests: XCTestCase {
    func testStableHandshakeThreadTurnAndCompletion() async throws {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }
        let sink = ByteSink()
        let session = RelayCodexSession(context: fixture.context) { bytes in
            await sink.append(bytes)
        }
        try await prepareRunningSession(session)
        try await session.receive(line(
            #"{"method":"turn/completed","params":{"turn":{"id":"turn-a","status":"completed"}}}"#
        ))

        let completedState = await session.state
        XCTAssertEqual(
            completedState,
            .turnCompleted(
                threadID: "thread-a",
                turnID: "turn-a",
                status: "completed"
            )
        )
        let sent = await sink.snapshot()
        XCTAssertEqual(sent.count, 4)
        XCTAssertTrue(try text(sent[0]).contains("initialize"))
        XCTAssertTrue(try text(sent[1]).contains("initialized"))
        XCTAssertTrue(try text(sent[2]).contains("thread/start"))
        XCTAssertTrue(try text(sent[3]).contains("turn/start"))
    }

    func testApprovalRequiresExactDurableDecisionAndIsSingleUse() async throws {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }
        let sink = ByteSink()
        let session = RelayCodexSession(context: fixture.context) { bytes in
            await sink.append(bytes)
        }
        let approvalTask = approvalRequest(from: session.events)
        try await prepareRunningSession(session)
        try await session.receive(commandApprovalLine(
            id: "approval-1",
            cwd: fixture.root.path
        ))
        let request = try await approvalTask.value
        let decision = grantedDecision(
            context: fixture.context,
            request: request
        )
        let token = RelayCodexDurableDecisionToken(
            decision: decision,
            request: request
        )
        try await session.resolveApproval(request: request, token: token)

        do {
            try await session.resolveApproval(request: request, token: token)
            XCTFail("duplicate approval was accepted")
        } catch RelayCodexSessionError.approvalAlreadyResolved {
            // Expected.
        }
        let response = try text(await sink.snapshot().last!)
        XCTAssertTrue(response.contains("accept"))
        XCTAssertFalse(response.contains("acceptForSession"))
    }

    func testApprovalRejectsMismatchedTurnBeforeSurfacing() async throws {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }
        let session = RelayCodexSession(context: fixture.context) { _ in }
        try await prepareRunningSession(session)

        do {
            try await session.receive(line(
                #"{"id":"bad","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-a","turnId":"other-turn","itemId":"item-a","cwd":"\#(fixture.root.path)","command":"swift test"}}"#
            ))
            XCTFail("mismatched turn was accepted")
        } catch RelayCodexSessionError.approvalContextMismatch {
            // Expected.
        }
        let state = await session.state
        XCTAssertEqual(state, .failed)
    }

    func testApprovalRejectsWorkspaceAndAuthorityExpansion() async throws {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }
        let session = RelayCodexSession(context: fixture.context) { _ in }
        try await prepareRunningSession(session)

        do {
            try await session.receive(line(
                #"{"id":"bad","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-a","turnId":"turn-a","itemId":"item-a","cwd":"/tmp","command":"swift test","additionalPermissions":{"fs":"/"}}}"#
            ))
            XCTFail("expanded workspace authority was accepted")
        } catch RelayCodexSessionError.approvalOutsideAuthority {
            // Expected.
        }
    }

    func testReadOnlyStageRejectsFileChangeApproval() async throws {
        let fixture = try RelayCodexTestContextFixture(
            stage: .scout,
            authority: .scout
        )
        defer { fixture.remove() }
        let session = RelayCodexSession(context: fixture.context) { _ in }
        try await prepareRunningSession(session)

        do {
            try await session.receive(line(
                #"{"id":"file-1","method":"item/fileChange/requestApproval","params":{"threadId":"thread-a","turnId":"turn-a","itemId":"item-file","grantRoot":"\#(fixture.root.path)"}}"#
            ))
            XCTFail("read-only stage accepted file change authority")
        } catch RelayCodexSessionError.approvalOutsideAuthority {
            // Expected.
        }
    }

    func testApprovalRejectsDecisionForDifferentRequest() async throws {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }
        let session = RelayCodexSession(context: fixture.context) { _ in }
        let approvalTask = approvalRequest(from: session.events)
        try await prepareRunningSession(session)
        try await session.receive(commandApprovalLine(
            id: "approval-1",
            cwd: fixture.root.path
        ))
        let request = try await approvalTask.value
        let wrong = RelayDecision(
            id: RelayDecisionID(),
            taskID: fixture.context.taskID,
            kind: .executeRepositoryCode,
            scope: "relay-codex-approval:\(String(repeating: "0", count: 64))",
            status: .granted,
            requestedAt: RelayInstant(rawValue: 1),
            decidedAt: RelayInstant(rawValue: 2),
            rationale: "Approved exact request."
        )

        do {
            try await session.resolveApproval(
                request: request,
                token: RelayCodexDurableDecisionToken(
                    decision: wrong,
                    request: request
                )
            )
            XCTFail("mismatched durable decision was accepted")
        } catch RelayCodexSessionError.durableDecisionMismatch {
            // Expected.
        }
    }

    func testTurnCompletionInvalidatesPendingApproval() async throws {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }
        let session = RelayCodexSession(context: fixture.context) { _ in }
        let approvalTask = approvalRequest(from: session.events)
        try await prepareRunningSession(session)
        try await session.receive(commandApprovalLine(
            id: "approval-1",
            cwd: fixture.root.path
        ))
        let request = try await approvalTask.value
        let token = RelayCodexDurableDecisionToken(
            decision: grantedDecision(
                context: fixture.context,
                request: request
            ),
            request: request
        )
        try await session.receive(line(
            #"{"method":"turn/completed","params":{"turn":{"id":"turn-a","status":"completed"}}}"#
        ))

        do {
            try await session.resolveApproval(request: request, token: token)
            XCTFail("approval survived turn completion")
        } catch RelayCodexSessionError.unknownApproval {
            // Expected.
        }
    }

    func testDurableDecisionIdentifierCannotAuthorizeSecondRequest()
        async throws
    {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }
        let session = RelayCodexSession(context: fixture.context) { _ in }
        let firstApprovalTask = approvalRequest(from: session.events)
        try await prepareRunningSession(session)
        try await session.receive(commandApprovalLine(
            id: "approval-1",
            itemID: "item-1",
            cwd: fixture.root.path
        ))
        let firstRequest = try await firstApprovalTask.value
        let firstDecision = grantedDecision(
            context: fixture.context,
            request: firstRequest
        )
        try await session.resolveApproval(
            request: firstRequest,
            token: RelayCodexDurableDecisionToken(
                decision: firstDecision,
                request: firstRequest
            )
        )

        let secondApprovalTask = approvalRequest(from: session.events)
        try await session.receive(commandApprovalLine(
            id: "approval-2",
            itemID: "item-2",
            cwd: fixture.root.path
        ))
        let secondRequest = try await secondApprovalTask.value
        let replayedIdentifier = RelayDecision(
            id: firstDecision.id,
            taskID: fixture.context.taskID,
            kind: .executeRepositoryCode,
            scope: secondRequest.durableDecisionScope,
            status: .granted,
            requestedAt: RelayInstant(rawValue: 3),
            decidedAt: RelayInstant(rawValue: 4),
            rationale: "Attempted replay."
        )

        do {
            try await session.resolveApproval(
                request: secondRequest,
                token: RelayCodexDurableDecisionToken(
                    decision: replayedIdentifier,
                    request: secondRequest
                )
            )
            XCTFail("durable decision identifier was replayed")
        } catch RelayCodexSessionError.durableDecisionAlreadyUsed {
            // Expected.
        }
    }

    func testEventBufferOverflowIsTerminal() async throws {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }
        let session = RelayCodexSession(
            context: fixture.context,
            eventBufferCapacity: 1
        ) { _ in }
        try await session.initialize()
        try await session.receive(line(#"{"id":0,"result":{}}"#))
        try await session.startThread()

        do {
            try await session.receive(line(
                #"{"id":1,"result":{"thread":{"id":"thread-a"}}}"#
            ))
            XCTFail("event overflow was silently dropped")
        } catch RelayCodexSessionError.eventBufferOverflow {
            // Expected.
        }
        let state = await session.state
        XCTAssertEqual(state, .failed)
    }

    func testUnknownAndDuplicateResponsesFailClosed() async throws {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }
        let session = RelayCodexSession(context: fixture.context) { _ in }
        try await session.initialize()
        do {
            try await session.receive(line(#"{"id":9,"result":{}}"#))
            XCTFail("unknown response was accepted")
        } catch RelayCodexSessionError.unknownResponseID {
            // Expected.
        }

        let duplicate = RelayCodexSession(context: fixture.context) { _ in }
        try await duplicate.initialize()
        let response = line(#"{"id":0,"result":{}}"#)
        try await duplicate.receive(response)
        do {
            try await duplicate.receive(response)
            XCTFail("duplicate response was accepted")
        } catch RelayCodexSessionError.duplicateResponseID {
            // Expected.
        }
    }

    func testInterruptTargetsExactRunningTurnAndInvalidatesApproval()
        async throws
    {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }
        let sink = ByteSink()
        let session = RelayCodexSession(context: fixture.context) { bytes in
            await sink.append(bytes)
        }
        let approvalTask = approvalRequest(from: session.events)
        try await prepareRunningSession(session)
        try await session.receive(commandApprovalLine(
            id: "approval-1",
            cwd: fixture.root.path
        ))
        let request = try await approvalTask.value
        try await session.interrupt()
        let sent = await sink.snapshot()
        let interruptRequest = try text(sent[sent.count - 1])

        XCTAssertTrue(interruptRequest.contains("turn/interrupt"))
        XCTAssertTrue(interruptRequest.contains("thread-a"))
        XCTAssertTrue(interruptRequest.contains("turn-a"))
        do {
            try await session.resolveApproval(
                request: request,
                token: RelayCodexDurableDecisionToken(
                    decision: grantedDecision(
                        context: fixture.context,
                        request: request
                    ),
                    request: request
                )
            )
            XCTFail("approval survived interrupt")
        } catch RelayCodexSessionError.unknownApproval {
            // Expected.
        }
    }

    private func prepareRunningSession(
        _ session: RelayCodexSession
    ) async throws {
        try await session.initialize()
        try await session.receive(line(#"{"id":0,"result":{}}"#))
        try await session.startThread()
        try await session.receive(line(
            #"{"id":1,"result":{"thread":{"id":"thread-a"}}}"#
        ))
        try await session.startTurn(
            prompt: "Implement",
            outputSchema: .object(["type": .string("object")])
        )
        try await session.receive(line(
            #"{"id":2,"result":{"turn":{"id":"turn-a"}}}"#
        ))
    }

    private func approvalRequest(
        from events: AsyncStream<RelayCodexSessionEvent>
    ) -> Task<RelayCodexApprovalRequest, Error> {
        Task {
            for await event in events {
                if case .approvalRequested(let request) = event {
                    return request
                }
            }
            throw RelayCodexSessionError.closed
        }
    }

    private func commandApprovalLine(
        id: String,
        itemID: String = "item-a",
        cwd: String
    ) -> Data {
        line(
            #"{"id":"\#(id)","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-a","turnId":"turn-a","itemId":"\#(itemID)","cwd":"\#(cwd)","command":"swift test","availableDecisions":["accept","decline"]}}"#
        )
    }

    private func grantedDecision(
        context: RelayCodexControlContext,
        request: RelayCodexApprovalRequest
    ) -> RelayDecision {
        RelayDecision(
            id: RelayDecisionID(),
            taskID: context.taskID,
            kind: .executeRepositoryCode,
            scope: request.durableDecisionScope,
            status: .granted,
            requestedAt: RelayInstant(rawValue: 1),
            decidedAt: RelayInstant(rawValue: 2),
            rationale: "Approved exact request."
        )
    }

    private func line(_ value: String) -> Data {
        Data((value + "\n").utf8)
    }

    private func text(_ data: Data) throws -> String {
        try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

private actor ByteSink {
    private var values: [Data] = []

    func append(_ value: Data) {
        values.append(value)
    }

    func snapshot() -> [Data] { values }
}
