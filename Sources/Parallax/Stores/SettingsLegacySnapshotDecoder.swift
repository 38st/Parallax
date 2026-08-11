import Foundation

enum SettingsLegacyJSONPayload: Equatable, Sendable {
    case profileTemplates
    case profileVisualIdentities
}

enum SettingsLegacyWireLocation: Equatable, Sendable {
    case root
    case template(index: Int)
    case visual(key: String)
}

enum SettingsLegacyWireField: Equatable, Sendable {
    case root
    case templateItem
    case id
    case name
    case argumentsText
    case environmentText
    case notes
    case visualValue
    case symbol
    case color
}

enum SettingsLegacyWireValueProblem: Equatable, Sendable {
    case missing
    case null
    case wrongType
    case invalidValue
}

enum SettingsLegacyWireResource: Equatable, Sendable {
    case itemCount
    case keyUTF8Bytes
    case idUTF8Bytes
    case nameUTF8Bytes
    case argumentsTextUTF8Bytes
    case environmentTextUTF8Bytes
    case notesUTF8Bytes
    case symbolUTF8Bytes
    case colorUTF8Bytes
}

enum SettingsLegacySnapshotDecodeIssue: Equatable, Sendable {
    case preflight(
        payload: SettingsLegacyJSONPayload,
        issue: StrictJSONPreflightIssue
    )
    case shape(
        payload: SettingsLegacyJSONPayload,
        location: SettingsLegacyWireLocation,
        field: SettingsLegacyWireField,
        problem: SettingsLegacyWireValueProblem
    )
    case resource(
        payload: SettingsLegacyJSONPayload,
        location: SettingsLegacyWireLocation,
        resource: SettingsLegacyWireResource,
        actual: Int,
        maximum: Int
    )
    case visualKeyIdentityAmbiguity(
        sourceCount: Int,
        materializedCount: Int
    )
}

enum SettingsLegacyDecodedField<Value>: Equatable, Sendable
where Value: Equatable & Sendable {
    case unavailable(SettingsLegacySourceFailure)
    case absent
    case wrongType(SettingsLegacyRawType)
    case oversized([SettingsLegacyLimitViolation])
    case decoded(Value)
    case invalid(SettingsLegacySnapshotDecodeIssue)
}

struct SettingsLegacyTemplateWireRecord: Equatable, Sendable {
    let id: UUID
    let name: String
    let argumentsText: String
    let environmentText: String
    let notes: String
    let materializedIgnoredMemberCount: Int
}

enum SettingsLegacyVisualSymbol: String, Equatable, Sendable {
    case briefcase = "briefcase.fill"
    case person = "person.crop.circle.fill"
    case flask = "flask.fill"
    case terminal = "terminal.fill"
    case book = "book.closed.fill"
    case palette = "paintpalette.fill"
    case globe
    case lightbulb = "lightbulb.fill"
    case hammer = "hammer.fill"
    case camera = "camera.fill"
    case music = "music.note"
    case leaf = "leaf.fill"
    case unmanaged = "app.dashed"
}

enum SettingsLegacyVisualColor: String, Equatable, Sendable {
    case blue
    case purple
    case orange
    case pink
    case teal
    case green
    case indigo
    case cyan
    case brown
    case gray
}

struct SettingsLegacyVisualIdentityWireRecord: Equatable, Sendable {
    let key: String
    let symbol: SettingsLegacyVisualSymbol
    let color: SettingsLegacyVisualColor
    let materializedIgnoredMemberCount: Int
}

struct SettingsLegacyDecodedSnapshot: Equatable, Sendable {
    let source: SettingsLegacySnapshot
    let profileTemplates:
        SettingsLegacyDecodedField<[SettingsLegacyTemplateWireRecord]>
    let profileVisualIdentities:
        SettingsLegacyDecodedField<[SettingsLegacyVisualIdentityWireRecord]>
}

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

private struct SettingsLegacyMaterializationFailure: Error {
    let issue: SettingsLegacySnapshotDecodeIssue
}

private struct SettingsLegacyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct SettingsLegacyTemplateRoot: Decodable {
    let records: [SettingsLegacyTemplateWireRecord]

    init(from decoder: Decoder) throws {
        var container: UnkeyedDecodingContainer
        do {
            container = try decoder.unkeyedContainer()
        } catch {
            throw SettingsLegacyMaterializationFailure(
                issue: .shape(
                    payload: .profileTemplates,
                    location: .root,
                    field: .root,
                    problem: .wrongType
                )
            )
        }
        var result: [SettingsLegacyTemplateWireRecord] = []
        if let count = container.count {
            guard count <= SettingsLegacySnapshotDecoder.maximumItems else {
                throw SettingsLegacyMaterializationFailure(
                    issue: .resource(
                        payload: .profileTemplates,
                        location: .root,
                        resource: .itemCount,
                        actual: count,
                        maximum: SettingsLegacySnapshotDecoder.maximumItems
                    )
                )
            }
            result.reserveCapacity(count)
        }
        while !container.isAtEnd {
            let index = container.currentIndex
            if try container.decodeNil() {
                throw SettingsLegacyMaterializationFailure(
                    issue: .shape(
                        payload: .profileTemplates,
                        location: .template(index: index),
                        field: .templateItem,
                        problem: .null
                    )
                )
            }
            do {
                result.append(
                    try container.decode(
                        SettingsLegacyTemplateValue.self
                    ).record
                )
            } catch let failure as SettingsLegacyMaterializationFailure {
                throw failure
            } catch {
                throw SettingsLegacyMaterializationFailure(
                    issue: .shape(
                        payload: .profileTemplates,
                        location: .template(index: index),
                        field: .templateItem,
                        problem: .wrongType
                    )
                )
            }
        }
        records = result
    }
}

private struct SettingsLegacyTemplateValue: Decodable {
    let record: SettingsLegacyTemplateWireRecord

    init(from decoder: Decoder) throws {
        let index = decoder.codingPath.last?.intValue ?? 0
        let location = SettingsLegacyWireLocation.template(index: index)
        let container = try SettingsLegacyDecoding.container(
            decoder,
            payload: .profileTemplates,
            location: location,
            field: .templateItem
        )
        let idSource = try SettingsLegacyDecoding.string(
            container,
            name: "id",
            payload: .profileTemplates,
            location: location,
            field: .id,
            resource: .idUTF8Bytes,
            maximum: SettingsLegacySnapshotDecoder.maximumIDUTF8Bytes
        )
        guard let id = UUID(uuidString: idSource) else {
            throw SettingsLegacyMaterializationFailure(
                issue: .shape(
                    payload: .profileTemplates,
                    location: location,
                    field: .id,
                    problem: .invalidValue
                )
            )
        }
        let name = try SettingsLegacyDecoding.string(
            container,
            name: "name",
            payload: .profileTemplates,
            location: location,
            field: .name,
            resource: .nameUTF8Bytes,
            maximum: SettingsLegacySnapshotDecoder.maximumNameUTF8Bytes
        )
        let arguments = try SettingsLegacyDecoding.string(
            container,
            name: "argumentsText",
            payload: .profileTemplates,
            location: location,
            field: .argumentsText,
            resource: .argumentsTextUTF8Bytes,
            maximum: SettingsLegacySnapshotDecoder.maximumTextUTF8Bytes
        )
        let environment = try SettingsLegacyDecoding.string(
            container,
            name: "environmentText",
            payload: .profileTemplates,
            location: location,
            field: .environmentText,
            resource: .environmentTextUTF8Bytes,
            maximum: SettingsLegacySnapshotDecoder.maximumTextUTF8Bytes
        )
        let notes = try SettingsLegacyDecoding.string(
            container,
            name: "notes",
            payload: .profileTemplates,
            location: location,
            field: .notes,
            resource: .notesUTF8Bytes,
            maximum: SettingsLegacySnapshotDecoder.maximumTextUTF8Bytes
        )
        let known = [
            "id",
            "name",
            "argumentsText",
            "environmentText",
            "notes",
        ]
        record = .init(
            id: id,
            name: name,
            argumentsText: arguments,
            environmentText: environment,
            notes: notes,
            materializedIgnoredMemberCount:
                SettingsLegacyDecoding.ignoredCount(
                    container,
                    knownNames: known
                )
        )
    }
}

private struct SettingsLegacyVisualRoot: Decodable {
    static let sourceCountKey = CodingUserInfoKey(
        rawValue: "SettingsLegacyVisualRoot.sourceCount"
    )!

    let records: [SettingsLegacyVisualIdentityWireRecord]

    init(from decoder: Decoder) throws {
        let container = try SettingsLegacyDecoding.container(
            decoder,
            payload: .profileVisualIdentities,
            location: .root,
            field: .root
        )
        let materializedCount = container.allKeys.count
        guard let sourceCount = decoder.userInfo[Self.sourceCountKey] as? Int
        else {
            throw SettingsLegacyMaterializationFailure(
                issue: .shape(
                    payload: .profileVisualIdentities,
                    location: .root,
                    field: .root,
                    problem: .invalidValue
                )
            )
        }
        guard materializedCount == sourceCount else {
            throw SettingsLegacyMaterializationFailure(
                issue: .visualKeyIdentityAmbiguity(
                    sourceCount: sourceCount,
                    materializedCount: materializedCount
                )
            )
        }
        guard materializedCount <= SettingsLegacySnapshotDecoder.maximumItems
        else {
            throw SettingsLegacyMaterializationFailure(
                issue: .resource(
                    payload: .profileVisualIdentities,
                    location: .root,
                    resource: .itemCount,
                    actual: materializedCount,
                    maximum: SettingsLegacySnapshotDecoder.maximumItems
                )
            )
        }
        let ordered = container.allKeys.sorted {
            $0.stringValue.utf8.lexicographicallyPrecedes(
                $1.stringValue.utf8
            )
        }
        var result: [SettingsLegacyVisualIdentityWireRecord] = []
        result.reserveCapacity(materializedCount)
        for key in ordered {
            let rawKey = key.stringValue
            let location = SettingsLegacyWireLocation.visual(key: rawKey)
            let rawVisualIdentifierUTF8Count = rawKey.utf8.count
            guard rawVisualIdentifierUTF8Count
                    <= SettingsLegacySnapshotDecoder.maximumKeyUTF8Bytes
            else {
                throw SettingsLegacyMaterializationFailure(
                    issue: .resource(
                        payload: .profileVisualIdentities,
                        location: location,
                        resource: .keyUTF8Bytes,
                        actual: rawVisualIdentifierUTF8Count,
                        maximum:
                            SettingsLegacySnapshotDecoder
                                .maximumKeyUTF8Bytes
                    )
                )
            }
            if try container.decodeNil(forKey: key) {
                throw SettingsLegacyMaterializationFailure(
                    issue: .shape(
                        payload: .profileVisualIdentities,
                        location: location,
                        field: .visualValue,
                        problem: .null
                    )
                )
            }
            do {
                let value = try container.decode(
                    SettingsLegacyVisualValue.self,
                    forKey: key
                )
                result.append(
                    .init(
                        key: rawKey,
                        symbol: value.symbol,
                        color: value.color,
                        materializedIgnoredMemberCount:
                            value.materializedIgnoredMemberCount
                    )
                )
            } catch let failure as SettingsLegacyMaterializationFailure {
                throw failure
            } catch {
                throw SettingsLegacyMaterializationFailure(
                    issue: .shape(
                        payload: .profileVisualIdentities,
                        location: location,
                        field: .visualValue,
                        problem: .wrongType
                    )
                )
            }
        }
        records = result
    }
}

private struct SettingsLegacyVisualValue: Decodable {
    let symbol: SettingsLegacyVisualSymbol
    let color: SettingsLegacyVisualColor
    let materializedIgnoredMemberCount: Int

    init(from decoder: Decoder) throws {
        let rawKey = decoder.codingPath.last?.stringValue ?? ""
        let location = SettingsLegacyWireLocation.visual(key: rawKey)
        let container = try SettingsLegacyDecoding.container(
            decoder,
            payload: .profileVisualIdentities,
            location: location,
            field: .visualValue
        )
        let symbolSource = try SettingsLegacyDecoding.string(
            container,
            name: "symbol",
            payload: .profileVisualIdentities,
            location: location,
            field: .symbol,
            resource: .symbolUTF8Bytes,
            maximum: SettingsLegacySnapshotDecoder.maximumSymbolUTF8Bytes
        )
        guard let symbol = SettingsLegacyVisualSymbol(
            rawValue: symbolSource
        ) else {
            throw SettingsLegacyMaterializationFailure(
                issue: .shape(
                    payload: .profileVisualIdentities,
                    location: location,
                    field: .symbol,
                    problem: .invalidValue
                )
            )
        }
        let colorSource = try SettingsLegacyDecoding.string(
            container,
            name: "color",
            payload: .profileVisualIdentities,
            location: location,
            field: .color,
            resource: .colorUTF8Bytes,
            maximum: SettingsLegacySnapshotDecoder.maximumColorUTF8Bytes
        )
        guard let color = SettingsLegacyVisualColor(
            rawValue: colorSource
        ) else {
            throw SettingsLegacyMaterializationFailure(
                issue: .shape(
                    payload: .profileVisualIdentities,
                    location: location,
                    field: .color,
                    problem: .invalidValue
                )
            )
        }
        self.symbol = symbol
        self.color = color
        materializedIgnoredMemberCount =
            SettingsLegacyDecoding.ignoredCount(
                container,
                knownNames: ["symbol", "color"]
            )
    }
}

private enum SettingsLegacyDecoding {
    static func container(
        _ decoder: Decoder,
        payload: SettingsLegacyJSONPayload,
        location: SettingsLegacyWireLocation,
        field: SettingsLegacyWireField
    ) throws -> KeyedDecodingContainer<SettingsLegacyCodingKey> {
        do {
            return try decoder.container(
                keyedBy: SettingsLegacyCodingKey.self
            )
        } catch {
            throw SettingsLegacyMaterializationFailure(
                issue: .shape(
                    payload: payload,
                    location: location,
                    field: field,
                    problem: .wrongType
                )
            )
        }
    }

    static func string(
        _ container: KeyedDecodingContainer<SettingsLegacyCodingKey>,
        name: String,
        payload: SettingsLegacyJSONPayload,
        location: SettingsLegacyWireLocation,
        field: SettingsLegacyWireField,
        resource: SettingsLegacyWireResource,
        maximum: Int
    ) throws -> String {
        guard let key = exactKey(container, name: name) else {
            throw SettingsLegacyMaterializationFailure(
                issue: .shape(
                    payload: payload,
                    location: location,
                    field: field,
                    problem: .missing
                )
            )
        }
        if try container.decodeNil(forKey: key) {
            throw SettingsLegacyMaterializationFailure(
                issue: .shape(
                    payload: payload,
                    location: location,
                    field: field,
                    problem: .null
                )
            )
        }
        let value: String
        do {
            value = try container.decode(String.self, forKey: key)
        } catch {
            throw SettingsLegacyMaterializationFailure(
                issue: .shape(
                    payload: payload,
                    location: location,
                    field: field,
                    problem: .wrongType
                )
            )
        }
        let count = value.utf8.count
        guard count <= maximum else {
            throw SettingsLegacyMaterializationFailure(
                issue: .resource(
                    payload: payload,
                    location: location,
                    resource: resource,
                    actual: count,
                    maximum: maximum
                )
            )
        }
        return value
    }

    static func ignoredCount(
        _ container: KeyedDecodingContainer<SettingsLegacyCodingKey>,
        knownNames: [String]
    ) -> Int {
        container.allKeys.reduce(into: 0) { count, key in
            if !knownNames.contains(where: {
                scalarEqual(key.stringValue, $0)
            }) {
                count += 1
            }
        }
    }

    private static func exactKey(
        _ container: KeyedDecodingContainer<SettingsLegacyCodingKey>,
        name: String
    ) -> SettingsLegacyCodingKey? {
        container.allKeys.first {
            scalarEqual($0.stringValue, name)
        }
    }

    private static func scalarEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(
            rhs.unicodeScalars,
            by: { $0.value == $1.value }
        )
    }
}
