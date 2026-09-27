import CryptoKit
import Foundation

extension SettingsMigrationPlanner {
    func materializedLegacyState() -> SettingsState? {
        guard let templates = materializedTemplates(),
              let visuals = materializedVisuals(),
              let path = materializedString(
                  legacy.source.source.defaultBaseStoragePath,
                  default: ""
              ),
              let confirm = materializedBoolean(
                  legacy.source.source.confirmBeforeLaunch,
                  default: false
              ),
              let automatic = materializedBoolean(
                  legacy.source.source.automaticallyRecoverCrashedApps,
                  default: true
              ),
              let appearance = materializedAppearance()
        else {
            return nil
        }
        return SettingsState(
            profileTemplates: templates,
            defaultBaseStoragePath: path,
            confirmBeforeLaunch: confirm,
            automaticallyRecoverCrashedApps: automatic,
            appearance: appearance,
            profileVisualIdentities: visuals
        )
    }

    var hasRetainedLegacyValue: Bool {
        isRetained(legacy.source.source.profileTemplates)
            || isRetained(
                legacy.source.source.legacyProfileTemplateNames
            )
            || isRetained(legacy.source.source.defaultBaseStoragePath)
            || isRetained(legacy.source.source.confirmBeforeLaunch)
            || isRetained(
                legacy.source.source.automaticallyRecoverCrashedApps
            )
            || isRetained(legacy.source.source.appearance)
            || isRetained(
                legacy.source.source.profileVisualIdentities
            )
    }

    private func materializedTemplates() -> [ProfileTemplate]? {
        switch legacy.source.profileTemplates {
        case .decoded(let records):
            return records.map {
                ProfileTemplate(
                    id: $0.id,
                    name: $0.name,
                    argumentsText: $0.argumentsText,
                    environmentText: $0.environmentText,
                    notes: $0.notes
                )
            }
        case .absent:
            break
        case .unavailable, .wrongType, .oversized, .invalid:
            return nil
        }
        switch legacy.source.source.legacyProfileTemplateNames {
        case .absent:
            return ProfileTemplate.defaults
        case .retained(let names):
            guard !names.isEmpty else {
                return ProfileTemplate.defaults
            }
            let identifiers = synthesizedLegacyTemplateIDs(names: names)
            return zip(identifiers, names).map { id, name in
                ProfileTemplate(id: id, name: name)
            }
        case .unavailable, .wrongType, .oversized:
            return nil
        }
    }

    private func materializedVisuals()
        -> [UUID: ProfileInstanceVisualIdentity]?
    {
        switch legacy.source.profileVisualIdentities {
        case .absent:
            return [:]
        case .decoded(let records):
            var result: [UUID: ProfileInstanceVisualIdentity] = [:]
            result.reserveCapacity(records.count)
            for record in records {
                guard let id = UUID(uuidString: record.key),
                      record.key == id.uuidString.lowercased(),
                      result[id] == nil,
                      let symbol = ProfileInstanceVisualSymbol(
                          rawValue: record.symbol.rawValue
                      ),
                      let color = ProfileInstanceVisualColor(
                          rawValue: record.color.rawValue
                      )
                else {
                    return nil
                }
                result[id] = .init(symbol: symbol, color: color)
            }
            return result
        case .unavailable, .wrongType, .oversized, .invalid:
            return nil
        }
    }

    private func materializedAppearance() -> AppAppearance? {
        switch legacy.appearance {
        case .absent:
            return .system
        case .supported(.system):
            return .system
        case .supported(.light):
            return .light
        case .supported(.dark):
            return .dark
        case .unavailable, .wrongType, .oversized:
            return nil
        case .unsupportedEmpty, .unsupportedNonempty:
            return nil
        }
    }
}

private func materializedString(
    _ field: SettingsLegacyField<String>,
    default defaultValue: String
) -> String? {
    switch field {
    case .absent:
        defaultValue
    case .retained(let value):
        value
    case .unavailable, .wrongType, .oversized:
        nil
    }
}

private func materializedBoolean(
    _ field: SettingsLegacyField<Bool>,
    default defaultValue: Bool
) -> Bool? {
    switch field {
    case .absent:
        defaultValue
    case .retained(let value):
        value
    case .unavailable, .wrongType, .oversized:
        nil
    }
}

private func isRetained<Value>(
    _ field: SettingsLegacyField<Value>
) -> Bool where Value: Equatable & Sendable {
    if case .retained = field { return true }
    return false
}

private func synthesizedLegacyTemplateIDs(names: [String]) -> [UUID] {
    // Legacy name-only templates never had identifiers. A length-prefixed,
    // order-sensitive namespace yields distinct, retry-stable UUIDv8 values
    // without trimming or canonically folding any source name.
    var namespaceHasher = SHA256()
    namespaceHasher.update(
        data: Data("parallax.settings.legacy-template-names.v1".utf8)
    )
    update(UInt64(names.count), hasher: &namespaceHasher)
    for name in names {
        update(UInt64(name.utf8.count), hasher: &namespaceHasher)
        namespaceHasher.update(data: Data(name.utf8))
    }
    let namespace = Data(namespaceHasher.finalize())
    return names.indices.map { index in
        var itemHasher = SHA256()
        itemHasher.update(data: namespace)
        update(UInt64(index), hasher: &itemHasher)
        var bytes = Array(itemHasher.finalize())
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }
}

private func update(_ value: UInt64, hasher: inout SHA256) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
        hasher.update(data: Data(bytes))
    }
}
