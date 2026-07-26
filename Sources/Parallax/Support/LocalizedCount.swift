import Foundation

enum LocalizedCount {
    static func applications(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = String(
            localized: "application-count",
            defaultValue: "%lld applications",
            bundle: localizedBundle(for: locale),
            locale: locale
        )
        return formatted(count, format: format, locale: locale)
    }

    static func profiles(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = String(
            localized: "profile-count",
            defaultValue: "%lld profiles",
            bundle: localizedBundle(for: locale),
            locale: locale
        )
        return formatted(count, format: format, locale: locale)
    }

    static func profileConfigurations(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = String(
            localized: "profile-configuration-count",
            defaultValue: "%lld profile configurations",
            bundle: localizedBundle(for: locale),
            locale: locale
        )
        return formatted(count, format: format, locale: locale)
    }

    static func launchArguments(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = String(
            localized: "launch-argument-count",
            defaultValue: "%lld launch arguments",
            bundle: localizedBundle(for: locale),
            locale: locale
        )
        return formatted(count, format: format, locale: locale)
    }

    static func environmentOperations(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = String(
            localized: "environment-operation-count",
            defaultValue: "%lld environment operations",
            bundle: localizedBundle(for: locale),
            locale: locale
        )
        return formatted(count, format: format, locale: locale)
    }

    private static func formatted(
        _ count: Int,
        format: String,
        locale: Locale
    ) -> String {
        return String(
            format: format,
            locale: locale,
            arguments: [Int64(count)]
        )
    }

    private static func localizedBundle(
        for locale: Locale
    ) -> Bundle {
        let language = locale.identifier
            .split(whereSeparator: {
                $0 == "-" || $0 == "_"
            })
            .first
            .map(String.init)
        guard
            let language,
            let path = PackagedRuntimeResources.bundle.path(
                forResource: language,
                ofType: "lproj"
            ),
            let bundle = Bundle(path: path)
        else {
            return PackagedRuntimeResources.bundle
        }
        return bundle
    }
}
