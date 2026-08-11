import CoreFoundation
import Foundation

enum SettingsLegacyKey: String, CaseIterable, Sendable {
    case profileTemplates = "settings.profileTemplates"
    case legacyProfileTemplateNames = "settings.profileTemplateNames"
    case defaultBaseStoragePath = "settings.defaultBaseStoragePath"
    case confirmBeforeLaunch = "settings.confirmBeforeLaunch"
    case automaticallyRecoverCrashedApps =
        "settings.automaticallyRecoverCrashedApps"
    case appearance = "settings.appearance"
    case profileVisualIdentities = "settings.profileVisualIdentities"

    static let ordered: [Self] = [
        .profileTemplates,
        .legacyProfileTemplateNames,
        .defaultBaseStoragePath,
        .confirmBeforeLaunch,
        .automaticallyRecoverCrashedApps,
        .appearance,
        .profileVisualIdentities,
    ]
}

enum SettingsLegacyRawType: Equatable, Sendable {
    case boolean
    case data
    case string
    case array
    case number
    case dictionary
    case date
    case other
}

enum SettingsLegacyLimitViolation: Equatable, Sendable {
    case byteCount(actual: UInt64, maximum: Int)
    case elementCount(actual: Int, maximum: Int)
    case stringElementUTF8Bytes(
        firstIndex: Int,
        firstActual: Int,
        violationCount: Int,
        maximum: Int
    )
    case aggregateUTF8Bytes(actual: UInt64, maximum: Int)
}

enum SettingsLegacyReservedApplicationIdentifier: Equatable, Sendable {
    case anyApplication
    case currentApplication
}

enum SettingsLegacySourceFailure: Equatable, Sendable {
    case invalidApplicationIdentifier(actualUTF8Bytes: Int, maximum: Int)
    case reservedApplicationIdentifier(
        SettingsLegacyReservedApplicationIdentifier
    )
    case unavailable(code: Int32)
}

enum SettingsLegacyField<Value>: Equatable, Sendable
where Value: Equatable & Sendable {
    case unavailable(SettingsLegacySourceFailure)
    case absent
    case retained(Value)
    case wrongType(SettingsLegacyRawType)
    case oversized([SettingsLegacyLimitViolation])
}

enum SettingsLegacyFieldIssue: Equatable, Sendable {
    case wrongType(SettingsLegacyRawType)
    case oversized([SettingsLegacyLimitViolation])
}

enum SettingsLegacySnapshotIssue: Equatable, Sendable {
    case source(SettingsLegacySourceFailure)
    case field(key: SettingsLegacyKey, issue: SettingsLegacyFieldIssue)
    case aggregateDataBytes(actual: UInt64, maximum: Int)
    case unexpectedKeyCount(Int)
}

enum SettingsLegacySnapshotCompletion: Equatable, Sendable {
    case complete
    case partial([SettingsLegacySnapshotIssue])
}

struct SettingsLegacySnapshot: Equatable, Sendable {
    let profileTemplates: SettingsLegacyField<Data>
    let legacyProfileTemplateNames: SettingsLegacyField<[String]>
    let defaultBaseStoragePath: SettingsLegacyField<String>
    let confirmBeforeLaunch: SettingsLegacyField<Bool>
    let automaticallyRecoverCrashedApps: SettingsLegacyField<Bool>
    let appearance: SettingsLegacyField<String>
    let profileVisualIdentities: SettingsLegacyField<Data>
    let completion: SettingsLegacySnapshotCompletion
}

struct SettingsLegacySnapshotReader: Sendable {
    static let maximumApplicationIdentifierUTF8Bytes = 4_096
    static let maximumRequestedKeyUTF8Bytes = 256
    static let maximumDataBytes = 4 * 1_024 * 1_024
    static let maximumAggregateDataBytes = 8 * 1_024 * 1_024
    static let maximumLegacyNames = 4_096
    static let maximumLegacyNameUTF8Bytes = 256
    static let maximumLegacyNamesAggregateUTF8Bytes = 4 * 1_024 * 1_024
    static let maximumBasePathUTF8Bytes = 4_096
    static let maximumAppearanceUTF8Bytes = 16

    let applicationIdentifier: String

    func capture() -> SettingsLegacySnapshot {
        if let failure = Self.applicationIdentifierFailure(
            applicationIdentifier
        ) {
            return SettingsLegacySnapshotClassifier.unavailable(failure)
        }
        let keys = SettingsLegacyKey.ordered.map(\.rawValue)
        precondition(keys.count == 7)
        precondition(keys.allSatisfy {
            !$0.isEmpty
                && $0.utf8.count <= Self.maximumRequestedKeyUTF8Bytes
        })
        let copied = CFPreferencesCopyMultiple(
            keys as CFArray,
            applicationIdentifier as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        let values = copied as NSDictionary as! [String: Any]
        return SettingsLegacySnapshotClassifier.classify(values)
    }

    static func applicationIdentifierFailure(
        _ identifier: String
    ) -> SettingsLegacySourceFailure? {
        let byteCount = identifier.utf8.count
        guard !identifier.isEmpty,
              byteCount <= maximumApplicationIdentifierUTF8Bytes
        else {
            return .invalidApplicationIdentifier(
                actualUTF8Bytes: byteCount,
                maximum: maximumApplicationIdentifierUTF8Bytes
            )
        }
        if identifier == kCFPreferencesAnyApplication as String {
            return .reservedApplicationIdentifier(.anyApplication)
        }
        if identifier == kCFPreferencesCurrentApplication as String {
            return .reservedApplicationIdentifier(.currentApplication)
        }
        return nil
    }
}

enum SettingsLegacySnapshotClassifier {
    static func classify(_ values: [String: Any]) -> SettingsLegacySnapshot {
        let templates = dataField(values, key: .profileTemplates)
        let names = namesField(values)
        let path = stringField(
            values,
            key: .defaultBaseStoragePath,
            maximum: SettingsLegacySnapshotReader.maximumBasePathUTF8Bytes
        )
        let confirm = booleanField(values, key: .confirmBeforeLaunch)
        let automatic = booleanField(
            values,
            key: .automaticallyRecoverCrashedApps
        )
        let appearance = stringField(
            values,
            key: .appearance,
            maximum: SettingsLegacySnapshotReader.maximumAppearanceUTF8Bytes
        )
        let identities = dataField(
            values,
            key: .profileVisualIdentities
        )

        var issues: [SettingsLegacySnapshotIssue] = []
        appendIssue(templates, key: .profileTemplates, to: &issues)
        appendIssue(
            names,
            key: .legacyProfileTemplateNames,
            to: &issues
        )
        appendIssue(path, key: .defaultBaseStoragePath, to: &issues)
        appendIssue(confirm, key: .confirmBeforeLaunch, to: &issues)
        appendIssue(
            automatic,
            key: .automaticallyRecoverCrashedApps,
            to: &issues
        )
        appendIssue(appearance, key: .appearance, to: &issues)
        appendIssue(
            identities,
            key: .profileVisualIdentities,
            to: &issues
        )
        let aggregateDataBytes = aggregateDataSize(values)
        if aggregateDataBytes
            > UInt64(
                SettingsLegacySnapshotReader.maximumAggregateDataBytes
            )
        {
            issues.append(
                .aggregateDataBytes(
                    actual: aggregateDataBytes,
                    maximum:
                        SettingsLegacySnapshotReader.maximumAggregateDataBytes
                )
            )
        }
        let expected = Set(SettingsLegacyKey.ordered.map(\.rawValue))
        let unexpectedCount = values.keys.reduce(into: 0) { count, key in
            if !expected.contains(key) {
                count += 1
            }
        }
        if unexpectedCount > 0 {
            issues.append(.unexpectedKeyCount(unexpectedCount))
        }
        return .init(
            profileTemplates: templates,
            legacyProfileTemplateNames: names,
            defaultBaseStoragePath: path,
            confirmBeforeLaunch: confirm,
            automaticallyRecoverCrashedApps: automatic,
            appearance: appearance,
            profileVisualIdentities: identities,
            completion: issues.isEmpty ? .complete : .partial(issues)
        )
    }

    static func unavailable(
        _ failure: SettingsLegacySourceFailure
    ) -> SettingsLegacySnapshot {
        .init(
            profileTemplates: .unavailable(failure),
            legacyProfileTemplateNames: .unavailable(failure),
            defaultBaseStoragePath: .unavailable(failure),
            confirmBeforeLaunch: .unavailable(failure),
            automaticallyRecoverCrashedApps: .unavailable(failure),
            appearance: .unavailable(failure),
            profileVisualIdentities: .unavailable(failure),
            completion: .partial([.source(failure)])
        )
    }

    private static func dataField(
        _ values: [String: Any],
        key: SettingsLegacyKey
    ) -> SettingsLegacyField<Data> {
        guard let raw = values[key.rawValue] else { return .absent }
        guard rawType(raw) == .data, let value = raw as? Data else {
            return .wrongType(rawType(raw))
        }
        guard value.count <= SettingsLegacySnapshotReader.maximumDataBytes
        else {
            return .oversized([
                .byteCount(
                    actual: UInt64(value.count),
                    maximum: SettingsLegacySnapshotReader.maximumDataBytes
                ),
            ])
        }
        return .retained(ownedData(value))
    }

    private static func namesField(
        _ values: [String: Any]
    ) -> SettingsLegacyField<[String]> {
        let key = SettingsLegacyKey.legacyProfileTemplateNames.rawValue
        guard let raw = values[key] else { return .absent }
        guard rawType(raw) == .array, let array = raw as? NSArray else {
            return .wrongType(rawType(raw))
        }
        let retainNames =
            array.count <= SettingsLegacySnapshotReader.maximumLegacyNames
        var names: [String] = []
        if retainNames {
            names.reserveCapacity(array.count)
        }
        var aggregate: UInt64 = 0
        var firstOversized: (index: Int, actual: Int)?
        var oversizedCount = 0
        for index in 0 ..< array.count {
            let rawName = array[index]
            guard rawType(rawName) == .string,
                  let value = rawName as? String
            else {
                return .wrongType(.array)
            }
            let name = ownedString(value)
            let count = name.utf8.count
            aggregate = saturatedAdd(aggregate, UInt64(count))
            if count
                > SettingsLegacySnapshotReader.maximumLegacyNameUTF8Bytes
            {
                oversizedCount += 1
                if firstOversized == nil {
                    firstOversized = (index, count)
                }
            }
            if retainNames {
                names.append(name)
            }
        }
        var violations: [SettingsLegacyLimitViolation] = []
        if array.count > SettingsLegacySnapshotReader.maximumLegacyNames {
            violations.append(
                .elementCount(
                    actual: array.count,
                    maximum: SettingsLegacySnapshotReader.maximumLegacyNames
                )
            )
        }
        if let firstOversized {
            violations.append(
                .stringElementUTF8Bytes(
                    firstIndex: firstOversized.index,
                    firstActual: firstOversized.actual,
                    violationCount: oversizedCount,
                    maximum:
                        SettingsLegacySnapshotReader
                            .maximumLegacyNameUTF8Bytes
                )
            )
        }
        if aggregate
            > UInt64(
                SettingsLegacySnapshotReader
                    .maximumLegacyNamesAggregateUTF8Bytes
            )
        {
            violations.append(
                .aggregateUTF8Bytes(
                    actual: aggregate,
                    maximum:
                        SettingsLegacySnapshotReader
                            .maximumLegacyNamesAggregateUTF8Bytes
                )
            )
        }
        return violations.isEmpty ? .retained(names) : .oversized(violations)
    }

    private static func stringField(
        _ values: [String: Any],
        key: SettingsLegacyKey,
        maximum: Int
    ) -> SettingsLegacyField<String> {
        guard let raw = values[key.rawValue] else { return .absent }
        guard rawType(raw) == .string, let value = raw as? String else {
            return .wrongType(rawType(raw))
        }
        let copied = ownedString(value)
        let count = copied.utf8.count
        guard count <= maximum else {
            return .oversized([
                .byteCount(actual: UInt64(count), maximum: maximum),
            ])
        }
        return .retained(copied)
    }

    private static func booleanField(
        _ values: [String: Any],
        key: SettingsLegacyKey
    ) -> SettingsLegacyField<Bool> {
        guard let raw = values[key.rawValue] else { return .absent }
        guard rawType(raw) == .boolean, let value = raw as? Bool else {
            return .wrongType(rawType(raw))
        }
        return .retained(value)
    }

    private static func aggregateDataSize(
        _ values: [String: Any]
    ) -> UInt64 {
        [
            SettingsLegacyKey.profileTemplates,
            .profileVisualIdentities,
        ].reduce(into: UInt64(0)) { total, key in
            guard let raw = values[key.rawValue],
                  rawType(raw) == .data,
                  let data = raw as? Data
            else { return }
            total = saturatedAdd(total, UInt64(data.count))
        }
    }

    private static func appendIssue<Value>(
        _ field: SettingsLegacyField<Value>,
        key: SettingsLegacyKey,
        to issues: inout [SettingsLegacySnapshotIssue]
    ) where Value: Equatable & Sendable {
        switch field {
        case .wrongType(let type):
            issues.append(.field(key: key, issue: .wrongType(type)))
        case .oversized(let violations):
            issues.append(
                .field(key: key, issue: .oversized(violations))
            )
        case .unavailable, .absent, .retained:
            break
        }
    }

    private static func ownedData(_ value: Data) -> Data {
        guard !value.isEmpty else { return Data() }
        return value.withUnsafeBytes { bytes in
            Data(bytes: bytes.baseAddress!, count: bytes.count)
        }
    }

    private static func ownedString(_ value: String) -> String {
        String(decoding: value.utf8, as: UTF8.self)
    }

    private static func rawType(_ raw: Any) -> SettingsLegacyRawType {
        let type = CFGetTypeID(raw as CFTypeRef)
        if type == CFBooleanGetTypeID() { return .boolean }
        if type == CFDataGetTypeID() { return .data }
        if type == CFStringGetTypeID() { return .string }
        if type == CFArrayGetTypeID() { return .array }
        if type == CFNumberGetTypeID() { return .number }
        if type == CFDictionaryGetTypeID() { return .dictionary }
        if type == CFDateGetTypeID() { return .date }
        return .other
    }

    private static func saturatedAdd(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
