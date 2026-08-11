import Foundation

/// Typed application-domain representation of a current settings document.
/// Wire spelling, ordering, revisions, and schema concerns remain owned by
/// `SettingsDocument` and `SettingsDocumentCodec`.
struct SettingsState: Equatable, Sendable {
    enum MappingError: Error, Equatable, Sendable {
        case unsupportedSchema(UInt64)
        case invalidTemplateID(String)
        case duplicateTemplateID(UUID)
        case invalidAppearance(String)
        case invalidVisualProfileID(String)
        case duplicateVisualProfileID(UUID)
        case invalidVisualSymbol(String)
        case invalidVisualColor(String)
    }

    let profileTemplates: [ProfileTemplate]
    let defaultBaseStoragePath: String
    let confirmBeforeLaunch: Bool
    let automaticallyRecoverCrashedApps: Bool
    let appearance: AppAppearance
    let profileVisualIdentities: [UUID: ProfileInstanceVisualIdentity]

    static let defaults = SettingsState(
        profileTemplates: ProfileTemplate.defaults,
        defaultBaseStoragePath: "",
        confirmBeforeLaunch: false,
        automaticallyRecoverCrashedApps: true,
        appearance: .system,
        profileVisualIdentities: [:]
    )

    init(
        profileTemplates: [ProfileTemplate],
        defaultBaseStoragePath: String,
        confirmBeforeLaunch: Bool,
        automaticallyRecoverCrashedApps: Bool,
        appearance: AppAppearance,
        profileVisualIdentities: [
            UUID: ProfileInstanceVisualIdentity
        ]
    ) {
        self.profileTemplates = profileTemplates
        self.defaultBaseStoragePath = defaultBaseStoragePath
        self.confirmBeforeLaunch = confirmBeforeLaunch
        self.automaticallyRecoverCrashedApps =
            automaticallyRecoverCrashedApps
        self.appearance = appearance
        self.profileVisualIdentities = profileVisualIdentities
    }

    init(document: SettingsDocument) throws {
        guard document.schemaVersion == SettingsDocument.currentSchemaVersion
        else {
            throw MappingError.unsupportedSchema(document.schemaVersion)
        }

        var templateIDs = Set<UUID>()
        var templates: [ProfileTemplate] = []
        templates.reserveCapacity(document.profileTemplates.count)
        for wire in document.profileTemplates {
            guard let id = UUID(uuidString: wire.id) else {
                throw MappingError.invalidTemplateID(wire.id)
            }
            guard templateIDs.insert(id).inserted else {
                throw MappingError.duplicateTemplateID(id)
            }
            templates.append(
                ProfileTemplate(
                    id: id,
                    name: wire.name,
                    argumentsText: wire.argumentsText,
                    environmentText: wire.environmentText,
                    notes: wire.notes
                )
            )
        }

        guard let appearance = AppAppearance(rawValue: document.appearance)
        else {
            throw MappingError.invalidAppearance(document.appearance)
        }

        var visuals: [UUID: ProfileInstanceVisualIdentity] = [:]
        visuals.reserveCapacity(document.profileVisualIdentities.count)
        for wire in document.profileVisualIdentities {
            guard let profileID = UUID(uuidString: wire.profileID) else {
                throw MappingError.invalidVisualProfileID(wire.profileID)
            }
            guard visuals[profileID] == nil else {
                throw MappingError.duplicateVisualProfileID(profileID)
            }
            guard let symbol = ProfileInstanceVisualSymbol(
                rawValue: wire.symbol
            ) else {
                throw MappingError.invalidVisualSymbol(wire.symbol)
            }
            guard let color = ProfileInstanceVisualColor(
                rawValue: wire.color
            ) else {
                throw MappingError.invalidVisualColor(wire.color)
            }
            visuals[profileID] = ProfileInstanceVisualIdentity(
                symbol: symbol,
                color: color
            )
        }

        self.init(
            profileTemplates: templates,
            defaultBaseStoragePath: document.defaultBaseStoragePath,
            confirmBeforeLaunch: document.confirmBeforeLaunch,
            automaticallyRecoverCrashedApps:
                document.automaticallyRecoverCrashedApps,
            appearance: appearance,
            profileVisualIdentities: visuals
        )
    }

    func document(revision: SettingsRevision) -> SettingsDocument {
        SettingsDocument(
            revision: revision,
            profileTemplates: profileTemplates.map { template in
                SettingsDocument.Template(
                    id: template.id.uuidString.lowercased(),
                    name: template.name,
                    argumentsText: template.argumentsText,
                    environmentText: template.environmentText,
                    notes: template.notes
                )
            },
            defaultBaseStoragePath: defaultBaseStoragePath,
            confirmBeforeLaunch: confirmBeforeLaunch,
            automaticallyRecoverCrashedApps:
                automaticallyRecoverCrashedApps,
            appearance: appearance.rawValue,
            profileVisualIdentities: profileVisualIdentities
                .sorted {
                    $0.key.uuidString.lowercased()
                        < $1.key.uuidString.lowercased()
                }
                .map { profileID, identity in
                    SettingsDocument.VisualIdentity(
                        profileID: profileID.uuidString.lowercased(),
                        symbol: identity.symbol.rawValue,
                        color: identity.color.rawValue
                    )
                }
        )
    }
}
