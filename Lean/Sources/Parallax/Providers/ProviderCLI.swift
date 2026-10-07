import AppKit
import Foundation

enum ProviderError: LocalizedError, Equatable {
    case toolMissing(String)
    case signedOut
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing(let name): "The \(name) command-line tool isn't installed."
        case .signedOut: "Signed out. Sign in again to read usage."
        case .timedOut: "The provider didn't answer in time."
        case .failed(let message): message
        }
    }
}

struct CLIResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

/// Runs the official provider CLIs (`claude`, `codex`) with a minimal environment.
enum ProviderCLI {
    static func locate(_ name: String) -> URL? {
        let home = NSHomeDirectory()
        let directories = [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "\(home)/.npm-global/bin", "\(home)/.bun/bin",
        ]
        return directories
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func environment(adding extra: [String: String]) -> [String: String] {
        let home = NSHomeDirectory()
        var environment = [
            "HOME": home,
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
        ]
        environment.merge(extra) { _, new in new }
        return environment
    }

    /// Runs a tool to completion, keeping stdout and stderr separately.
    static func run(
        _ tool: String,
        _ arguments: [String],
        environment extra: [String: String],
        timeout: TimeInterval
    ) async throws -> CLIResult {
        guard let executable = locate(tool) else { throw ProviderError.toolMissing(tool) }
        let box = ProcessBox()
        let process = box.process
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment(adding: extra)
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let out = LockedData()
        let err = LockedData()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { out.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { err.append(chunk) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLIResult, Error>) in
                let once = Once()
                box.process.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    // Give the pipes a moment to deliver their last bytes.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        if once.claim() {
                            continuation.resume(returning: CLIResult(status: status, stdout: out.value, stderr: err.value))
                        }
                    }
                }
                do {
                    try box.process.run()
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard box.process.isRunning else { return }
                    if once.claim() { continuation.resume(throwing: ProviderError.timedOut) }
                    box.stop()
                }
            }
        } onCancel: {
            box.stop()
        }
    }

    /// Opens a provider sign-in page, accepting only the provider's own https hosts.
    @MainActor
    static func openSignInPage(_ text: String, allowedHosts: [String]) -> Bool {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased(),
              allowedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// Owns a `Process` so it can be handed to the escaping callbacks above.
final class ProcessBox: @unchecked Sendable {
    let process = Process()

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
