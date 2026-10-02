import SwiftUI

/// A library overview for the sidebar's All Spaces destination. Browsing this
/// view keeps selection nil; only choosing an app or space changes selection.
struct AllSpacesView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("All Spaces")
                    .font(.title2.bold())
                Spacer()
                Text(LocalizedCount.spaces(store.applications.reduce(0) {
                    $0 + $1.profiles.count
                }))
                .foregroundStyle(.secondary)
            }
            .padding(20)

            List {
                ForEach(store.applications) { application in
                    Section {
                        Button {
                            store.selectedApplicationID = application.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: application.appPath))
                                    .resizable()
                                    .frame(width: 28, height: 28)
                                Text(application.displayName)
                                    .font(.headline)
                                Spacer()
                                Text(LocalizedCount.spaces(application.profiles.count))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("all-spaces.application.\(application.id.uuidString)")

                        ForEach(application.profiles) { profile in
                            Button {
                                store.selectedApplicationID = application.id
                                store.selectedProfileID = profile.id
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "macwindow")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28)
                                    Text(profile.name)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("all-spaces.profile.\(profile.id.uuidString)")
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .accessibilityIdentifier("all-spaces.overview")
    }
}
