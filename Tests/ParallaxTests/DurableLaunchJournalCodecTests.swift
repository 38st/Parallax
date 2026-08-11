import Foundation
import XCTest
@testable import Parallax

final class DurableLaunchJournalCodecTests: XCTestCase {
    func testReadPlanAndMaterializationPreferCompletionOverOtherMarkers()
        throws
    {
        let fixture = try makeFixture()
        let completion = try fixture.codec.encodeCompletion(
            requestID: fixture.requestID,
            completion: .terminated
        )
        let names: Set<String> = [
            fixture.request.name,
            "opening.json",
            "process.json",
            completion.name,
        ]

        XCTAssertEqual(
            fixture.codec.requiredFileNames(in: names),
            [fixture.request.name, completion.name]
        )
        let artifact = fixture.codec.materialize(
            fixture.snapshot(
                presentNames: names,
                namedData: [
                    fixture.request.name: .bytes(fixture.request.data),
                    "opening.json": .unreadable,
                    "process.json": .unreadable,
                    completion.name: .bytes(completion.data),
                ]
            )
        )

        guard case .completed = artifact.state else {
            return XCTFail("Expected completion to take precedence")
        }
        XCTAssertEqual(artifact.requestID, fixture.requestID)
        XCTAssertEqual(artifact.identity, fixture.identity)
    }

    func testMaterializationPrefersProcessOverUnreadableOpening() throws {
        let fixture = try makeFixture()
        let process = ProcessStartIdentity(
            processIdentifier: 7_201,
            startTimeSeconds: 800,
            startTimeMicroseconds: 9
        )
        let processFile = try fixture.codec.encodeProcess(
            requestID: fixture.requestID,
            process: process
        )
        let names: Set<String> = [
            fixture.request.name,
            "opening.json",
            processFile.name,
        ]

        XCTAssertEqual(
            fixture.codec.requiredFileNames(in: names),
            [fixture.request.name, processFile.name]
        )
        let artifact = fixture.codec.materialize(
            fixture.snapshot(
                presentNames: names,
                namedData: [
                    fixture.request.name: .bytes(fixture.request.data),
                    "opening.json": .unreadable,
                    processFile.name: .bytes(processFile.data),
                ]
            )
        )

        guard case .running(let materialized) = artifact.state else {
            return XCTFail("Expected running process")
        }
        XCTAssertEqual(materialized, process)
    }

    func testMarkerIdentityMismatchIsCorruptButRetainsRequestEvidence()
        throws
    {
        let fixture = try makeFixture()
        let opening = try fixture.codec.encodeOpening(requestID: UUID())
        let artifact = fixture.codec.materialize(
            fixture.snapshot(
                presentNames: [fixture.request.name, opening.name],
                namedData: [
                    fixture.request.name: .bytes(fixture.request.data),
                    opening.name: .bytes(opening.data),
                ]
            )
        )

        guard case .corrupt = artifact.state else {
            return XCTFail("Expected corrupt marker identity")
        }
        XCTAssertEqual(artifact.requestID, fixture.requestID)
        XCTAssertEqual(artifact.identity, fixture.identity)
    }

    func testRequestDirectoryIdentityMismatchIsCorruptWithoutRequestEvidence()
        throws
    {
        let fixture = try makeFixture()
        let artifact = fixture.codec.materialize(
            DurableLaunchJournalCodec.Snapshot(
                directoryName: UUID().uuidString.lowercased(),
                directoryURL: fixture.directoryURL,
                presentNames: [fixture.request.name],
                namedData: [
                    fixture.request.name: .bytes(fixture.request.data)
                ]
            )
        )

        guard case .corrupt = artifact.state else {
            return XCTFail("Expected corrupt request identity")
        }
        XCTAssertNil(artifact.requestID)
        XCTAssertNil(artifact.identity)
    }

    private func makeFixture() throws -> Fixture {
        let codec = DurableLaunchJournalCodec()
        let requestID = UUID()
        let identity = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID()
        )
        let request = try codec.encodeRequest(
            requestID: requestID,
            identity: identity,
            ownerProcess: ProcessStartIdentity(
                processIdentifier: 7_200,
                startTimeSeconds: 700,
                startTimeMicroseconds: 8
            )
        )
        return Fixture(
            codec: codec,
            requestID: requestID,
            identity: identity,
            request: request,
            directoryURL: URL(fileURLWithPath: "/journal")
                .appendingPathComponent(requestID.uuidString.lowercased())
        )
    }
}

private struct Fixture {
    let codec: DurableLaunchJournalCodec
    let requestID: UUID
    let identity: ProfileActivityIdentity
    let request: DurableLaunchJournalCodec.EncodedFile
    let directoryURL: URL

    func snapshot(
        presentNames: Set<String>,
        namedData: [String: DurableLaunchJournalCodec.NamedData]
    ) -> DurableLaunchJournalCodec.Snapshot {
        DurableLaunchJournalCodec.Snapshot(
            directoryName: requestID.uuidString.lowercased(),
            directoryURL: directoryURL,
            presentNames: presentNames,
            namedData: namedData
        )
    }
}
