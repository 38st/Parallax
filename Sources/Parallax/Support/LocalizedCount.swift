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
            locale: Locale(identifier: "en")
        )
        return formatted(count, format: format, locale: Locale(identifier: "en"))
    }

    static func profiles(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = String(
            localized: "profile-count",
            defaultValue: "%lld profiles",
            bundle: localizedBundle(for: locale),
            locale: Locale(identifier: "en")
        )
        return formatted(count, format: format, locale: Locale(identifier: "en"))
    }

    static func spaces(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = String(
            localized: "space-count",
            defaultValue: "%lld spaces",
            bundle: localizedBundle(for: locale),
            locale: Locale(identifier: "en")
        )
        return formatted(count, format: format, locale: Locale(identifier: "en"))
    }

    static func profileConfigurations(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = String(
            localized: "profile-configuration-count",
            defaultValue: "%lld profile configurations",
            bundle: localizedBundle(for: locale),
            locale: Locale(identifier: "en")
        )
        return formatted(count, format: format, locale: Locale(identifier: "en"))
    }

    static func launchArguments(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = String(
            localized: "launch-argument-count",
            defaultValue: "%lld launch arguments",
            bundle: localizedBundle(for: locale),
            locale: Locale(identifier: "en")
        )
        return formatted(count, format: format, locale: Locale(identifier: "en"))
    }

    /// "1 account" / "N accounts" (`account-count`).
    static func accounts(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = String(
            localized: "account-count",
            defaultValue: "%lld accounts",
            bundle: localizedBundle(for: locale),
            locale: Locale(identifier: "en")
        )
        return formatted(count, format: format, locale: Locale(identifier: "en"))
    }

    /// "1 account tracked" / "N accounts tracked" (`tracked-account-count`).
    static func trackedAccounts(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = String(
            localized: "tracked-account-count",
            defaultValue: "%lld accounts tracked",
            bundle: localizedBundle(for: locale),
            locale: Locale(identifier: "en")
        )
        return formatted(count, format: format, locale: Locale(identifier: "en"))
    }

    static func environmentOperations(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = String(
            localized: "environment-operation-count",
            defaultValue: "%lld environment operations",
            bundle: localizedBundle(for: locale),
            locale: Locale(identifier: "en")
        )
        return formatted(count, format: format, locale: Locale(identifier: "en"))
    }

    private static func formatted(
        _ count: Int,
        format: String,
        locale: Locale
    ) -> String {
        return String(
            format: format,
            locale: Locale(identifier: "en"),
            arguments: [Int64(count)]
        )
    }

    private static func localizedBundle(
        for locale: Locale
    ) -> Bundle {
        guard
            let path = PackagedRuntimeResources.bundle.path(
                forResource: "en",
                ofType: "lproj"
            ),
            let bundle = Bundle(path: path)
        else {
            return PackagedRuntimeResources.bundle
        }
        return bundle
    }
}
