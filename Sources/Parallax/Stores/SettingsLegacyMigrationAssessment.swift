import Foundation

enum SettingsLegacyMigrationPairing: Equatable, Sendable {
    case paired, inconsistent
}

enum SettingsLegacyMigrationJSONFieldState: Equatable, Sendable {
    case unavailable, absent, wrongType, oversized, invalid
    case decoded(count: Int)
}

enum SettingsLegacyMigrationNamesState: Equatable, Sendable {
    case unavailable, absent, wrongType, oversized
    case retained(count: Int)
}

enum SettingsLegacyMigrationPresence: Equatable, Sendable {
    case unknown, absent, present
}

struct SettingsLegacyMigrationTemplateFormFacts: Equatable, Sendable {
    let structured: SettingsLegacyMigrationPresence
    let names: SettingsLegacyMigrationPresence
}

enum SettingsLegacyMigrationNameCompatibility: Equatable, Sendable {
    case blank, accepted, requiresNormalization
}

struct SettingsLegacyMigrationNameFacts: Equatable, Sendable {
    let sourceIndex: Int
    let compatibility: SettingsLegacyMigrationNameCompatibility
    let firstPriorScalarExactIndex: Int?
    let firstPriorCanonicalEquivalentButScalarDistinctIndex: Int?
}

struct SettingsLegacyMigrationStructuredTemplateFacts: Equatable, Sendable {
    let sourceIndex: Int
    let id: UUID
    let name: SettingsLegacyMigrationNameFacts
    let materializedIgnoredMemberCount: Int
    let firstPriorEqualUUIDIndex: Int?
}

enum SettingsLegacyMigrationStringState: Equatable, Sendable {
    case unavailable, absent, wrongType, oversized
    case retainedEmpty, retainedNonempty
}

enum SettingsLegacyMigrationBooleanState: Equatable, Sendable {
    case unavailable, absent, wrongType, oversized
    case retainedFalse, retainedTrue
}

enum SettingsLegacyMigrationSupportedAppearance: Equatable, Sendable {
    case system, light, dark
}

enum SettingsLegacyMigrationAppearanceState: Equatable, Sendable {
    case unavailable, absent, wrongType, oversized
    case supported(SettingsLegacyMigrationSupportedAppearance)
    case unsupportedEmpty, unsupportedNonempty
}

enum SettingsLegacyMigrationVisualKeyClass: Equatable, Sendable {
    case canonicalLowercaseUUID(UUID), noncanonicalUUID(UUID), nonUUID
}

struct SettingsLegacyMigrationVisualFacts: Equatable, Sendable {
    let entryIndex: Int
    let materializedIgnoredMemberCount: Int
    let rawKeyClass: SettingsLegacyMigrationVisualKeyClass
    let firstPriorEqualUUIDIndex: Int?
}

struct SettingsLegacyMigrationByteTotals: Equatable, Sendable {
    let structuredTemplates: UInt64
    let legacyNames: UInt64
    let retainedScalars: UInt64
    let visuals: UInt64
    let nameOnlyIdentifierDemand: UInt64
}

struct SettingsLegacyMigrationAssessment: Equatable, Sendable {
    let source: SettingsLegacyDecodedSnapshot
    let structuredTemplatePairing: SettingsLegacyMigrationPairing
    let visualPairing: SettingsLegacyMigrationPairing
    let structuredTemplates: SettingsLegacyMigrationJSONFieldState
    let legacyNames: SettingsLegacyMigrationNamesState
    let templateForms: SettingsLegacyMigrationTemplateFormFacts
    let structuredTemplateFacts: [SettingsLegacyMigrationStructuredTemplateFacts]
    let legacyNameFacts: [SettingsLegacyMigrationNameFacts]
    let basePath: SettingsLegacyMigrationStringState
    let confirmBeforeLaunch: SettingsLegacyMigrationBooleanState
    let automaticallyRecoverCrashedApps: SettingsLegacyMigrationBooleanState
    let appearance: SettingsLegacyMigrationAppearanceState
    let visuals: SettingsLegacyMigrationJSONFieldState
    let visualFacts: [SettingsLegacyMigrationVisualFacts]
    let byteTotals: SettingsLegacyMigrationByteTotals
}

struct SettingsLegacyMigrationAssessor: Sendable {
    let source: SettingsLegacyDecodedSnapshot

    func assess() -> SettingsLegacyMigrationAssessment {
        let templates = decodedTemplates(source.profileTemplates)
        let names = retainedNames(source.source.legacyProfileTemplateNames)
        let visuals = decodedVisuals(source.profileVisualIdentities)
        return .init(
            source: source,
            structuredTemplatePairing: pairing(
                source.source.profileTemplates, source.profileTemplates
            ),
            visualPairing: pairing(
                source.source.profileVisualIdentities,
                source.profileVisualIdentities
            ),
            structuredTemplates: jsonState(source.profileTemplates),
            legacyNames:
                namesState(source.source.legacyProfileTemplateNames),
            templateForms: .init(
                structured: presence(source.source.profileTemplates),
                names: presence(source.source.legacyProfileTemplateNames)
            ),
            structuredTemplateFacts: templateFacts(templates),
            legacyNameFacts: nameFacts(names),
            basePath: stringState(source.source.defaultBaseStoragePath),
            confirmBeforeLaunch: booleanState(
                source.source.confirmBeforeLaunch
            ),
            automaticallyRecoverCrashedApps: booleanState(
                source.source.automaticallyRecoverCrashedApps
            ),
            appearance: appearanceState(source.source.appearance),
            visuals: jsonState(source.profileVisualIdentities),
            visualFacts: visualFacts(visuals),
            byteTotals: byteTotals(
                templates: templates, names: names, visuals: visuals
            )
        )
    }

    private func templateFacts(
        _ records: [SettingsLegacyTemplateWireRecord]
    ) -> [SettingsLegacyMigrationStructuredTemplateFacts] {
        var identifiers: [UUID: Int] = [:]
        var names = NameTracker()
        return records.enumerated().map { index, record in
            let prior = identifiers[record.id]
            if prior == nil {
                identifiers[record.id] = index
            }
            return .init(
                sourceIndex: index,
                id: record.id,
                name: names.facts(record.name, index: index),
                materializedIgnoredMemberCount:
                    record.materializedIgnoredMemberCount,
                firstPriorEqualUUIDIndex: prior
            )
        }
    }

    private func nameFacts(_ names: [String])
        -> [SettingsLegacyMigrationNameFacts]
    {
        var tracker = NameTracker()
        return names.enumerated().map {
            tracker.facts($0.element, index: $0.offset)
        }
    }

    private func visualFacts(
        _ records: [SettingsLegacyVisualIdentityWireRecord]
    ) -> [SettingsLegacyMigrationVisualFacts] {
        var identifiers: [UUID: Int] = [:]
        return records.enumerated().map { index, record in
            guard let id = UUID(uuidString: record.key) else {
                return .init(
                    entryIndex: index,
                    materializedIgnoredMemberCount:
                        record.materializedIgnoredMemberCount,
                    rawKeyClass: .nonUUID,
                    firstPriorEqualUUIDIndex: nil
                )
            }
            let prior = identifiers[id]
            if prior == nil {
                identifiers[id] = index
            }
            let canonical = id.uuidString.lowercased()
            let keyClass: SettingsLegacyMigrationVisualKeyClass =
                scalarEqual(record.key, canonical)
                ? .canonicalLowercaseUUID(id)
                : .noncanonicalUUID(id)
            return .init(
                entryIndex: index,
                materializedIgnoredMemberCount:
                    record.materializedIgnoredMemberCount,
                rawKeyClass: keyClass,
                firstPriorEqualUUIDIndex: prior
            )
        }
    }

    private func byteTotals(
        templates: [SettingsLegacyTemplateWireRecord],
        names: [String],
        visuals: [SettingsLegacyVisualIdentityWireRecord]
    ) -> SettingsLegacyMigrationByteTotals {
        var structured: UInt64 = 0
        for record in templates {
            add(36, to: &structured)
            add(record.name, to: &structured)
            add(record.argumentsText, to: &structured)
            add(record.environmentText, to: &structured)
            add(record.notes, to: &structured)
        }
        var legacyNames: UInt64 = 0
        for name in names {
            add(name, to: &legacyNames)
        }
        var scalars: UInt64 = 0
        if case .retained(let path) =
            source.source.defaultBaseStoragePath {
            add(path, to: &scalars)
        }
        if case .retained(let appearance) = source.source.appearance {
            add(appearance, to: &scalars)
        }
        var visualBytes: UInt64 = 0
        for record in visuals {
            add(record.key, to: &visualBytes)
            add(record.symbol.rawValue, to: &visualBytes)
            add(record.color.rawValue, to: &visualBytes)
        }
        let demand =
            UInt64(names.count).multipliedReportingOverflow(by: 36)
        return .init(
            structuredTemplates: structured,
            legacyNames: legacyNames,
            retainedScalars: scalars,
            visuals: visualBytes,
            nameOnlyIdentifierDemand:
                demand.overflow ? .max : demand.partialValue
        )
    }

    private func add(_ value: String, to total: inout UInt64) {
        add(UInt64(value.utf8.count), to: &total)
    }

    private func add(_ value: UInt64, to total: inout UInt64) {
        let sum = total.addingReportingOverflow(value)
        total = sum.overflow ? .max : sum.partialValue
    }
}

private struct ScalarNameKey: Hashable {
    let scalars: [UInt32]

    init(_ value: String) { scalars = value.unicodeScalars.map(\.value) }
}

private struct CanonicalNameGroup {
    let earliestKey: ScalarNameKey
    let earliestIndex: Int
    var earliestDifferentIndex: Int?

    func earliestDifferent(from key: ScalarNameKey) -> Int? {
        key == earliestKey ? earliestDifferentIndex : earliestIndex
    }
}

private struct NameTracker {
    private var scalarIndexes: [ScalarNameKey: Int] = [:]
    private var canonicalGroups: [String: CanonicalNameGroup] = [:]

    mutating func facts(_ value: String, index: Int)
        -> SettingsLegacyMigrationNameFacts
    {
        let key = ScalarNameKey(value)
        let exact = scalarIndexes[key]
        var group = canonicalGroups[value]
        let canonical = group?.earliestDifferent(from: key)
        if exact == nil {
            scalarIndexes[key] = index
        }
        if group == nil {
            group = .init(
                earliestKey: key,
                earliestIndex: index,
                earliestDifferentIndex: nil
            )
        } else if key != group?.earliestKey,
                  group?.earliestDifferentIndex == nil
        {
            group?.earliestDifferentIndex = index
        }
        canonicalGroups[value] = group
        return .init(
            sourceIndex: index,
            compatibility: compatibility(value),
            firstPriorScalarExactIndex: exact,
            firstPriorCanonicalEquivalentButScalarDistinctIndex:
                canonical
        )
    }
}

private func compatibility(_ value: String)
    -> SettingsLegacyMigrationNameCompatibility
{
    guard let normalized = DisplayNameValidator.normalized(value) else {
        return .blank
    }
    return scalarEqual(normalized, value) ? .accepted : .requiresNormalization
}

private func scalarEqual(_ lhs: String, _ rhs: String) -> Bool {
    ScalarNameKey(lhs) == ScalarNameKey(rhs)
}

private func decodedTemplates(_ field: SettingsLegacyDecodedField<
    [SettingsLegacyTemplateWireRecord]
>) -> [SettingsLegacyTemplateWireRecord] {
    guard case .decoded(let records) = field else {
        return []
    }
    return records
}

private func decodedVisuals(_ field: SettingsLegacyDecodedField<
    [SettingsLegacyVisualIdentityWireRecord]
>) -> [SettingsLegacyVisualIdentityWireRecord] {
    guard case .decoded(let records) = field else {
        return []
    }
    return records
}

private func retainedNames(_ field: SettingsLegacyField<[String]>) -> [String] {
    guard case .retained(let names) = field else {
        return []
    }
    return names
}

private func jsonState<Value>(
    _ field: SettingsLegacyDecodedField<[Value]>
) -> SettingsLegacyMigrationJSONFieldState where Value: Equatable & Sendable {
    switch field {
    case .unavailable: .unavailable
    case .absent: .absent
    case .wrongType: .wrongType
    case .oversized: .oversized
    case .invalid: .invalid
    case .decoded(let values): .decoded(count: values.count)
    }
}

private func namesState(
    _ field: SettingsLegacyField<[String]>
) -> SettingsLegacyMigrationNamesState {
    switch field {
    case .unavailable: .unavailable
    case .absent: .absent
    case .wrongType: .wrongType
    case .oversized: .oversized
    case .retained(let values): .retained(count: values.count)
    }
}

private func presence<Value>(
    _ field: SettingsLegacyField<Value>
) -> SettingsLegacyMigrationPresence where Value: Equatable & Sendable {
    switch field {
    case .unavailable: .unknown
    case .absent: .absent
    case .retained, .wrongType, .oversized: .present
    }
}

private func stringState(
    _ field: SettingsLegacyField<String>
) -> SettingsLegacyMigrationStringState {
    switch field {
    case .unavailable: .unavailable
    case .absent: .absent
    case .wrongType: .wrongType
    case .oversized: .oversized
    case .retained(let value):
        value.isEmpty ? .retainedEmpty : .retainedNonempty
    }
}

private func booleanState(
    _ field: SettingsLegacyField<Bool>
) -> SettingsLegacyMigrationBooleanState {
    switch field {
    case .unavailable: .unavailable
    case .absent: .absent
    case .wrongType: .wrongType
    case .oversized: .oversized
    case .retained(false): .retainedFalse
    case .retained(true): .retainedTrue
    }
}

private func appearanceState(
    _ field: SettingsLegacyField<String>
) -> SettingsLegacyMigrationAppearanceState {
    switch field {
    case .unavailable: .unavailable
    case .absent: .absent
    case .wrongType: .wrongType
    case .oversized: .oversized
    case .retained("system"): .supported(.system)
    case .retained("light"): .supported(.light)
    case .retained("dark"): .supported(.dark)
    case .retained(let value):
        value.isEmpty ? .unsupportedEmpty : .unsupportedNonempty
    }
}

private func pairing<Value>(
    _ source: SettingsLegacyField<Data>,
    _ decoded: SettingsLegacyDecodedField<[Value]>
) -> SettingsLegacyMigrationPairing where Value: Equatable & Sendable {
    switch (source, decoded) {
    case (.unavailable(let lhs), .unavailable(let rhs)) where lhs == rhs:
        .paired
    case (.absent, .absent): .paired
    case (.wrongType(let lhs), .wrongType(let rhs)) where lhs == rhs: .paired
    case (.oversized(let lhs), .oversized(let rhs)) where lhs == rhs: .paired
    case (.retained, .decoded), (.retained, .invalid): .paired
    default: .inconsistent
    }
}
