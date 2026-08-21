import SwiftUI

@MainActor
struct RelayWorkspaceActions {
    var newRelay: () -> Void = {}
    var pause: (UUID) -> Void = { _ in }
    var resume: (UUID) -> Void = { _ in }
    var stop: (UUID) -> Void = { _ in }
    var retry: (UUID) -> Void = { _ in }
    var recover: (UUID) -> Void = { _ in }
    var approveGate: (UUID, UUID) -> Void = { _, _ in }
    var denyGate: (UUID, UUID, String) -> Void = { _, _, _ in }
}

struct RelayWorkspaceView: View {
    let tasks: [RelayTaskPresentation]
    @Binding var selection: RelayTaskPresentation.ID?
    @Binding var sidebarVisibility: NavigationSplitViewVisibility
    let actions: RelayWorkspaceActions

    @State private var searchText = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            RelayTaskSidebarView(
                tasks: filteredTasks,
                selection: $selection,
                newRelay: actions.newRelay
            )
            .workspaceSidebarColumn()
        } detail: {
            if let selectedTask {
                RelayTaskDetailView(task: selectedTask, actions: actions)
                    .id(selectedTask.id)
            } else if tasks.isEmpty {
                ContentUnavailableView {
                    Label("No Relays", systemImage: "arrow.forward.square")
                } description: {
                    Text(
                        "Give Relay a repository task and supervise its verified handoffs."
                    )
                } actions: {
                    Button("New Relay…", action: actions.newRelay)
                        .accessibilityIdentifier(
                            RelayAccessibilityIdentifier.newRelay
                        )
                }
            } else {
                ContentUnavailableView(
                    "Select a Relay",
                    systemImage: "sidebar.left",
                    description: Text(
                        "Choose a relay to review its progress, findings, and evidence."
                    )
                )
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .searchable(
            text: $searchText,
            placement: .sidebar,
            prompt: Text("Search Relays")
        )
        .accessibilityIdentifier(RelayAccessibilityIdentifier.workspace)
    }

    private var selectedTask: RelayTaskPresentation? {
        tasks.first { $0.id == selection }
    }

    private var filteredTasks: [RelayTaskPresentation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tasks }
        return tasks.filter {
            $0.summary.title.localizedCaseInsensitiveContains(query)
                || $0.summary.repositoryName.localizedCaseInsensitiveContains(query)
                || $0.summary.objective.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct RelayTaskSidebarView: View {
    let tasks: [RelayTaskPresentation]
    @Binding var selection: RelayTaskPresentation.ID?
    let newRelay: () -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(RelayTaskListGroup.allCases, id: \.self) { group in
                let groupedTasks = tasksForGroup(group)
                if !groupedTasks.isEmpty {
                    Section(group.label) {
                        ForEach(groupedTasks) { task in
                            RelayTaskSidebarRow(task: task)
                                .tag(task.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Relays")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: newRelay) {
                    Label("New Relay", systemImage: "plus")
                }
                .help("New Relay")
                .accessibilityIdentifier(RelayAccessibilityIdentifier.newRelay)
            }
        }
        .workspaceSidebarToggle()
    }

    private func tasksForGroup(
        _ group: RelayTaskListGroup
    ) -> [RelayTaskPresentation] {
        tasks.filter { $0.summary.listGroup == group }
            .sorted { lhs, rhs in
                lhs.summary.updatedAt > rhs.summary.updatedAt
            }
    }
}

private struct RelayTaskSidebarRow: View {
    let task: RelayTaskPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: task.summary.executionStatus.systemImage)
                    .foregroundStyle(
                        relayColor(for: task.summary.executionStatus.tone)
                    )
                    .accessibilityHidden(true)
                Text(task.summary.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if task.summary.executionStatus == .needsUser {
                    Text("Needs You")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            Text(task.summary.repositoryName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 4) {
                Text(task.summary.executionStatus.label)
                if let stage = task.summary.currentStageLabel {
                    Text("·")
                    Text(stage)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(task.summary.accessibilityLabel())
        .accessibilityHint(Text("Show this relay"))
        .accessibilityIdentifier(
            RelayAccessibilityIdentifier.task(task.id)
        )
    }
}
