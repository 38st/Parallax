import SwiftUI

struct DetailView: View {
    @Bindable var store: LibraryStore
    var application: ManagedApplication

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ApplicationHeaderView(store: store, application: application)

                Divider()

                if proxy.size.width < 940 {
                    VStack(spacing: 0) {
                        ProfileListView(store: store, application: application)
                            .frame(height: min(220, max(160, proxy.size.height * 0.32)))

                        Divider()

                        profileDetail
                    }
                } else {
                    HSplitView {
                        ProfileListView(store: store, application: application)
                            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

                        profileDetail
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .clipped()
                    }
                }
            }
        }
        .navigationTitle(application.displayName)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.addProfile()
                } label: {
                    Label("Add Profile", systemImage: "person.badge.plus")
                }
                .help("Add Profile")

                Button {
                    store.launchSelectedProfile()
                } label: {
                    Label("Launch", systemImage: "play.fill")
                }
                .disabled(store.selectedProfile == nil)
                .help("Launch Selected Profile")
            }
        }
    }

    @ViewBuilder
    private var profileDetail: some View {
        if let profile = store.selectedProfile {
            ProfileEditorView(store: store, application: application, profile: profile)
        } else {
            EmptyProfileView(store: store)
        }
    }
}
