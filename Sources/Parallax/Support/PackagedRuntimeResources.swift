import Foundation

enum PackagedRuntimeResourceError: LocalizedError, Equatable {
    case missing(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name):
            String(
                localized:
                    "The packaged runtime resource “\(name)” is missing."
            )
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
                "en.lproj/Localizable.stringsdict",
                bundle.url(
                    forResource: "Localizable",
                    withExtension: "stringsdict",
                    subdirectory: nil,
                    localization: "en"
                )
            ),
            (
                "es.lproj/Localizable.stringsdict",
                bundle.url(
                    forResource: "Localizable",
                    withExtension: "stringsdict",
                    subdirectory: nil,
                    localization: "es"
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
