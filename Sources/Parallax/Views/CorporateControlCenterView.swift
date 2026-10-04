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
        case .accounts: String(localized: "Accounts")
        case .overview: String(localized: "Overview")
        case .people: String(localized: "People")
        case .providers: String(localized: "Providers")
        case .activity: String(localized: "Activity")
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

enum WorkspaceSidebarSelection: Hashable {
    case corporate(CorporateSection)
    case localSpaces
    case settings
    case application(ManagedApplication.ID)
}

struct ParallaxWorkspaceView: View {
    @Bindable var store: LibraryStore
    @Bindable var corporateStore: CorporateUsageStore
    @Bindable var corporateAccountOperationCoordinator: CorporateAccountOperationCoordinator
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var corporateSelection: CorporateSection = .accounts
    @State private var sidebarSelection: WorkspaceSidebarSelection? = .localSpaces

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(store: store, corporateStore: corporateStore, selection: $sidebarSelection)
                .workspaceSidebarColumn()
        } detail: {
            Group {
                switch sidebarSelection {
                case .settings:
                    WorkspaceSettingsView(store: store, corporateStore: corporateStore, operations: corporateAccountOperationCoordinator)
                case .corporate(.activity):
                    WorkspaceActivityView(store: store, corporateStore: corporateStore)
                case .corporate:
                    CorporateControlCenterView(store: corporateStore, operationCoordinator: corporateAccountOperationCoordinator,
                        selection: $corporateSelection,
                        recreateCodexSpaces: { store.synchronizeCodexAccountSpaces(accounts: corporateStore.trackedAccounts, recreateRemovedSpaces: true) })
                default:
                    LocalSpacesView(store: store, corporateStore: corporateStore)
                }
            }

        }
        .navigationSplitViewStyle(.prominentDetail)
        .onAppear { synchronizeSidebar(to: store.sceneCoordinator.selectedWorkspaceTab) }
        .onChange(of: store.sceneCoordinator.selectedWorkspaceTab) { _, tab in synchronizeSidebar(to: tab) }
        .onChange(of: sidebarSelection) { _, selection in applySidebarSelection(selection) }
        .onChange(of: store.selectedApplicationID) { _, applicationID in
            if applicationID != nil { store.sceneCoordinator.selectedWorkspaceTab = .localSpaces }
            guard store.sceneCoordinator.selectedWorkspaceTab == .localSpaces else { return }
            sidebarSelection = applicationID.map { .application($0) } ?? .localSpaces
        }
        .onChange(of: store.sceneCoordinator.requestedApplicationPage, initial: true) { _, applicationID in
            guard let applicationID else { return }
            sidebarSelection = .application(applicationID)
            store.sceneCoordinator.requestedApplicationPage = nil
        }
        .accessibilityIdentifier("workspace.root")
    }

    private func synchronizeSidebar(to tab: WorkspaceTab) {
        switch tab {
        case .controlCenter: sidebarSelection = .corporate(corporateSelection)
        case .localSpaces: sidebarSelection = store.selectedApplicationID.map { .application($0) } ?? .localSpaces
        }
    }

    private func applySidebarSelection(_ selection: WorkspaceSidebarSelection?) {
        guard let selection else { return }
        switch selection {
        case .settings: break
        case .corporate(let section):
            corporateSelection = section
            store.sceneCoordinator.selectedWorkspaceTab = .controlCenter
        case .localSpaces:
            store.selectedApplicationID = nil
            store.selectedProfileID = nil
            store.sceneCoordinator.selectedWorkspaceTab = .localSpaces
        case .application(let applicationID):
            store.selectedApplicationID = applicationID
            store.sceneCoordinator.selectedWorkspaceTab = .localSpaces
        }
    }
}

struct CorporateControlCenterView: View {
    @Bindable var store: CorporateUsageStore
    @Bindable var operationCoordinator:
        CorporateAccountOperationCoordinator
    @Binding var selection: CorporateSection
    var recreateCodexSpaces: (() -> Void)? = nil

    var body: some View {
        Group {
            switch selection {
            case .accounts:
                CorporateAccountTrackerView(
                    store: store,
                    operationCoordinator: operationCoordinator,
                    recreateCodexSpaces: recreateCodexSpaces
                )
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
