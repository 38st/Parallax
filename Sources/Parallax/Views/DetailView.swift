import SwiftUI

struct DetailView: View {
    @Bindable var store: LibraryStore
    var application: ManagedApplication
    let presentationState: LibraryPresentationState
    let windowWidth: CGFloat
    var corporateStore: CorporateUsageStore? = nil
    @State private var pendingLaunch: LaunchProfile?
    @State private var isShowingNewSpace = false
    @State private var preferredTemplateID: ProfileTemplate.ID?

    var body: some View {
        VStack(spacing: 0) {
            ApplicationHeaderView(store: store, application: application)
            Divider()
            ProfileListView(store: store, application: application, requestNewSpace: showNewSpace,
                corporateStore: corporateStore)
            SpaceOperationStatusView(store: store).padding(12)
        }
        .navigationTitle(application.displayName)
        .sheet(isPresented: $isShowingNewSpace, onDismiss: {
            if let profile = pendingLaunch { pendingLaunch = nil; store.launch(profile) }
        }) {
            NewSpaceView(store: store, application: application, preferredTemplateID: preferredTemplateID,
                openCreatedSpace: { pendingLaunch = $0 })
        }
    }

    private func showNewSpace(preferredTemplateID: ProfileTemplate.ID?) {
        self.preferredTemplateID = preferredTemplateID
        isShowingNewSpace = true
    }
}

struct ProfileSplitLayout<Content: View>: View {
    let isCompact: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        let layout = isCompact
            ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(spacing: 0))
        layout { content() }
    }
}
