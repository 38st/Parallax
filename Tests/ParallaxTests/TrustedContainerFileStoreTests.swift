import Darwin
import Foundation
import XCTest
@testable import Parallax

final class TrustedContainerFileStoreTests: XCTestCase {
    func testCapabilityStoreReadsReplacesAndQuarantinesDescriptorRelatively()
        throws
    {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let store = TrustedContainerFileStore(container: capability)

        XCTAssertEqual(
            try store.read(named: "state.json", maximumBytes: 64),
            .missing
        )
        try store.replace(Data("{\"value\":1}".utf8), named: "state.json")
        XCTAssertEqual(
            try store.read(named: "state.json", maximumBytes: 64),
            .bytes(Data("{\"value\":1}".utf8))
        )

        XCTAssertThrowsError(
            try store.read(named: "state.json", maximumBytes: 2)
        ) { error in
            guard case TrustedContainerFileStoreError.inputTooLarge = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let residual = try store.quarantine(
            named: "state.json",
            as: "state.corrupt.json"
        )
        XCTAssertEqual(
            residual,
            TrustedContainerFileResidual(
                name: "state.json",
                reason: .retainedQuarantineSource
            )
        )
        XCTAssertEqual(
            try store.read(named: "state.json", maximumBytes: 64),
            .bytes(Data("{\"value\":1}".utf8))
        )
        XCTAssertEqual(
            try store.read(named: "state.corrupt.json", maximumBytes: 64),
            .bytes(Data("{\"value\":1}".utf8))
        )
        XCTAssertEqual(
            try store.quarantine(
                named: "state.json",
                as: "state.corrupt.json"
            ),
            residual
        )
    }

    func testExistingMismatchedQuarantineEvidenceFailsClosed() throws {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let store = TrustedContainerFileStore(container: capability)
        let source = Data("complete-source".utf8)
        let partialEvidence = Data("partial".utf8)
        try store.replace(source, named: "state.json")
        let evidence = capability.url.appendingPathComponent("corrupt.json")
        try partialEvidence.write(to: evidence)
        XCTAssertEqual(chmod(evidence.path, 0o600), 0)

        XCTAssertThrowsError(
            try store.quarantine(
                named: "state.json",
                as: "corrupt.json"
            )
        ) { error in
            XCTAssertEqual(
                error as? TrustedContainerFileStoreError,
                .quarantineEvidenceMismatch(name: "corrupt.json")
            )
        }
        XCTAssertEqual(
            try store.read(named: "state.json", maximumBytes: 64),
            .bytes(source)
        )
        XCTAssertEqual(try Data(contentsOf: evidence), partialEvidence)
    }

    func testNewQuarantineRejectsInPlaceSourceRewriteAfterCopy() throws {
        try assertQuarantineRejectsInPlaceRewrite(
            existingEvidence: false,
            rewriteEvidence: false
        )
    }

    func testNewQuarantineRejectsInPlaceEvidenceRewriteAfterCopy() throws {
        try assertQuarantineRejectsInPlaceRewrite(
            existingEvidence: false,
            rewriteEvidence: true
        )
    }

    func testIdempotentQuarantineRejectsInPlaceSourceRewrite() throws {
        try assertQuarantineRejectsInPlaceRewrite(
            existingEvidence: true,
            rewriteEvidence: false
        )
    }

    func testIdempotentQuarantineRejectsInPlaceEvidenceRewrite() throws {
        try assertQuarantineRejectsInPlaceRewrite(
            existingEvidence: true,
            rewriteEvidence: true
        )
    }

    func testStoreRejectsSymbolicLinkLeafWithoutReadingTarget() throws {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let target = support.appendingPathComponent("outside.json")
        let bytes = Data("secret".utf8)
        try bytes.write(to: target)
        let leaf = capability.url.appendingPathComponent("state.json")
        XCTAssertEqual(symlink(target.path, leaf.path), 0)

        XCTAssertThrowsError(
            try TrustedContainerFileStore(container: capability).read(
                named: "state.json",
                maximumBytes: 64
            )
        )
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testLockPathReplacementFailsPostflight() throws {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let store = TrustedContainerFileStore(container: capability)
        let lock = capability.url.appendingPathComponent(".state.lock")
        let displaced = capability.url.appendingPathComponent(
            ".state.lock.displaced"
        )

        XCTAssertThrowsError(
            try store.withExclusiveLock(named: ".state.lock") {
                try FileManager.default.moveItem(at: lock, to: displaced)
                try Data().write(to: lock)
            }
        ) { error in
            guard case TrustedContainerFileStoreError.unsafeItem = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMissingDestinationRaceNeverOverwritesRacer() throws {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let destination = capability.url.appendingPathComponent("state.json")
        let racer = Data("racer".utf8)
        let store = TrustedContainerFileStore(
            container: capability,
            boundaryHook: { boundary in
                guard boundary == .beforeReplace else { return }
                try racer.write(to: destination)
                XCTAssertEqual(chmod(destination.path, 0o600), 0)
            }
        )

        XCTAssertThrowsError(
            try store.replace(
                Data("target".utf8),
                named: "state.json",
                temporaryName: ".fixed-temp"
            )
        )
        XCTAssertEqual(try Data(contentsOf: destination), racer)
        XCTAssertEqual(
            try Data(
                contentsOf: capability.url
                    .appendingPathComponent(".fixed-temp")
            ),
            Data("target".utf8)
        )
    }

    func testManyReplacementsReuseOneBoundedBackupAndLock() throws {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let store = TrustedContainerFileStore(container: capability)

        for value in 0..<100 {
            try store.replace(
                Data("value-\(value)".utf8),
                named: "state.json"
            )
        }

        XCTAssertEqual(
            try store.read(named: "state.json", maximumBytes: 64),
            .bytes(Data("value-99".utf8))
        )
        XCTAssertEqual(
            Set(
                try FileManager.default.contentsOfDirectory(
                    atPath: capability.url.path
                )
            ),
            [
                "state.json",
                ".state.json.replace",
                ".state.json.replace.lock"
            ]
        )
        XCTAssertEqual(
            try Data(
                contentsOf: capability.url.appendingPathComponent(
                    ".state.json.replace"
                )
            ),
            Data("value-98".utf8)
        )
    }

    func testReusableStagingRacePreservesRacerAndPublishedDestination()
        throws
    {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let baseStore = TrustedContainerFileStore(container: capability)
        try baseStore.replace(Data("value-1".utf8), named: "state.json")
        try baseStore.replace(Data("value-2".utf8), named: "state.json")
        let staging = capability.url.appendingPathComponent(
            ".state.json.replace"
        )
        let captured = capability.url.appendingPathComponent("captured.json")
        let decoy = Data("decoy".utf8)
        let racingStore = TrustedContainerFileStore(
            container: capability,
            boundaryHook: { boundary in
                guard boundary == .afterTemporaryCreation else { return }
                try FileManager.default.moveItem(at: staging, to: captured)
                try decoy.write(to: staging)
                XCTAssertEqual(chmod(staging.path, 0o600), 0)
            }
        )

        XCTAssertThrowsError(
            try racingStore.replace(
                Data("value-3".utf8),
                named: "state.json"
            )
        )
        XCTAssertEqual(
            try Data(
                contentsOf: capability.url.appendingPathComponent(
                    "state.json"
                )
            ),
            Data("value-2".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: staging), decoy)
        XCTAssertEqual(try Data(contentsOf: captured), Data("value-3".utf8))
    }

    func testExistingDestinationRacePreservesBothObjects() throws {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let destination = capability.url.appendingPathComponent("state.json")
        let saved = capability.url.appendingPathComponent("saved.json")
        let original = Data("original".utf8)
        let racer = Data("racer".utf8)
        try TrustedContainerFileStore(container: capability).replace(
            original,
            named: "state.json"
        )
        let racingStore = TrustedContainerFileStore(
            container: capability,
            boundaryHook: { boundary in
                guard boundary == .beforeReplace else { return }
                try FileManager.default.moveItem(at: destination, to: saved)
                try racer.write(to: destination)
                XCTAssertEqual(chmod(destination.path, 0o600), 0)
            }
        )

        XCTAssertThrowsError(
            try racingStore.replace(
                Data("target".utf8),
                named: "state.json",
                temporaryName: ".fixed-temp"
            )
        )
        XCTAssertEqual(try Data(contentsOf: destination), racer)
        XCTAssertEqual(try Data(contentsOf: saved), original)
    }

    func testFailureCleanupDoesNotUnlinkReplacedTemporaryPath() throws {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let temporary = capability.url.appendingPathComponent(".fixed-temp")
        let captured = capability.url.appendingPathComponent("captured-temp")
        let decoy = Data("decoy".utf8)
        let store = TrustedContainerFileStore(
            container: capability,
            boundaryHook: { boundary in
                guard boundary == .afterTemporaryCreation else { return }
                try FileManager.default.moveItem(at: temporary, to: captured)
                try decoy.write(to: temporary)
                XCTAssertEqual(chmod(temporary.path, 0o600), 0)
            }
        )

        XCTAssertThrowsError(
            try store.replace(
                Data("target".utf8),
                named: "state.json",
                temporaryName: ".fixed-temp"
            )
        )
        XCTAssertEqual(try Data(contentsOf: temporary), decoy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captured.path))
    }

    func testExistingSwapMismatchLeavesEveryRacedObjectInPlace() throws {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let destination = capability.url.appendingPathComponent("state.json")
        let temporary = capability.url.appendingPathComponent(".fixed-temp")
        let savedOriginal = capability.url.appendingPathComponent("saved.json")
        let original = Data("original".utf8)
        let decoy = Data("decoy".utf8)
        try TrustedContainerFileStore(container: capability).replace(
            original,
            named: "state.json"
        )
        let store = TrustedContainerFileStore(
            container: capability,
            boundaryHook: { boundary in
                guard boundary == .afterReplace else { return }
                try FileManager.default.moveItem(
                    at: temporary,
                    to: savedOriginal
                )
                try decoy.write(to: temporary)
                XCTAssertEqual(chmod(temporary.path, 0o600), 0)
            }
        )

        XCTAssertThrowsError(
            try store.replace(
                Data("target".utf8),
                named: "state.json",
                temporaryName: ".fixed-temp"
            )
        )
        XCTAssertEqual(try Data(contentsOf: destination), Data("target".utf8))
        XCTAssertEqual(try Data(contentsOf: savedOriginal), original)
        XCTAssertEqual(try Data(contentsOf: temporary), decoy)
    }

    func testQuarantineSourceRaceFailsBeforeCreatingEvidenceDestination()
        throws
    {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let source = capability.url.appendingPathComponent("state.json")
        let saved = capability.url.appendingPathComponent("saved.json")
        let destination = capability.url.appendingPathComponent("corrupt.json")
        let original = Data("original".utf8)
        let racer = Data("racer".utf8)
        try TrustedContainerFileStore(container: capability).replace(
            original,
            named: "state.json"
        )
        let store = TrustedContainerFileStore(
            container: capability,
            boundaryHook: { boundary in
                guard boundary == .beforeQuarantine else { return }
                try FileManager.default.moveItem(at: source, to: saved)
                try racer.write(to: source)
                XCTAssertEqual(chmod(source.path, 0o600), 0)
            }
        )

        XCTAssertThrowsError(
            try store.quarantine(
                named: "state.json",
                as: "corrupt.json"
            )
        ) { error in
            guard case TrustedContainerFileStoreError.changedDuringRead = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), racer)
        XCTAssertEqual(try Data(contentsOf: saved), original)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path)
        )
    }

    func testQuarantinePostflightMismatchPreservesEveryObservedObject()
        throws
    {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let source = capability.url.appendingPathComponent("state.json")
        let destination = capability.url.appendingPathComponent("corrupt.json")
        let saved = capability.url.appendingPathComponent("saved.json")
        let original = Data("original".utf8)
        let decoy = Data("decoy".utf8)
        try TrustedContainerFileStore(container: capability).replace(
            original,
            named: "state.json"
        )
        let store = TrustedContainerFileStore(
            container: capability,
            boundaryHook: { boundary in
                guard boundary == .afterQuarantine else { return }
                try FileManager.default.moveItem(at: destination, to: saved)
                try decoy.write(to: destination)
                XCTAssertEqual(chmod(destination.path, 0o600), 0)
            }
        )

        XCTAssertThrowsError(
            try store.quarantine(named: "state.json", as: "corrupt.json")
        )
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: saved), original)
        XCTAssertEqual(try Data(contentsOf: destination), decoy)
    }

    func testCompatibilityEstablishmentAcceptsSymlinkedAncestorOnly()
        throws
    {
        let fixture = try temporaryDirectory()
        let actualParent = fixture.appendingPathComponent("actual")
        try FileManager.default.createDirectory(
            at: actualParent,
            withIntermediateDirectories: false
        )
        let alias = fixture.appendingPathComponent("alias")
        XCTAssertEqual(symlink(actualParent.path, alias.path), 0)
        let requestedSupport = alias.appendingPathComponent("Support")

        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: requestedSupport
        )
        try capability.validate()
        let bytes = Data("{}".utf8)
        let store = TrustedContainerFileStore(container: capability)
        try store.replace(bytes, named: "state.json")
        XCTAssertEqual(
            try store.read(named: "state.json", maximumBytes: 16),
            .bytes(bytes)
        )
    }

    func testCapabilityFailsClosedAfterContainerPathReplacement() throws {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let original = capability.url
        let displaced = support.appendingPathComponent("Parallax.displaced")
        try FileManager.default.moveItem(at: original, to: displaced)
        try FileManager.default.createDirectory(
            at: original,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(chmod(original.path, 0o700), 0)

        XCTAssertThrowsError(
            try TrustedContainerFileStore(container: capability).read(
                named: "state.json",
                maximumBytes: 64
            )
        ) { error in
            guard case TrustedParallaxContainerError
                .containerIdentityChanged = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMutationAuthorityAdoptsCapabilityThatSurvivesLeaseCleanup()
        throws
    {
        let container = try temporaryDirectory().appendingPathComponent(
            TrustedParallaxContainer.directoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(chmod(container.path, 0o700), 0)
        let mutationLock = SettingsPrimaryMutationLock(
            trustedContainerURL: container
        )

        let adopted = try mutationLock.withMutationLock { authority in
            try authority.adoptTrustedContainer()
        }
        let store = TrustedContainerFileStore(container: adopted)
        let bytes = Data("{}".utf8)
        try store.replace(bytes, named: "shared.json")
        XCTAssertEqual(
            try store.read(named: "shared.json", maximumBytes: 16),
            .bytes(bytes)
        )
    }

    @MainActor
    func testCapabilityBackedStoresFailClosedAfterContainerReplacement()
        throws
    {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let history = try LaunchHistoryStore(trustedContainer: capability)
        let workarounds = try ManagedAppWorkaroundStore(
            trustedContainer: capability
        )
        let recovery = try ManagedAppRecoveryLedger(
            trustedContainer: capability
        )
        let displaced = support.appendingPathComponent("Parallax.displaced")
        try FileManager.default.moveItem(at: capability.url, to: displaced)
        try FileManager.default.createDirectory(
            at: capability.url,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(chmod(capability.url.path, 0o700), 0)

        history.refreshFromDisk()
        XCTAssertNotNil(history.persistenceErrorMessage)
        XCTAssertFalse(
            workarounds.upsert(
                ManagedAppWorkaroundRecord(
                    applicationStorageID: UUID(),
                    profileStorageID: UUID(),
                    workaroundID: "test.workaround",
                    displayName: "Test workaround",
                    definitionVersion: 1,
                    configurationReference: "test.reference",
                    state: .verified,
                    updatedAt: Date(),
                    operatorNote: nil
                )
            )
        )
        XCTAssertThrowsError(
            try recovery.decision(
                for: ManagedAppRecoveryKey(
                    applicationStorageID: UUID(),
                    profileStorageID: UUID()
                ),
                confirmedCrashAt: Date()
            )
        )
    }

    private func assertQuarantineRejectsInPlaceRewrite(
        existingEvidence: Bool,
        rewriteEvidence: Bool
    ) throws {
        let support = try temporaryDirectory()
        let capability = try TrustedParallaxContainer.establish(
            applicationSupportURL: support
        )
        let source = capability.url.appendingPathComponent("state.json")
        let evidence = capability.url.appendingPathComponent("corrupt.json")
        let original = Data("original".utf8)
        let mutation = Data("mutated!".utf8)
        let baseStore = TrustedContainerFileStore(container: capability)
        try baseStore.replace(original, named: "state.json")
        if existingEvidence {
            _ = try baseStore.quarantine(
                named: "state.json",
                as: "corrupt.json"
            )
        }
        let racingStore = TrustedContainerFileStore(
            container: capability,
            boundaryHook: { boundary in
                guard boundary == .afterQuarantine else { return }
                try rewriteTestFileInPlace(
                    mutation,
                    at: rewriteEvidence ? evidence : source
                )
            }
        )

        XCTAssertThrowsError(
            try racingStore.quarantine(
                named: "state.json",
                as: "corrupt.json"
            )
        ) { error in
            guard case TrustedContainerFileStoreError.changedDuringRead = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try Data(contentsOf: source),
            rewriteEvidence ? original : mutation
        )
        XCTAssertEqual(
            try Data(contentsOf: evidence),
            rewriteEvidence ? mutation : original
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "parallax-trusted-container-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private func rewriteTestFileInPlace(_ data: Data, at url: URL) throws {
    let descriptor = open(url.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { close(descriptor) }
    try data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(
                descriptor,
                base.advanced(by: offset),
                buffer.count - offset
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(count < 0 ? errno : EIO)
                )
            }
            offset += count
        }
    }
    guard fsync(descriptor) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
