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
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(
               url: resources.appendingPathComponent(
                   bundleName,
                   isDirectory: true
               )
           )
        {
            return packaged
        }
        return .module
    }

    static func verify(
        bundle: Bundle? = nil
    ) throws {
        let bundle = bundle ?? self.bundle
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

private extension InputStream {
    func openAndCanReadOneByte() -> Bool {
        open()
        defer { close() }
        var byte: UInt8 = 0
        return read(&byte, maxLength: 1) == 1
    }
}
