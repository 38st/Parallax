import Foundation

struct SettingsLegacySnapshotDecoder: Sendable {
    static let maximumInputBytes = 4 * 1_024 * 1_024
    static let maximumItems = 4_096
    static let maximumKeyUTF8Bytes = 256
    static let maximumStringUTF8Bytes = 64 * 1_024
    static let maximumNumberBytes = 128
    static let maximumNestingDepth = 32
    static let maximumTokenCount = 200_000
    static let maximumIDUTF8Bytes = 36
    static let maximumNameUTF8Bytes = 256
    static let maximumTextUTF8Bytes = 64 * 1_024
    static let maximumSymbolUTF8Bytes = 64
    static let maximumColorUTF8Bytes = 16

    let source: SettingsLegacySnapshot

    func decode() -> SettingsLegacyDecodedSnapshot {
        let templates = decodeTemplates(source.profileTemplates)
        let visuals = decodeVisuals(source.profileVisualIdentities)
        return .init(
            source: source,
            profileTemplates: templates,
            profileVisualIdentities: visuals
        )
    }

    private func decodeTemplates(
        _ field: SettingsLegacyField<Data>
    ) -> SettingsLegacyDecodedField<[SettingsLegacyTemplateWireRecord]> {
        switch field {
        case .unavailable(let failure):
            return .unavailable(failure)
        case .absent:
            return .absent
        case .wrongType(let type):
            return .wrongType(type)
        case .oversized(let violations):
            return .oversized(violations)
        case .retained(let data):
            return decodeRetainedTemplates(data)
        }
    }

    private func decodeRetainedTemplates(
        _ data: Data
    ) -> SettingsLegacyDecodedField<[SettingsLegacyTemplateWireRecord]> {
        switch preflight(data, root: .array) {
        case .failure(let issue):
            return .invalid(
                .preflight(payload: .profileTemplates, issue: issue)
            )
        case .success:
            break
        }
        do {
            let decoded = try JSONDecoder().decode(
                SettingsLegacyTemplateRoot.self,
                from: data
            )
            guard decoded.records.count <= Self.maximumItems else {
                return .invalid(
                    .resource(
                        payload: .profileTemplates,
                        location: .root,
                        resource: .itemCount,
                        actual: decoded.records.count,
                        maximum: Self.maximumItems
                    )
                )
            }
            return .decoded(decoded.records)
        } catch let failure as SettingsLegacyMaterializationFailure {
            return .invalid(failure.issue)
        } catch {
            return .invalid(
                .shape(
                    payload: .profileTemplates,
                    location: .root,
                    field: .root,
                    problem: .wrongType
                )
            )
        }
    }

    private func decodeVisuals(
        _ field: SettingsLegacyField<Data>
    ) -> SettingsLegacyDecodedField<
        [SettingsLegacyVisualIdentityWireRecord]
    > {
        switch field {
        case .unavailable(let failure):
            return .unavailable(failure)
        case .absent:
            return .absent
        case .wrongType(let type):
            return .wrongType(type)
        case .oversized(let violations):
            return .oversized(violations)
        case .retained(let data):
            return decodeRetainedVisuals(data)
        }
    }

    private func decodeRetainedVisuals(
        _ data: Data
    ) -> SettingsLegacyDecodedField<
        [SettingsLegacyVisualIdentityWireRecord]
    > {
        let evidence: StrictJSONPreflightEvidence
        switch preflight(data, root: .object) {
        case .failure(let issue):
            return .invalid(
                .preflight(
                    payload: .profileVisualIdentities,
                    issue: issue
                )
            )
        case .success(let value):
            evidence = value
        }
        guard let sourceCount = evidence.rootItemCount else {
            return .invalid(
                .shape(
                    payload: .profileVisualIdentities,
                    location: .root,
                    field: .root,
                    problem: .wrongType
                )
            )
        }
        let decoder = JSONDecoder()
        decoder.userInfo[SettingsLegacyVisualRoot.sourceCountKey] =
            sourceCount
        do {
            let decoded = try decoder.decode(
                SettingsLegacyVisualRoot.self,
                from: data
            )
            guard decoded.records.count <= Self.maximumItems else {
                return .invalid(
                    .resource(
                        payload: .profileVisualIdentities,
                        location: .root,
                        resource: .itemCount,
                        actual: decoded.records.count,
                        maximum: Self.maximumItems
                    )
                )
            }
            return .decoded(decoded.records)
        } catch let failure as SettingsLegacyMaterializationFailure {
            return .invalid(failure.issue)
        } catch {
            return .invalid(
                .shape(
                    payload: .profileVisualIdentities,
                    location: .root,
                    field: .root,
                    problem: .wrongType
                )
            )
        }
    }

    private func preflight(
        _ data: Data,
        root: StrictJSONRootRequirement
    ) -> Result<StrictJSONPreflightEvidence, StrictJSONPreflightIssue> {
        StrictJSONPreflight(
            limits: .init(
                maximumBytes: Self.maximumInputBytes,
                maximumArrayItems: Self.maximumItems,
                maximumObjectMembers: Self.maximumItems,
                maximumKeyUTF8Bytes: Self.maximumKeyUTF8Bytes,
                maximumStringUTF8Bytes: Self.maximumStringUTF8Bytes,
                maximumNumberBytes: Self.maximumNumberBytes,
                maximumNestingDepth: Self.maximumNestingDepth,
                maximumTokenCount: Self.maximumTokenCount
            ),
            rootRequirement: root,
            topLevelProbe: nil
        ).scan(data)
    }
}
