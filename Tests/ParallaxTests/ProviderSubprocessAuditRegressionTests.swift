import AppKit
import Darwin
import Foundation
import XCTest

@testable import Parallax

final class ProviderSubprocessAuditRegressionTests: XCTestCase {
    func testCancellationStopsTheProviderProcessGroup() throws {
        let (root, executable) = try fixture(
            """
            #!/bin/sh
            trap '' TERM
            /bin/sh -c 'trap "" TERM; while :; do :; done' &
            printf '%s' "$!" > "$CODEX_HOME/grandchild"
            while :; do :; done
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let childFile = root.appendingPathComponent("grandchild")
        defer {
            if let text = try? String(contentsOf: childFile, encoding: .utf8), let pid = pid_t(text)
            {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        XCTAssertThrowsError(
            try ProviderProcessRunner.run(
                executable: executable, arguments: [], environment: ["CODEX_HOME": root.path],
                timeout: 5,
                cancellationCheck: { FileManager.default.fileExists(atPath: childFile.path) }
            )
        ) { XCTAssertEqual($0 as? ProviderProcessFailure, .cancelled) }
        let pid = try XCTUnwrap(pid_t(String(contentsOf: childFile, encoding: .utf8)))
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let deadline = ProviderDeadline(after: 2)
        var exited = false
        repeat {
            let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
            exited = count == 0 || info.pbi_status == 5
            if exited { break }
            Thread.sleep(forTimeInterval: 0.01)
        } while !deadline.hasExpired
        XCTAssertTrue(exited, "Grandchild must stop within the bounded reap period")
    }

    func testSuccessCollectsAllOutputWrittenImmediatelyBeforeExit() throws {
        let (root, executable) = try fixture(
            """
            #!/bin/sh
            i=0
            while [ "$i" -lt 2000 ]; do
              printf 'final-output-%s\\n' "$i"
              printf 'final-error-%s\\n' "$i" >&2
              i=$((i + 1))
            done
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try ProviderProcessRunner.run(
            executable: executable, arguments: [], environment: [:], timeout: 10)
        XCTAssertEqual(
            result.output, (0..<2000).map { "final-output-\($0)" }.joined(separator: "\n"))
        XCTAssertEqual(
            result.errorOutput, (0..<2000).map { "final-error-\($0)" }.joined(separator: "\n"))
    }

    func testExitedParentCannotLeavePipeDrainWithoutDeadline() throws {
        let (root, executable) = try fixture(
            """
            #!/bin/sh
            /bin/sh -c 'trap "" TERM; while :; do :; done' &
            printf '%s' "$!" > "$CODEX_HOME/grandchild"
            printf 'collected output'
            printf 'collected error' >&2
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let childFile = root.appendingPathComponent("grandchild")
        defer {
            if let text = try? String(contentsOf: childFile, encoding: .utf8), let pid = pid_t(text)
            {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        let result = try ProviderProcessRunner.run(
            executable: executable, arguments: [], environment: ["CODEX_HOME": root.path],
            timeout: 2)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "collected output")
        XCTAssertEqual(result.errorOutput, "collected error")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)

    }

    @MainActor
    func testQuitRegistryReapsChildrenAndRefusesNewSpawns() throws {
        let (root, executable) = try fixture("#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderProcessRegistry()
        let process = Process()
        let waiter = ProviderProcessTerminationWaiter()
        process.executableURL = try executable.revalidatedURL()
        waiter.install(on: process)
        try registry.start(process, waiter: waiter)
        defer { registry.remove(process) }
        XCTAssertEqual(getpgid(process.processIdentifier), process.processIdentifier)
        registry.terminateAll()
        XCTAssertFalse(process.isRunning)
        var status: Int32 = 0
        let waitResult = waitpid(process.processIdentifier, &status, WNOHANG)
        let waitError = errno
        XCTAssertEqual(waitResult, -1)
        XCTAssertEqual(waitError, ECHILD)
        let late = Process()
        late.executableURL = try executable.revalidatedURL()
        XCTAssertThrowsError(try registry.start(late, waiter: ProviderProcessTerminationWaiter())) {
            XCTAssertEqual($0 as? ProviderProcessFailure, .cancelled)
        }
        XCTAssertEqual(late.processIdentifier, 0)
    }

    func testReaderFinishWaitsForOutputAlreadyReadByHandler() throws {
        let pipe = Pipe()
        let handlerEntered = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        let finishEntered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        let collector = ProviderProcessOutputCollector()
        let reader = ProviderPipeReader(handle: pipe.fileHandleForReading) { data in
            handlerEntered.signal()
            _ = releaseHandler.wait(timeout: .now() + 5)
            collector.append(data)
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("final response".utf8))
        try pipe.fileHandleForWriting.close()
        DispatchQueue.global().async {
            reader.drain()
            drained.signal()
        }
        XCTAssertEqual(handlerEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            finishEntered.signal()
            reader.finish()
            finished.signal()
        }
        XCTAssertEqual(finishEntered.wait(timeout: .now() + 2), .success)
        // Hold delivery after the bytes left the pipe. Teardown must wait for
        // that handler, even though a separate final read would see only EOF.
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        releaseHandler.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(drained.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(collector.string(), "final response")
    }

    @MainActor
    func testTerminationNotificationDoesNotPoisonOtherServiceRegistries() throws {
        let (root, executable) = try fixture("#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "RegistryAudit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ProviderProcessRegistry()
        let service = LiveCorporateAccountOperationService(processRegistry: registry)
        let coordinator = CorporateAccountOperationCoordinator(
            store: CorporateUsageStore(userDefaults: defaults, initialAccounts: []),
            service: service)
        coordinator.startAutomaticRefresh(initialDelay: 300)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertThrowsError(
            try ProviderProcessRunner.run(
                executable: executable, arguments: [], environment: [:], timeout: 2,
                registry: registry)
        ) {
            XCTAssertEqual($0 as? ProviderProcessFailure, .cancelled)
        }
        let freshService = LiveCorporateAccountOperationService()
        XCTAssertEqual(
            try ProviderProcessRunner.run(
                executable: executable, arguments: [], environment: [:], timeout: 2,
                registry: freshService.processRegistry
            ).status, 0)
        XCTAssertEqual(
            try ProviderProcessRunner.run(
                executable: executable, arguments: [], environment: [:], timeout: 2
            ).status, 0)
    }

    private func fixture(_ script: String) throws -> (URL, TrustedProviderExecutable) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProviderSubprocessAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("provider")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return (
            root,
            try ProviderExecutableLocator(currentUserID: getuid(), fixedDirectories: [root]).locate(
                named: "provider")
        )
    }
}
