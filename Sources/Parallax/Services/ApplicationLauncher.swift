import AppKit
import Foundation

protocol ApplicationLaunching {
    func launch(application: ManagedApplication, profile: LaunchProfile, completion: @escaping @Sendable (Result<Void, Error>) -> Void) throws
}

enum LaunchError: LocalizedError {
    case missingApplication(String)

    var errorDescription: String? {
        switch self {
        case .missingApplication(let path):
            "The application could not be found at \(path)."
        }
    }
}

struct WorkspaceApplicationLauncher: ApplicationLaunching {
    func launch(application: ManagedApplication, profile: LaunchProfile, completion: @escaping @Sendable (Result<Void, Error>) -> Void) throws {
        let url = URL(fileURLWithPath: application.appPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LaunchError.missingApplication(application.appPath)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = profile.arguments.map(Self.expandingTildeInArgument)

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in profile.environment {
            environment[key] = NSString(string: value).expandingTildeInPath
        }
        try Self.createKnownHomeDirectories(in: environment)
        configuration.environment = environment

        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    static func expandingTildeInArgument(_ argument: String) -> String {
        if argument.hasPrefix("~") {
            return NSString(string: argument).expandingTildeInPath
        }

        guard
            let separator = argument.firstIndex(of: "="),
            argument[argument.index(after: separator)...].hasPrefix("~")
        else {
            return argument
        }

        let key = argument[...separator]
        let valueStart = argument.index(after: separator)
        let value = String(argument[valueStart...])
        return String(key) + NSString(string: value).expandingTildeInPath
    }

    static func createKnownHomeDirectories(in environment: [String: String]) throws {
        guard let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty else { return }
        try FileManager.default.createDirectory(
            atPath: codexHome,
            withIntermediateDirectories: true
        )
    }
}
