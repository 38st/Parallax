import SwiftUI

struct DetailView: View {
    // Use the whole window for this decision so toggling the 280-point
    // Apps sidebar cannot also rearrange the detail view mid-animation.
    private static let sideBySideWindowWidthThreshold: CGFloat = 1_220

    @Bindable var store: LibraryStore
    var application: ManagedApplication
    let presentationState: LibraryPresentationState
    let windowWidth: CGFloat
    @State private var isShowingNewSpace = false
    @State private var preferredTemplateID:
        ProfileTemplate.ID?

    var body: some View {
        GeometryReader { _ in
            VStack(spacing: 0) {
                ApplicationHeaderView(store: store, application: application)

                Divider()

                GeometryReader { contentProxy in
                    let isCompact = windowWidth < Self.sideBySideWindowWidthThreshold
                    let listHeight = CompactProfileSplitSizing.listHeight(
                        requested: store.sceneCoordinator.compactProfileListHeight,
                        availableHeight: contentProxy.size.height
                    )
                    // AnyLayout preserves the list, editor and sheet identities
                    // while changing only how those same children are arranged.
                    ProfileSplitLayout(isCompact: isCompact) {
                        ProfileListView(
                            store: store,
                            application: application,
                            requestNewSpace: showNewSpace
                        )
                        .frame(
                            width: isCompact ? nil : store.sceneCoordinator.profileListWidth,
                            height: isCompact ? listHeight : nil
                        )

                        CompactProfileSplitResizeHandle(
                            listHeight: isCompact ? listHeight : store.sceneCoordinator.profileListWidth,
                            availableHeight: contentProxy.size.height,
                            setListHeight: {
                                if isCompact {
                                    store.sceneCoordinator.compactProfileListHeight = $0
                                } else {
                                    store.sceneCoordinator.profileListWidth = $0
                                }
                            },
                            isCompact: isCompact
                        )

                        profileDetail
                            .frame(
                                minWidth: 0, maxWidth: .infinity,
                                minHeight: isCompact ? CompactProfileSplitSizing.minimumEditorHeight : nil,
                                maxHeight: .infinity
                            )
                            .clipped()
                    }
                }
            }
        }
        .navigationTitle(application.displayName)
        .sheet(isPresented: $isShowingNewSpace) {
            NewSpaceView(
                store: store,
                application: application,
                preferredTemplateID: preferredTemplateID
            )
        }
    }

    @ViewBuilder
    private var profileDetail: some View {
        if let profile = selectedProfile {
            ProfileEditorView(store: store, application: application, profile: profile)
                .id(profile.id)
        } else if case let .selectedApplicationHasNoProfiles(applicationID) =
            presentationState,
            applicationID == application.id
        {
            EmptyApplicationProfilesView(
                hasTemplates: !store.profileTemplates.isEmpty,
                requestNewSpace: showNewSpace
            )
        } else {
            NoSpaceSelectedView()
        }
    }

    private var selectedProfile: LaunchProfile? {
        guard
            case let .profileSelected(applicationID, profileID) =
                presentationState,
            applicationID == application.id
        else {
            return nil
        }
        return application.profiles.first { $0.id == profileID }
    }

    private func showNewSpace(
        preferredTemplateID: ProfileTemplate.ID?
    ) {
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
