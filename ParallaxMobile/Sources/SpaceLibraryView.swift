import SwiftUI

struct SpaceLibraryView: View {
    @EnvironmentObject private var store: SpaceStore
    @State private var isPresentingNewSpace = false

    private let columns = [
        GridItem(.adaptive(minimum: 155), spacing: 14),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.spaces.isEmpty {
                    ContentUnavailableView(
                        "No spaces yet",
                        systemImage: "square.grid.2x2",
                        description: Text(
                            "Create a space for each account you want to keep separate."
                        )
                    )
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(store.spaces) { space in
                            NavigationLink(value: space) {
                                SpaceCard(space: space)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.delete(space)
                                } label: {
                                    Label("Delete Space", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Spaces")
            .navigationDestination(for: WebSpace.self) { space in
                SpaceBrowserView(space: space)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingNewSpace = true
                    } label: {
                        Label("New Space", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingNewSpace) {
                NewSpaceView()
            }
        }
    }
}

private struct SpaceCard: View {
    let space: WebSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: space.service.systemImage)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 3) {
                Text(space.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(space.service.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 22)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22))
    }

    private var tint: Color {
        switch space.service {
        case .instagram: .pink
        case .chatGPT: .teal
        case .custom: .blue
        }
    }
}

