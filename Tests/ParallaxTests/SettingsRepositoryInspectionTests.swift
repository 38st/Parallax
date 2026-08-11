import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Parallax

final class SettingsRepositoryTests: XCTestCase {
    func testFakeMissingAndUnavailableRemainExplicitAndReadOnly() {
        let missing = FakeSettingsPrimaryFileAccess(.success(.missing))
        XCTAssertEqual(
            SettingsRepository(primaryFileAccess: missing).inspect(),
            .missing
        )
        XCTAssertEqual(
            missing.maximums,
            [SettingsRepository.maximumPrimaryBytes]
        )

        let failure = SettingsPrimaryFileAccessError.systemCall(
            operation: "fixture",
            code: EIO
        )
        let unavailable = FakeSettingsPrimaryFileAccess(.failure(failure))
        XCTAssertEqual(
            SettingsRepository(primaryFileAccess: unavailable).inspect(),
            .unavailable(.primaryFile(failure))
        )
        XCTAssertEqual(unavailable.maximums.count, 1)
    }

    func testCurrentSnapshotRetainsExactBytesHashAndRevision() throws {
        let document = makeDocument(revision: 42)
        let bytes = try SettingsDocumentCodec().encode(document)
        let access = FakeSettingsPrimaryFileAccess(.success(.bytes(bytes)))

        guard case let .current(snapshot) =
            SettingsRepository(primaryFileAccess: access).inspect()
        else {
            return XCTFail("Expected current settings.")
        }
        XCTAssertEqual(snapshot.document, document)
        XCTAssertEqual(snapshot.originalBytes, bytes)
        XCTAssertEqual(
            snapshot.versionToken.revision,
            SettingsRevision(rawValue: 42)
        )
        XCTAssertEqual(
            snapshot.versionToken.sourceSHA256.hex,
            sha256(bytes)
        )
    }

    func testFutureAndInvalidRetainExactEvidenceWithoutFallback() {
        let futureBytes = Data(
            #" { "schemaVersion" : 2, "future" : true } "#.utf8
        )
        guard case let .future(version, evidence) =
            SettingsRepository(
                primaryFileAccess: FakeSettingsPrimaryFileAccess(
                    .success(.bytes(futureBytes))
                )
            ).inspect()
        else {
            return XCTFail("Expected future settings.")
        }
        XCTAssertEqual(version, 2)
        XCTAssertEqual(evidence.originalBytes, futureBytes)
        XCTAssertEqual(evidence.sourceSHA256.hex, sha256(futureBytes))

        let invalidBytes = Data(#"{"schemaVersion":1}"#.utf8)
        guard case let .recoveryRequired(failure, digest) =
            SettingsRepository(
                primaryFileAccess: FakeSettingsPrimaryFileAccess(
                    .success(.bytes(invalidBytes))
                )
            ).inspect()
        else {
            return XCTFail("Expected recovery-required settings.")
        }
        XCTAssertEqual(failure.originalBytes, invalidBytes)
        XCTAssertEqual(digest.hex, sha256(invalidBytes))
    }

    func testRepositoryAlwaysDelegatesExactFourMiBMaximum() {
        for result in [
            Result<SettingsPrimaryFileReadResult, SettingsPrimaryFileAccessError>
                .success(.missing),
            .failure(.systemCall(operation: "fixture", code: EMFILE)),
        ] {
            let access = FakeSettingsPrimaryFileAccess(result)
            _ = SettingsRepository(primaryFileAccess: access).inspect()
            XCTAssertEqual(
                access.maximums,
                [4 * 1_024 * 1_024]
            )
        }
    }

    private func makeDocument(revision: UInt64) -> SettingsDocument {
        SettingsDocument(
            revision: SettingsRevision(rawValue: revision),
            profileTemplates: [
                .init(
                    id: "00000000-0000-4000-8000-000000000001",
                    name: "Work",
                    argumentsText: "--safe",
                    environmentText: "A=1",
                    notes: "Fixture"
                )
            ],
            defaultBaseStoragePath: "/Managed",
            confirmBeforeLaunch: true,
            automaticallyRecoverCrashedApps: false,
            appearance: "dark",
            profileVisualIdentities: []
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class FakeSettingsPrimaryFileAccess:
    SettingsPrimaryFileAccessing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let result:
        Result<SettingsPrimaryFileReadResult, SettingsPrimaryFileAccessError>
    private var storedMaximums: [Int] = []

    init(
        _ result:
            Result<
                SettingsPrimaryFileReadResult,
                SettingsPrimaryFileAccessError
            >
    ) {
        self.result = result
    }

    var maximums: [Int] {
        lock.withLock { storedMaximums }
    }

    func read(
        maximumBytes: Int
    ) -> Result<SettingsPrimaryFileReadResult, SettingsPrimaryFileAccessError> {
        lock.withLock {
            storedMaximums.append(maximumBytes)
        }
        return result
    }
}
