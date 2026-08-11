import Darwin
import XCTest
@testable import Parallax

final class SettingsDescriptorCloseTests: XCTestCase {
    func testDescriptorSamplesEvidenceThenAlwaysReallyCloses() throws {
        let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var observedOpen = false

        let outcome = SettingsDescriptorClose.descriptor(descriptor) {
            observedOpen = fcntl(descriptor, F_GETFD) >= 0
            return EIO
        }

        let closedResult = fcntl(descriptor, F_GETFD)
        let closedError = errno
        XCTAssertTrue(observedOpen)
        XCTAssertEqual(outcome, .failure(code: EIO))
        XCTAssertEqual(closedResult, -1)
        XCTAssertEqual(closedError, EBADF)
    }

    func testInjectedEvidenceTakesPrecedenceOverRealCloseFailure() {
        var injected = false

        let outcome = SettingsDescriptorClose.descriptor(-1) {
            injected = true
            return ENOSPC
        }

        XCTAssertTrue(injected)
        XCTAssertEqual(outcome, .failure(code: ENOSPC))
    }

    func testRealCloseFailureIsRetainedWithoutInjectedEvidence() {
        XCTAssertEqual(
            SettingsDescriptorClose.descriptor(-1) { nil },
            .failure(code: EBADF)
        )
    }

    func testDirectoryStreamSamplesEvidenceThenAlwaysReallyCloses() throws {
        guard let stream = opendir("/private/tmp") else {
            throw POSIXError(.EIO)
        }
        let descriptor = dirfd(stream)
        var observedOpen = false

        let outcome = SettingsDescriptorClose.directoryStream(stream) {
            observedOpen = fcntl(descriptor, F_GETFD) >= 0
            return EIO
        }

        let closedResult = fcntl(descriptor, F_GETFD)
        let closedError = errno
        XCTAssertTrue(observedOpen)
        XCTAssertEqual(outcome, .failure(code: EIO))
        XCTAssertEqual(closedResult, -1)
        XCTAssertEqual(closedError, EBADF)
    }
}
