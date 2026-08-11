import SwiftUI

extension ProfileInstanceVisualColor {
    var swiftUIColor: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .orange: .orange
        case .pink: .pink
        case .teal: .teal
        case .green: .green
        case .indigo: .indigo
        case .cyan: .cyan
        case .brown: .brown
        case .gray: .gray
        }
    }
}

struct ProfileInstanceIdentityPicker: View {
    @Bindable var settings: AppSettings
    let profileID: UUID?
    let profileName: String

    var body: some View {
        if let profileID {
            Menu {
                Menu("Symbol") {
                    ForEach(
                        ProfileInstanceVisualIdentity
                            .selectableSymbols
                    ) { symbol in
                        Button {
                            settings.setProfileVisualSymbol(
                                symbol,
                                for: profileID
                            )
                        } label: {
                            Label(
                                symbol.label,
                                systemImage:
                                    identity.symbol == symbol
                                    ? "checkmark"
                                    : symbol.rawValue
                            )
                        }
                    }
                }

                Menu("Color") {
                    ForEach(
                        ProfileInstanceVisualIdentity
                            .selectableColors
                    ) { color in
                        Button {
                            settings.setProfileVisualColor(
                                color,
                                for: profileID
                            )
                        } label: {
                            Label(
                                color.label,
                                systemImage:
                                    identity.color == color
                                    ? "checkmark"
                                    : "circle.fill"
                            )
                        }
                    }
                }

                if settings.hasProfileVisualIdentity(
                    for: profileID
                ) {
                    Divider()
                    Button("Use Automatic Picture") {
                        settings.resetProfileVisualIdentity(
                            for: profileID
                        )
                    }
                }
            } label: {
                ProfileInstanceIdentityMark(
                    identity: identity,
                    isTrackedSpace: true
                )
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 12))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            Color.primary,
                            Color(nsColor: .windowBackgroundColor)
                        )
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change picture for \(profileName)")
            .accessibilityLabel(
                Text("Change picture for \(profileName)")
            )
        } else {
            ProfileInstanceIdentityMark(
                identity: identity,
                isTrackedSpace: false
            )
        }
    }

    private var identity: ProfileInstanceVisualIdentity {
        guard let profileID else {
            return ProfileInstanceVisualIdentity(profileID: nil)
        }
        return settings.profileVisualIdentity(for: profileID)
    }
}

struct ProfileInstanceIdentityMark: View {
    let identity: ProfileInstanceVisualIdentity
    let isTrackedSpace: Bool

    var body: some View {
        Image(systemName: identity.systemImageName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .frame(width: 36, height: 36)
            .background(
                foregroundColor.opacity(
                    isTrackedSpace ? 0.14 : 0.08
                ),
                in: RoundedRectangle(
                    cornerRadius: 10,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: 10,
                    style: .continuous
                )
                .stroke(
                    foregroundColor.opacity(
                        isTrackedSpace ? 0.18 : 0.12
                    ),
                    lineWidth: 1
                )
            }
            .accessibilityHidden(true)
    }

    private var foregroundColor: Color {
        guard isTrackedSpace else {
            return .secondary
        }
        return identity.color.swiftUIColor
    }
}
