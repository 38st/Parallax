import Darwin
import Foundation
import XCTest
@testable import Parallax

final class SettingsPublicationAuditRegressionTests: XCTestCase {
    func testCompareAndSwapPreservesReadFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        let document = SettingsState.defaults.document(revision: SettingsRevision(rawValue: 1))
        let bytes = try SettingsDocumentCodec().encode(document)
        let request = SettingsPrimaryPreparedPublication(
            prior: .missing, targetDocument: document, targetBytes: bytes,
            targetToken: SettingsVersionToken(revision: document.revision, sourceSHA256: SettingsSourceSHA256(bytes))
        )
        let error = SettingsPrimaryLockedInspectionError.fileAccess(
            .systemCall(operation: "audit read", code: EIO)
        )
        let result = SettingsPrimaryPublication().publish(request, settingsDescriptor: descriptor) {
            .failure(error)
        }
        guard case .failed(let evidence) = result else { return XCTFail("Expected failure") }
        XCTAssertEqual(evidence.failure, .lockedRead(error))
    }

    func testTrailingReadSystemFailureIsNotAByteMismatch() {
        XCTAssertThrowsError(try SettingsPrimaryPublication().exactDescriptorBytes(
            -1, expected: Data(),
            token: SettingsVersionToken(revision: .zero, sourceSHA256: SettingsSourceSHA256(Data()))
        )) { error in
            guard case .system(let failure) = error as? SettingsPrimaryPublicationFailure else {
                return XCTFail("Expected system failure: \(error)")
            }
            XCTAssertEqual(failure.code, EBADF)
        }
    }

    func testSettingsSystemErrorsLocalizeTheWholeMessage() {
        let runtime = SettingsRuntimeContainerFailure.systemCall(operation: "untranslated operation", code: EIO)
        let mutation = SettingsPrimaryMutationLockSystemFailure(operation: "untranslated operation", code: EIO)
        XCTAssertFalse(runtime.localizedDescription.contains("untranslated operation"))
        XCTAssertFalse(mutation.localizedSummary.contains("untranslated operation"))
        XCTAssertTrue(runtime.localizedDescription.contains(String(EIO)))
        XCTAssertTrue(mutation.localizedSummary.contains(String(EIO)))
    }

    func testExpectationRetryReadsUnderMutationLock() async throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: requested) }
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        guard let canonical = realpath(requested.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let writer = SettingsRepositoryWriter(mutationLock: SettingsPrimaryMutationLock(trustedContainerURL: root))
        guard case .committed(let initial, _) = writer.commit(
            SettingsContent(document: SettingsState.defaults.document(revision: .zero)), expecting: .missing
        ) else { return XCTFail("Expected initial commit") }
        let peerState = try SettingsMutation.setAppearance(.dark).applying(to: .defaults)
        guard case .committed = writer.commit(
            SettingsContent(document: peerState.document(revision: .zero)), expecting: .version(initial.versionToken)
        ) else { return XCTFail("Expected peer commit") }
        let probes = SettingsAuditLockProbe()
        let lockPath = root.appendingPathComponent("Settings/.settings.lock")
        let retryWriter = SettingsRepositoryWriter(mutationLock: SettingsPrimaryMutationLock(
            trustedContainerURL: root,
            boundaryHook: { boundary in
                guard boundary == .afterFlock else { return }
                let contender = open(lockPath.path, O_RDWR | O_CLOEXEC)
                XCTAssertGreaterThanOrEqual(contender, 0)
                guard contender >= 0 else { return }
                defer { close(contender) }
                XCTAssertEqual(flock(contender, LOCK_EX | LOCK_NB), -1)
                XCTAssertEqual(errno, EWOULDBLOCK)
                probes.increment()
            }
        ))
        let coordinator = SettingsMutationCoordinator(
            initialState: .defaults, initialSnapshot: initial, writer: retryWriter
        )
        let result = await coordinator.apply(.setConfirmBeforeLaunch(true))
        guard case .committed(let state, _) = result else { return XCTFail("Retry used unlocked inspection: \(result)") }
        XCTAssertEqual(state.appearance, .dark)
        XCTAssertTrue(state.confirmBeforeLaunch)
        XCTAssertEqual(probes.count, 3, "Rejected CAS, retry inspection, and successful CAS each hold the lock")
    }

}


private final class SettingsAuditLockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
