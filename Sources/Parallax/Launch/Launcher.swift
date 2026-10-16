import AppKit
import Foundation

enum LaunchError: LocalizedError {
    case appMissing(String)
    case appChanged(String)
    case reusedExistingInstance(String)
    case keychainSecret
    case alreadyRunning(String)
    case invalidSetting(String)

    var errorDescription: String? {
        switch self {
        case .appMissing(let name): "\(name) isn't at its saved location. Choose the app again from its page."
        case .appChanged(let name): "The app at \(name)'s saved location is a different app."
        case .reusedExistingInstance(let name):
            "\(name) switched to a window that was already open instead of starting a separate instance, so this space isn't isolated. Quit \(name) and try again."
        case .alreadyRunning(let name): "\(name) is already open. Quit it, then continue the chat again."
        case .invalidSetting(let problem): "\(problem) Fix it in Edit Space."
        case .keychainSecret: "This space uses a Keychain secret from the old Parallax. Replace it with a value in Edit Space."
        }
    }
}

@MainActor
enum Launcher {
    /// Checks saved launch settings without creating folders or starting the app.
    static func validate(app: ManagedApp, plan: LaunchPlan) throws -> URL {
        let appURL = URL(fileURLWithPath: app.path).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: appURL.path) else { throw LaunchError.appMissing(app.name) }
        if let expected = app.bundleID, Bundle(url: appURL)?.bundleIdentifier != expected {
            throw LaunchError.appChanged(app.name)
        }
        if plan.environment.values.contains(where: { $0.hasPrefix("{{keychain:") }) { throw LaunchError.keychainSecret }
        return appURL
    }

    /// Opens one instance. `continueURL` is handed to the app on launch (Claude chat handoff).
    static func open(app: ManagedApp, plan: LaunchPlan, continueURL: URL? = nil) async throws -> NSRunningApplication {
        let appURL = try validate(app: app, plan: plan)
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
            if let bundleID = app.bundleID, let runningID = running.bundleIdentifier { return bundleID == runningID }
            return running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == path
        }
    }

    static func instancesOutsideSpaces(of app: ManagedApp) -> [NSRunningApplication] {
        runningInstances(of: app).filter {
            isOutsideSpaces(ProcessArguments.arguments(of: $0.processIdentifier), kind: app.kind)
        }
    }

    static func isOutsideSpaces(_ arguments: [String]?, kind: AppKind) -> Bool {
        guard let arguments else { return false }
        return folderArguments(arguments, kind: kind).isEmpty
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

    static func folderArguments(_ arguments: [String], kind: AppKind) -> [String] {
        let options = kind == .firefox ? ["-profile", "--profile"] : LaunchPlanner.userDataOptions
        return arguments.optionValue(options).map { [$0] } ?? []
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

enum ProcessArguments {
    static func arguments(of pid: pid_t) -> [String]? { read(pid)?.arguments }

    static func read(_ pid: pid_t) -> (arguments: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(Array(buffer.prefix(size)))
    }

    static func parse(_ buffer: [UInt8]) -> (arguments: [String], environment: [String: String])? {
        guard buffer.count > 4 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= buffer.count else { return nil }
        var index = 4
        func string() -> String? {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            guard index < buffer.count else { return nil }
            defer { index += 1 }
            return String(bytes: buffer[start..<index], encoding: .utf8)
        }
        guard string() != nil else { return nil } // executable path
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let value = string() else { return nil }
            arguments.append(value)
        }
        var environment: [String: String] = [:]
        while index < buffer.count, let value = string(), !value.isEmpty {
            guard let equals = value.firstIndex(of: "=") else { continue }
            let key = String(value[..<equals])
            if environment[key] == nil { environment[key] = String(value[value.index(after: equals)...]) }
        }
        return (arguments, environment)
    }
}
