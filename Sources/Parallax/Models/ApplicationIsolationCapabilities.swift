import CoreFoundation
import Foundation

enum ApplicationMultipleInstancePolicy: Equatable, Sendable {
    case prohibited
    case notProhibited
    case unknown
}

struct ApplicationIsolationCapabilities: Equatable, Sendable {
    let preset: AppPreset
    let multipleInstancePolicy: ApplicationMultipleInstancePolicy

    static func readPolicy(
        at applicationURL: URL,
        fileSystem: any FileSystem = LocalFileSystem()
    ) -> ApplicationMultipleInstancePolicy {
        let url = applicationURL.appendingPathComponent("Contents/Info.plist")
        guard let attributes = try? fileSystem.attributesOfItem(at: url),
              attributes.kind == .regularFile,
              let size = attributes.size, size <= 1_048_576,
              let data = try? fileSystem.readData(at: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return .unknown }
        guard let value = plist["LSMultipleInstancesProhibited"] else { return .notProhibited }
        guard let boolean = value as? NSNumber,
              CFGetTypeID(boolean) == CFBooleanGetTypeID() else { return .unknown }
        return boolean.boolValue ? .prohibited : .notProhibited
    }

    var dataSummary: String { dataSummary(bundle: PackagedRuntimeResources.bundle) }
    var instanceSummary: String { instanceSummary(bundle: PackagedRuntimeResources.bundle) }

    func dataSummary(bundle: Bundle) -> String {
        switch preset {
        case .automatic, .custom:
            String(localized: "Data separation depends on the options you configure for this app.", bundle: bundle)
        case .codex:
            String(localized: "Applying the recommended settings adds CODEX_HOME and --user-data-dir folders for each space, when Codex honors those options.", bundle: bundle)
        case .claude:
            String(localized: "Claude spaces use --user-data-dir and CLAUDE_CONFIG_DIR folders when Claude honors those options. Parallax does not copy chats or credentials between spaces.", bundle: bundle)
        case .firefox:
            String(localized: "Applying the recommended settings adds a Firefox profile folder through -profile and enables -no-remote. Existing profile selections are preserved.", bundle: bundle)
        case .visualStudioCode:
            String(localized: "Applying the recommended settings adds --user-data-dir and --extensions-dir folders for each space, when the application honors those options.", bundle: bundle)
        case .electron:
            String(localized: "Applying the recommended settings adds an application data folder through --user-data-dir for each space, when the application honors that option.", bundle: bundle)
        case .chrome, .brave, .edge, .chromium:
            String(localized: "Applying the recommended settings adds a browser data folder through --user-data-dir for each space, when the application honors that option.", bundle: bundle)
        }
    }

    func instanceSummary(bundle: Bundle) -> String {
        switch multipleInstancePolicy {
        case .prohibited:
            return String(localized: "This app prohibits multiple instances. macOS may refuse to open a second copy.", bundle: bundle)
        case .unknown:
            return String(localized: "The app's multiple-instance policy could not be read. Running several copies is unverified.", bundle: bundle)
        case .notProhibited:
            if preset == .firefox {
                return String(localized: "Firefox supports running separate profiles at once with -no-remote. Each copy must use a different profile folder.", bundle: bundle)
            }
            if preset == .visualStudioCode {
                return String(localized: "Separate user-data folders support running copies side by side when this app honors the VS Code options.", bundle: bundle)
            }
            return String(localized: "Parallax requests a separate instance for each space. The app may still reuse an existing process, so running several copies is not guaranteed.", bundle: bundle)
        }
    }
}

struct ApplicationCapabilityPolicyState {
    private var applicationPath: String?
    private var value: ApplicationMultipleInstancePolicy?

    func policy(for path: String) -> ApplicationMultipleInstancePolicy? {
        applicationPath == path ? value : nil
    }

    mutating func record(_ policy: ApplicationMultipleInstancePolicy, for path: String) {
        applicationPath = path
        value = policy
    }
}
