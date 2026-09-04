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
    @State private var compactProfileListHeight: CGFloat = 220

    var body: some View {
        GeometryReader { _ in
            VStack(spacing: 0) {
                ApplicationHeaderView(store: store, application: application)

                Divider()

                if windowWidth < Self.sideBySideWindowWidthThreshold {
                    GeometryReader { contentProxy in
                        let listHeight = CompactProfileSplitSizing
                            .listHeight(
                                requested: compactProfileListHeight,
                                availableHeight: contentProxy.size.height
                            )
                        VStack(spacing: 0) {
                            ProfileListView(
                                store: store,
                                application: application,
                                requestNewSpace: showNewSpace
                            )
                            .frame(height: listHeight)

                            CompactProfileSplitResizeHandle(
                                listHeight: listHeight,
                                availableHeight: contentProxy.size.height,
                                setListHeight: {
                                    compactProfileListHeight = $0
                                }
                            )

                            profileDetail
                                .frame(
                                    minHeight:
                                        CompactProfileSplitSizing
                                        .minimumEditorHeight,
                                    maxHeight: .infinity
                                )
                                .clipped()
                        }
                    }
                } else {
                    HSplitView {
                        ProfileListView(
                            store: store,
                            application: application,
                            requestNewSpace: showNewSpace
                        )
                            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

                        profileDetail
                            .frame(minWidth: 0, maxWidth: .infinity)
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
