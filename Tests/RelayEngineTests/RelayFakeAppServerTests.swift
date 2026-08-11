import Foundation
import RelayEngine
import XCTest

final class RelayFakeAppServerTests: XCTestCase {
    func testFragmentedRequestsProduceCanonicalCorrelatedFrames() throws {
        let server = RelayFakeAppServer(steps: [
            RelayFakeAppServerStep(
                method: "initialize",
                id: .exact(1),
                outputs: [
                    .result(.object(["ready": .bool(true)])),
                    .notification(
                        method: "relay/progress",
                        params: .object(["sequence": .number(1)])
                    ),
                ]
            ),
            RelayFakeAppServerStep(
                method: "initialized",
                id: .absent
            ),
        ])

        XCTAssertEqual(
            try server.receive(Data(#"{"id":1,"method":"init"# .utf8)),
            []
        )
        let response = try server.receive(Data(#"ialize","params":{}}"#.utf8) + Data([0x0A]))
        XCTAssertEqual(response.count, 2)
        XCTAssertEqual(
            String(decoding: response[0], as: UTF8.self),
            #"{"id":1,"result":{"ready":true}}"# + "\n"
        )
        XCTAssertEqual(
            String(decoding: response[1], as: UTF8.self),
            #"{"method":"relay/progress","params":{"sequence":1}}"# + "\n"
        )
        var productionDecoder = RelayJSONLDecoder()
        let decoded = try productionDecoder.append(response.reduce(into: Data()) {
            $0.append($1)
        })
        XCTAssertEqual(decoded.count, 2)
        XCTAssertTrue(decoded[0].isResponse)
        XCTAssertEqual(decoded[1].method, "relay/progress")

        XCTAssertEqual(
            try server.receive(Data(#"{"method":"initialized"}"#.utf8) + Data([0x0A])),
            []
        )
        XCTAssertEqual(server.transcript.count, 2)
        XCTAssertEqual(server.unconsumedStepCount, 0)
        try server.finishInput()
    }

    func testMismatchedRequestDoesNotConsumeScriptedStep() throws {
        let server = RelayFakeAppServer(steps: [
            RelayFakeAppServerStep(method: "thread/start", id: .exact(7)),
        ])

        XCTAssertThrowsError(
            try server.receive(Data(#"{"id":8,"method":"thread/start"}"#.utf8) + Data([0x0A]))
        ) { error in
            XCTAssertEqual(
                error as? RelayFakeAppServerError,
                .unexpectedID(expected: .exact(7), actual: 8)
            )
        }
        XCTAssertEqual(server.unconsumedStepCount, 1)
        XCTAssertEqual(server.transcript, [])
    }

    func testCloseAndMalformedOutputAreExplicitFaults() throws {
        let closingServer = RelayFakeAppServer(steps: [
            RelayFakeAppServerStep(
                method: "thread/start",
                id: .exact(3),
                outputs: [.error(code: -32_000, message: "fixture failure")],
                closesAfterOutput: true
            ),
        ])
        let frames = try closingServer.receive(
            Data(#"{"id":3,"method":"thread/start"}"#.utf8) + Data([0x0A])
        )
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(closingServer.isClosed)
        XCTAssertThrowsError(try closingServer.receive(Data("{}\n".utf8))) {
            XCTAssertEqual($0 as? RelayFakeAppServerError, .closed)
        }

        let malformedServer = RelayFakeAppServer(steps: [
            RelayFakeAppServerStep(
                method: "thread/start",
                id: .exact(4),
                outputs: [.rawLine(Data("not-json".utf8))]
            ),
        ])
        let malformedFrames = try malformedServer.receive(
            Data(#"{"id":4,"method":"thread/start"}"#.utf8) + Data([0x0A])
        )
        var decoder = RelayJSONLDecoder()
        XCTAssertThrowsError(try decoder.append(try XCTUnwrap(malformedFrames.first))) {
            XCTAssertEqual(
                $0 as? RelayCodexProtocolError,
                .malformedMessage
            )
        }
    }

    func testBooleanAndFractionalIDsDoNotSatisfyExactExpectation() {
        for invalidID in ["true", "1.5", "1e100"] {
            let server = RelayFakeAppServer(steps: [
                RelayFakeAppServerStep(method: "fixture", id: .exact(1)),
            ])
            XCTAssertThrowsError(
                try server.receive(
                    Data("{\"id\":\(invalidID),\"method\":\"fixture\"}\n".utf8)
                )
            ) { error in
                XCTAssertEqual(
                    error as? RelayFakeAppServerError,
                    .unexpectedID(expected: .exact(1), actual: nil)
                )
            }
        }
    }
}
