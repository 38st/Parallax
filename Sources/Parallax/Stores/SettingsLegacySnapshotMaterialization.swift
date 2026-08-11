import Foundation

struct SettingsLegacyMaterializationFailure: Error {
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

struct SettingsLegacyTemplateRoot: Decodable {
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

struct SettingsLegacyVisualRoot: Decodable {
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

