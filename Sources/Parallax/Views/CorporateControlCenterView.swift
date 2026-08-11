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

private enum CorporateSection: String, CaseIterable, Identifiable {
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

struct ParallaxWorkspaceView: View {
    @Bindable var store: LibraryStore
    @Bindable var relayStore: RelayAppStore
    @State private var corporateStore = CorporateUsageStore()

    var body: some View {
        TabView {
            CorporateControlCenterView(store: corporateStore)
                .tabItem {
                    Label("Control Center", systemImage: "building.2")
                }

            LocalSpacesView(store: store)
                .tabItem {
                    Label("Local Spaces", systemImage: "macwindow.on.rectangle")
                }

            RelayWorkspaceView(
                tasks: relayStore.presentations,
                selection: $relayStore.selection,
                actions: relayStore.actions
            )
            .tabItem {
                Label("Relays", systemImage: "arrow.forward.square")
            }
        }
        .accessibilityIdentifier("workspace.root")
        .task {
            relayStore.reload()
        }
        .sheet(isPresented: $relayStore.isShowingIntake) {
            RelayIntakeView(
                draft: $relayStore.intakeDraft,
                repositoryValidationMessage:
                    relayStore.repositoryValidationMessage,
                isSubmitting: relayStore.isSubmitting,
                chooseRepository: relayStore.chooseRepository,
                cancel: { relayStore.isShowingIntake = false },
                start: { _ in relayStore.startRelay() }
            )
        }
        .alert(
            "Relay Needs Attention",
            isPresented: Binding(
                get: { relayStore.failureMessage != nil },
                set: { if !$0 { relayStore.dismissFailure() } }
            )
        ) {
            Button("OK") { relayStore.dismissFailure() }
        } message: {
            Text(relayStore.failureMessage ?? "")
        }
    }
}

struct CorporateControlCenterView: View {
    @Bindable var store: CorporateUsageStore
    @State private var selection: CorporateSection? = .accounts

    var body: some View {
        NavigationSplitView {
            List(CorporateSection.allCases, selection: $selection) { section in
                Label(section.label, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("Parallax")
            .safeAreaInset(edge: .bottom) {
                organizationFooter
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            Group {
                switch selection ?? .accounts {
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
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var organizationFooter: some View {
        let connectedCount = store.trackedAccounts.filter {
            $0.isConnected == true
        }.count
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.16))
                Image(systemName: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("Account tracking")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(connectedCount) of \(store.trackedAccounts.count) connected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.bar)
    }
}
