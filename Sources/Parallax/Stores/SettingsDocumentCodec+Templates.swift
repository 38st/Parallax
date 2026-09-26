import Foundation

extension SettingsDocumentCodec {
    func templateArray(
        _ value: SettingsStrictJSONParser.Value?,
        path: String
    ) throws -> [SettingsDocument.Template] {
        guard let value else {
            throw SettingsDocumentCodecIssue.missingKey(path: path)
        }
        guard case let .array(values) = value else {
            throw SettingsDocumentCodecIssue.invalidType(path: path)
        }
        var templates: [SettingsDocument.Template] = []
        templates.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            let itemPath = "\(path)[\(index)]"
            guard case let .object(object) = value else {
                throw SettingsDocumentCodecIssue.invalidType(
                    path: itemPath
                )
            }
            try exactKeys(
                object,
                allowed: [
                    "id",
                    "name",
                    "argumentsText",
                    "environmentText",
                    "notes",
                ],
                path: itemPath
            )
            templates.append(
                SettingsDocument.Template(
                    id: try string(
                        object[exact: "id"],
                        path: "\(itemPath).id",
                        maximum: 36
                    ),
                    name: try string(
                        object[exact: "name"],
                        path: "\(itemPath).name",
                        maximum: limits.maximumNameUTF8Bytes
                    ),
                    argumentsText: try string(
                        object[exact: "argumentsText"],
                        path: "\(itemPath).argumentsText",
                        maximum: limits.maximumTextUTF8Bytes
                    ),
                    environmentText: try string(
                        object[exact: "environmentText"],
                        path: "\(itemPath).environmentText",
                        maximum: limits.maximumTextUTF8Bytes
                    ),
                    notes: try string(
                        object[exact: "notes"],
                        path: "\(itemPath).notes",
                        maximum: limits.maximumTextUTF8Bytes
                    )
                )
            )
        }
        return try validateTemplates(templates, path: path)
    }

    func validateTemplates(
        _ templates: [SettingsDocument.Template],
        path: String
    ) throws -> [SettingsDocument.Template] {
        guard templates.count <= limits.maximumTemplates else {
            throw SettingsDocumentCodecIssue.tooManyItems(
                path: path,
                maximum: limits.maximumTemplates
            )
        }
        var ids = Set<UUID>()
        return try templates.enumerated().map { index, template in
            let itemPath = "\(path)[\(index)]"
            let id = try canonicalUUID(
                template.id,
                path: "\(itemPath).id"
            )
            guard ids.insert(id.uuid).inserted else {
                throw SettingsDocumentCodecIssue.duplicateTemplateID(
                    id.string
                )
            }
            try validateTemplateName(
                template.name,
                path: "\(itemPath).name"
            )
            try validateString(
                template.argumentsText,
                path: "\(itemPath).argumentsText",
                maximum: limits.maximumTextUTF8Bytes
            )
            try validateString(
                template.environmentText,
                path: "\(itemPath).environmentText",
                maximum: limits.maximumTextUTF8Bytes
            )
            try validateString(
                template.notes,
                path: "\(itemPath).notes",
                maximum: limits.maximumTextUTF8Bytes
            )
            return SettingsDocument.Template(
                id: id.string,
                name: template.name,
                argumentsText: template.argumentsText,
                environmentText: template.environmentText,
                notes: template.notes
            )
        }
    }

    func visualArray(
        _ value: SettingsStrictJSONParser.Value?,
        path: String
    ) throws -> [SettingsDocument.VisualIdentity] {
        guard let value else {
            throw SettingsDocumentCodecIssue.missingKey(path: path)
        }
        guard case let .array(values) = value else {
            throw SettingsDocumentCodecIssue.invalidType(path: path)
        }
        var visuals: [SettingsDocument.VisualIdentity] = []
        visuals.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            let itemPath = "\(path)[\(index)]"
            guard case let .object(object) = value else {
                throw SettingsDocumentCodecIssue.invalidType(
                    path: itemPath
                )
            }
            try exactKeys(
                object,
                allowed: ["profileID", "symbol", "color"],
                path: itemPath
            )
            visuals.append(
                SettingsDocument.VisualIdentity(
                    profileID: try string(
                        object[exact: "profileID"],
                        path: "\(itemPath).profileID",
                        maximum: 36
                    ),
                    symbol: try string(
                        object[exact: "symbol"],
                        path: "\(itemPath).symbol",
                        maximum: limits.maximumNameUTF8Bytes
                    ),
                    color: try string(
                        object[exact: "color"],
                        path: "\(itemPath).color",
                        maximum: limits.maximumNameUTF8Bytes
                    )
                )
            )
        }
        return try validateVisuals(visuals, path: path)
    }

    func validateVisuals(
        _ visuals: [SettingsDocument.VisualIdentity],
        path: String
    ) throws -> [SettingsDocument.VisualIdentity] {
        guard visuals.count <= limits.maximumVisualIdentities else {
            throw SettingsDocumentCodecIssue.tooManyItems(
                path: path,
                maximum: limits.maximumVisualIdentities
            )
        }
        var ids = Set<UUID>()
        var canonical: [SettingsDocument.VisualIdentity] = []
        canonical.reserveCapacity(visuals.count)
        for (index, visual) in visuals.enumerated() {
            let itemPath = "\(path)[\(index)]"
            let id = try canonicalUUID(
                visual.profileID,
                path: "\(itemPath).profileID"
            )
            guard ids.insert(id.uuid).inserted else {
                throw SettingsDocumentCodecIssue
                    .duplicateVisualProfileID(id.string)
            }
            guard Self.symbols.contains(visual.symbol) else {
                throw SettingsDocumentCodecIssue.invalidValue(
                    path: "\(itemPath).symbol"
                )
            }
            guard Self.colors.contains(visual.color) else {
                throw SettingsDocumentCodecIssue.invalidValue(
                    path: "\(itemPath).color"
                )
            }
            canonical.append(
                SettingsDocument.VisualIdentity(
                    profileID: id.string,
                    symbol: visual.symbol,
                    color: visual.color
                )
            )
        }
        return canonical.sorted {
            $0.profileID < $1.profileID
        }
    }
}
