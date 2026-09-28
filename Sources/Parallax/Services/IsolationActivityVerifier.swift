import Darwin
import Foundation

enum IsolationFolderActivity: Equatable, Sendable {
    case active
    case inactive
    case unknown
}

/// Reads metadata only. Symlinks and mounted volumes are never traversed, and
/// an incomplete inspection cannot establish that the app ignored its folder.
struct IsolationActivityScanner: Sendable {
    var maximumEntries = 10_000
    var maximumDepth = 32
    var timeBudget: Duration = .milliseconds(250)
    var monotonicNow: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }

    func activity(in folder: URL, since began: Date) -> IsolationFolderActivity {
        guard maximumEntries > 0,
              let root = openFolder(folder)
        else { return .unknown }
        defer { close(root.descriptor) }
        var remaining = maximumEntries
        let deadline = monotonicNow().advanced(by: timeBudget)
        return inspect(
            descriptor: root.descriptor, device: root.device,
            since: began, remaining: &remaining, depth: 0, deadline: deadline
        )
    }

    private func openFolder(_ folder: URL) -> (descriptor: Int32, device: dev_t)? {
        guard folder.isFileURL else { return nil }
        var requested = stat()
        guard lstat(folder.path, &requested) == 0, requested.st_mode & S_IFMT == S_IFDIR,
              let canonical = realpath(folder.path, nil) else { return nil }
        defer { free(canonical) }
        let descriptor = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == requested.st_dev, opened.st_ino == requested.st_ino else {
            close(descriptor)
            return nil
        }
        return (descriptor, opened.st_dev)
    }

    private func inspect(
        descriptor: Int32, device: dev_t, since began: Date,
        remaining: inout Int, depth: Int, deadline: ContinuousClock.Instant
    ) -> IsolationFolderActivity {
        guard !Task.isCancelled, remaining > 0, depth <= maximumDepth,
              monotonicNow() < deadline else { return .unknown }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_dev == device else { return .unknown }
        if modified(status, since: began) { return .active }
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { return .unknown }
        guard let directory = fdopendir(duplicate) else {
            close(duplicate)
            return .unknown
        }
        defer { closedir(directory) }
        var incomplete = false
        while true {
            guard !Task.isCancelled, remaining > 0, monotonicNow() < deadline else { return .unknown }
            errno = 0
            guard let entry = readdir(directory) else {
                return errno == 0 && !incomplete ? .inactive : .unknown
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            remaining -= 1
            var childStatus = stat()
            guard fstatat(descriptor, name, &childStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
                incomplete = true
                continue
            }
            guard childStatus.st_dev == device else {
                incomplete = true
                continue
            }
            switch childStatus.st_mode & S_IFMT {
            case S_IFREG:
                if modified(childStatus, since: began) { return .active }
            case S_IFDIR:
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard child >= 0 else {
                    incomplete = true
                    continue
                }
                let result = inspect(descriptor: child, device: device, since: began,
                                     remaining: &remaining, depth: depth + 1, deadline: deadline)
                close(child)
                if result == .active { return .active }
                if result == .unknown { incomplete = true }
            default:
                break
            }
        }
    }

    private func modified(_ status: stat, since began: Date) -> Bool {
        let modified = TimeInterval(status.st_mtimespec.tv_sec)
            + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        return modified > began.timeIntervalSince1970
    }
}

protocol IsolationVerificationClock: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

struct SystemIsolationVerificationClock: IsolationVerificationClock {
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

struct IsolationActivityVerifier: Sendable {
    var clock: any IsolationVerificationClock = SystemIsolationVerificationClock()
    var scanner = IsolationActivityScanner()

    func verify(
        paths: [LaunchIsolationPath], since began: Date,
        report: @escaping @Sendable (IsolationFolderActivity) async -> Void
    ) async {
        var pending = Set(paths.compactMap { $0.isManaged ? $0.url : nil })
        guard !pending.isEmpty else { return }
        for _ in 0..<2 {
            do { try await clock.sleep(seconds: 30) } catch { return }
            guard !Task.isCancelled else { return }
            let folders = pending
            let scanner = scanner
            let task = Task.detached(priority: .utility) {
                folders.map { ($0, scanner.activity(in: $0, since: began)) }
            }
            let results = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled else { return }
            for (folder, activity) in results where activity == .active {
                pending.remove(folder)
            }
            let state: IsolationFolderActivity = pending.isEmpty ? .active
                : results.contains(where: { $0.1 == .inactive }) ? .inactive : .unknown
            await report(state)
            if pending.isEmpty { return }
        }
    }
}
