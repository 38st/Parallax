import Foundation

enum PortableConfigurationSanitizerAdapter {
    static func library(
        _ library: LibraryDocument,
        policy: SensitiveLiteralExportPolicy
    ) throws -> LibraryDocument {
        var applications = library.applications
        for applicationIndex in applications.indices {
            for profileIndex in applications[applicationIndex].profiles.indices {
                var profile =
                    applications[applicationIndex].profiles[profileIndex]
                profile.argumentsText = try argumentsText(
                    profile.argumentsText,
                    policy: policy,
                    owner:
                        "\(applications[applicationIndex].displayName) / \(profile.name)"
                )
                profile.environmentText = try environmentText(
                    profile.environmentText,
                    explicitSensitiveKeys:
                        Set(profile.sensitiveEnvironmentKeys),
                    policy: policy,
                    owner:
                        "\(applications[applicationIndex].displayName) / \(profile.name)"
                )
                applications[applicationIndex].profiles[profileIndex] =
                    profile
            }
        }
        return LibraryDocument(
            revision: library.revision,
            applications: applications
        )
    }

    static func settings(
        _ settings: PortableSettingsSnapshot,
        policy: SensitiveLiteralExportPolicy
    ) throws -> PortableSettingsSnapshot {
        let templates = try settings.profileTemplates.map { template in
            PortableProfileTemplate(
                id: template.id,
                name: template.name,
                argumentsText: try argumentsText(
                    template.argumentsText,
                    policy: policy,
                    owner: "Template / \(template.name)"
                ),
                environmentText: try environmentText(
                    template.environmentText,
                    explicitSensitiveKeys: [],
                    policy: policy,
                    owner: "Template / \(template.name)"
                ),
                notes: template.notes
            )
        }
        return PortableSettingsSnapshot(
            portableProfileTemplates: templates,
            defaultBaseStoragePath: settings.defaultBaseStoragePath,
            confirmBeforeLaunch: settings.confirmBeforeLaunch,
            appearance: settings.appearance
        )
    }

    private static func environmentText(
        _ text: String,
        explicitSensitiveKeys: Set<String>,
        policy: SensitiveLiteralExportPolicy,
        owner: String
    ) throws -> String {
        do {
            return try SensitiveConfigurationTextSanitizer()
                .sanitizeEnvironment(
                    text,
                    explicitSensitiveKeys: explicitSensitiveKeys,
                    policy: textSanitizationPolicy(for: policy)
                ).text
        } catch {
            throw PortableConfigurationError.invalidEnvironment(
                owner: owner
            )
        }
    }

    private static func argumentsText(
        _ text: String,
        policy: SensitiveLiteralExportPolicy,
        owner: String
    ) throws -> String {
        do {
            return try SensitiveConfigurationTextSanitizer()
                .sanitizeArguments(
                    text,
                    policy: textSanitizationPolicy(for: policy)
                ).text
        } catch {
            throw PortableConfigurationError.invalidArguments(
                owner: owner
            )
        }
    }

    private static func textSanitizationPolicy(
        for policy: SensitiveLiteralExportPolicy
    ) -> SensitiveConfigurationTextSanitizationPolicy {
        switch policy {
        case .omit:
            .omit
        case .redact:
            .redact
        case .includeAfterExplicitConfirmation:
            .includeAfterExplicitConfirmation
        }
    }
}
