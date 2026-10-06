import Foundation

enum PackagedRuntimeResourceError: LocalizedError, Equatable {
    case missing(String)
    case unreadable(String)
    case unsupportedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name):
            String(
                localized:
                    "The packaged runtime resource “\(name)” is missing."
            )
        case .unsupportedLanguage(let name):
            String(localized: "This build contains unsupported language resources: \(name). Rebuild Parallax with English only.")
        case .unreadable(let name):
            String(
                localized:
                    "The packaged runtime resource “\(name)” is unreadable."
            )
        }
    }
}

enum PackagedRuntimeResources {
    static let smokeTestArgument = "--resource-smoke-test"
    static let bundleName = "Parallax_Parallax.bundle"

    static var bundle: Bundle {
        resolveBundle() ?? .main
    }

    static func resolveBundle(
        mainBundle: Bundle = .main,
        developmentDirectories: [URL]? = nil
    ) -> Bundle? {
        if let resources = mainBundle.resourceURL,
           let packaged = Bundle(
               url: resources.appendingPathComponent(
                   bundleName,
                   isDirectory: true
               )
           )
        {
            return packaged
        }
        guard mainBundle.bundleURL.pathExtension.lowercased() != "app",
              mainBundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String != "APPL"
        else { return nil }
        let directories = developmentDirectories ?? [
            mainBundle.bundleURL,
            Bundle(for: RuntimeResourceBundleMarker.self).resourceURL,
            Bundle(for: RuntimeResourceBundleMarker.self).bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }
        for directory in directories {
            if let candidate = Bundle(url: directory.appendingPathComponent(bundleName)) {
                return candidate
            }
        }
        return nil
    }

    static func verify(
        bundle: Bundle? = nil
    ) throws {
        guard let bundle = bundle ?? resolveBundle() else {
            throw PackagedRuntimeResourceError.missing(bundleName)
        }
        let requiredResources: [(name: String, url: URL?)] = [
            (
                "AppIcon.icns",
                bundle.url(
                    forResource: "AppIcon",
                    withExtension: "icns"
                )
            ),
            (
                "en.lproj/Localizable.strings",
                bundle.url(forResource: "Localizable", withExtension: "strings",
                           subdirectory: nil, localization: "en")
            ),
            (
                "en.lproj/Localizable.stringsdict",
                bundle.url(
                    forResource: "Localizable",
                    withExtension: "stringsdict",
                    subdirectory: nil,
                    localization: "en"
                )
            ),
        ]
        for resource in requiredResources {
            guard let url = resource.url else {
                throw PackagedRuntimeResourceError.missing(
                    resource.name
                )
            }
            guard
                let stream = InputStream(url: url),
                stream.openAndCanReadOneByte()
            else {
                throw PackagedRuntimeResourceError.unreadable(
                    resource.name
                )
            }
        }
        var languages = Set(bundle.localizations)
        if let root = bundle.resourceURL {
            let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            languages.formUnion(entries.filter { $0.pathExtension == "lproj" }.map { $0.deletingPathExtension().lastPathComponent })
        }
        for language in languages.sorted() where language != "en" {
            throw PackagedRuntimeResourceError.unsupportedLanguage(language)
        }
    }
}

private final class RuntimeResourceBundleMarker {}

private extension InputStream {
    func openAndCanReadOneByte() -> Bool {
        open()
        defer { close() }
        var byte: UInt8 = 0
        return read(&byte, maxLength: 1) == 1
    }
}
