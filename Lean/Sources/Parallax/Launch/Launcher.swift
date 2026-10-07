import AppKit
import Foundation

enum LaunchError: LocalizedError {
    case appMissing(String)
    case appChanged(String)
    case reusedExistingInstance(String)
    case keychainSecret

    var errorDescription: String? {
        switch self {
        case .appMissing(let name): "\(name) isn't at its saved location. Choose the app again from its page."
        case .appChanged(let name): "The app at \(name)'s saved location is a different app."
        case .reusedExistingInstance(let name):
            "\(name) switched to a window that was already open instead of starting a separate instance, so this space isn't isolated. Quit \(name) and try again."
        case .keychainSecret: "This space uses a Keychain secret from the old Parallax. Replace it with a value in Edit Space."
        }
    }
}

@MainActor
enum Launcher {
    /// Opens one instance. `continueURL` is handed to the app on launch (Claude chat handoff).
    static func open(app: ManagedApp, plan: LaunchPlan, continueURL: URL? = nil) async throws -> NSRunningApplication {
        let appURL = URL(fileURLWithPath: app.path).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: appURL.path) else { throw LaunchError.appMissing(app.name) }
        if let expected = app.bundleID, Bundle(url: appURL)?.bundleIdentifier != expected {
            throw LaunchError.appChanged(app.name)
        }
        if plan.environment.values.contains(where: { $0.hasPrefix("{{keychain:") }) { throw LaunchError.keychainSecret }
        for folder in plan.folders {
            try FileManager.default.createDirectory(
                atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }

        let before = Set(runningInstances(of: app).map(\.processIdentifier))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = plan.arguments
        configuration.environment = plan.environment
        configuration.createsNewApplicationInstance = plan.newInstance
        configuration.activates = true

        let running: NSRunningApplication
        if let continueURL {
            running = try await NSWorkspace.shared.open([continueURL], withApplicationAt: appURL, configuration: configuration)
        } else {
            running = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }
        if plan.newInstance && before.contains(running.processIdentifier) {
            throw LaunchError.reusedExistingInstance(app.name)
        }
        return running
    }

    static func runningInstances(of app: ManagedApp) -> [NSRunningApplication] {
        let path = URL(fileURLWithPath: app.path).resolvingSymlinksInPath().standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.filter { running in
            guard !running.isTerminated else { return false }
            if let bundleID = app.bundleID, running.bundleIdentifier == bundleID { return true }
            return running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == path
        }
    }

    /// Matches running instances back to spaces by the data folder in their arguments.
    static func discoverRunningSpaces(apps: [ManagedApp]) -> [UUID: NSRunningApplication] {
        var found: [UUID: NSRunningApplication] = [:]
        for app in apps where app.kind != .other {
            let markers = app.spaces.compactMap { space in
                LaunchPlanner.isolationMarker(app: app, space: space).map { (space.id, normalized($0)) }
            }
            guard !markers.isEmpty else { continue }
            for running in runningInstances(of: app) {
                guard let arguments = ProcessArguments.arguments(of: running.processIdentifier) else { continue }
                let folders = folderArguments(arguments, kind: app.kind).map(normalized)
                if let match = markers.first(where: { folders.contains($0.1) }) { found[match.0] = running }
            }
        }
        return found
    }

    private static func folderArguments(_ arguments: [String], kind: AppKind) -> [String] {
        var result: [String] = []
        for (index, word) in arguments.enumerated() {
            for option in LaunchPlanner.userDataOptions where word.hasPrefix(option + "=") {
                result.append(String(word.dropFirst(option.count + 1)))
            }
            if LaunchPlanner.userDataOptions.contains(word) || (kind == .firefox && word == "-profile"),
               index + 1 < arguments.count {
                result.append(arguments[index + 1])
            }
        }
        return result
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

enum ProcessArguments {
    /// The argv of a process owned by this user, read with `KERN_PROCARGS2`.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
