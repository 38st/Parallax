import SwiftUI

private typealias CorporateAccountTrackerView =
    CorporateAccountTrackerContent
private typealias LiveAccountOverviewView =
    CorporateLiveAccountOverviewContent
private typealias LiveAccountPeopleView =
    CorporateLiveAccountPeopleContent
private typealias LiveAccountProvidersView =
    CorporateLiveAccountProvidersContent
private typealias LiveAccountActivityView =
    CorporateLiveAccountActivityContent

enum CorporateSection: String, CaseIterable, Identifiable {
    case accounts
    case overview
    case people
    case providers
    case activity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accounts: "Accounts"
        case .overview: "Overview"
        case .people: "People"
        case .providers: "Providers"
        case .activity: "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .accounts: "person.crop.rectangle.stack"
        case .overview: "chart.bar.xaxis"
        case .people: "person.2"
        case .providers: "square.stack.3d.up"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

enum WorkspaceTab: Hashable {
    case controlCenter
    case localSpaces
}

enum WorkspaceSidebarSelection: Hashable {
    case corporate(CorporateSection)
    case localSpaces
    case application(ManagedApplication.ID)
}

struct ParallaxWorkspaceView: View {
    @Bindable var store: LibraryStore
    @State private var corporateStore = CorporateUsageStore()
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedTab: WorkspaceTab = .controlCenter
    @State private var corporateSelection: CorporateSection = .accounts
    @State private var sidebarSelection: WorkspaceSidebarSelection? =
        .corporate(.accounts)

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(
                store: store,
                corporateStore: corporateStore,
                selection: $sidebarSelection
            )
            .workspaceSidebarColumn()
        } detail: {
            TabView(selection: $selectedTab) {
                CorporateControlCenterView(
                    store: corporateStore,
                    selection: $corporateSelection
                )
                    .tabItem {
                        Label("Control Center", systemImage: "building.2")
                    }
                    .tag(WorkspaceTab.controlCenter)

                LocalSpacesView(store: store)
                    .tabItem {
                        Label(
                            "Local Spaces",
                            systemImage: "macwindow.on.rectangle"
                        )
                    }
                    .tag(WorkspaceTab.localSpaces)
            }
            .onChange(of: selectedTab) { _, tab in
                synchronizeSidebar(to: tab)
            }
            .onChange(of: sidebarSelection) { _, selection in
                applySidebarSelection(selection)
            }
            .onChange(of: store.selectedApplicationID) { _, applicationID in
                guard selectedTab == .localSpaces else { return }
                sidebarSelection = applicationID.map {
                    .application($0)
                } ?? .localSpaces
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .accessibilityIdentifier("workspace.root")
    }

    private func synchronizeSidebar(to tab: WorkspaceTab) {
        switch tab {
        case .controlCenter:
            sidebarSelection = .corporate(corporateSelection)
        case .localSpaces:
            sidebarSelection = store.selectedApplicationID.map {
                .application($0)
            } ?? .localSpaces
        }
    }

    private func applySidebarSelection(
        _ selection: WorkspaceSidebarSelection?
    ) {
        guard let selection else { return }
        switch selection {
        case .corporate(let section):
            corporateSelection = section
            selectedTab = .controlCenter
        case .localSpaces:
            store.selectedApplicationID = nil
            store.selectedProfileID = nil
            selectedTab = .localSpaces
        case .application(let applicationID):
            store.selectedApplicationID = applicationID
            if !store.applications.contains(where: {
                $0.profiles.contains(where: {
                    $0.id == store.selectedProfileID
                }) && $0.id == applicationID
            }) {
                store.selectedProfileID = nil
            }
            selectedTab = .localSpaces
        }
    }
}

struct CorporateControlCenterView: View {
    @Bindable var store: CorporateUsageStore
    @Binding var selection: CorporateSection

    var body: some View {
        Group {
            switch selection {
            case .accounts:
                CorporateAccountTrackerView(store: store)
            case .overview:
                LiveAccountOverviewView(store: store)
            case .people:
                LiveAccountPeopleView(store: store)
            case .providers:
                LiveAccountProvidersView(store: store)
            case .activity:
                LiveAccountActivityView(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
