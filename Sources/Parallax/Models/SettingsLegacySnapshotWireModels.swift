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
