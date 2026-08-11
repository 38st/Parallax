import Foundation

enum ProfileInstanceVisualColor:
    String,
    CaseIterable,
    Codable,
    Identifiable,
    Equatable,
    Sendable
{
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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue:
            String(localized: "Blue")
        case .purple:
            String(localized: "Purple")
        case .orange:
            String(localized: "Orange")
        case .pink:
            String(localized: "Pink")
        case .teal:
            String(localized: "Teal")
        case .green:
            String(localized: "Green")
        case .indigo:
            String(localized: "Indigo")
        case .cyan:
            String(localized: "Cyan")
        case .brown:
            String(localized: "Brown")
        case .gray:
            String(localized: "Gray")
        }
    }
}

enum ProfileInstanceVisualSymbol:
    String,
    CaseIterable,
    Codable,
    Identifiable,
    Equatable,
    Sendable
{
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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .briefcase:
            String(localized: "Work")
        case .person:
            String(localized: "Personal")
        case .flask:
            String(localized: "Research")
        case .terminal:
            String(localized: "Development")
        case .book:
            String(localized: "Study")
        case .palette:
            String(localized: "Creative")
        case .globe:
            String(localized: "Web")
        case .lightbulb:
            String(localized: "Ideas")
        case .hammer:
            String(localized: "Projects")
        case .camera:
            String(localized: "Media")
        case .music:
            String(localized: "Music")
        case .leaf:
            String(localized: "Personal growth")
        case .unmanaged:
            String(localized: "Outside Parallax")
        }
    }
}

struct ProfileInstanceVisualIdentity:
    Codable,
    Equatable,
    Sendable
{
    let symbol: ProfileInstanceVisualSymbol
    let color: ProfileInstanceVisualColor

    var systemImageName: String {
        symbol.rawValue
    }

    init(
        symbol: ProfileInstanceVisualSymbol,
        color: ProfileInstanceVisualColor
    ) {
        self.symbol = symbol
        self.color = color
    }

    init(profileID: UUID?) {
        guard let profileID else {
            symbol = .unmanaged
            color = .gray
            return
        }

        let hash = Self.stableHash(profileID)
        symbol = Self.selectableSymbols[
            Int(hash % UInt64(Self.selectableSymbols.count))
        ]
        color = Self.profileColors[
            Int(
                (hash / UInt64(Self.selectableSymbols.count))
                    % UInt64(Self.profileColors.count)
            )
        ]
    }

    static let selectableColors: [ProfileInstanceVisualColor] = [
        .blue,
        .purple,
        .orange,
        .pink,
        .teal,
        .green,
        .indigo,
        .cyan,
        .brown,
    ]

    static let selectableSymbols: [ProfileInstanceVisualSymbol] = [
        .briefcase,
        .person,
        .flask,
        .terminal,
        .book,
        .palette,
        .globe,
        .lightbulb,
        .hammer,
        .camera,
        .music,
        .leaf,
    ]

    private static let profileColors = selectableColors

    private static func stableHash(_ identifier: UUID) -> UInt64 {
        identifier.uuidString.utf8.reduce(
            UInt64(14_695_981_039_346_656_037)
        ) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
