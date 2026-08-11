import SwiftUI

struct RelayTaskDetailView: View {
    let task: RelayTaskPresentation
    let actions: RelayWorkspaceActions

    @State private var selectedSection: RelayTaskDetailSection = .progress
    @State private var selectedBaton: RelayBatonPresentation?
    @State private var pendingGateDenial: RelayHumanGatePresentation?
    @State private var isConfirmingStop = false

    var body: some View {
        VStack(spacing: 0) {
            RelayTaskHeaderView(
                task: task,
                pause: { actions.pause(task.id) },
                resume: { actions.resume(task.id) },
                retry: { actions.retry(task.id) },
                requestStop: { isConfirmingStop = true }
            )

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(task.pendingGates) { gate in
                        RelayHumanGateCard(
                            gate: gate,
                            taskID: task.id,
                            approve: {
                                actions.approveGate(task.id, gate.id)
                            },
                            requestDenial: {
                                pendingGateDenial = gate
                            }
                        )
                    }

                    if task.recovery != .none {
                        RelayRecoveryCard(
                            recovery: task.recovery,
                            taskID: task.id,
                            action: { actions.recover(task.id) }
                        )
                    }

                    Picker("Relay Detail", selection: $selectedSection) {
                        ForEach(RelayTaskDetailSection.allCases) { section in
                            Text(section.label).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier(
                        RelayAccessibilityIdentifier.detailSection
                    )

                    sectionContent
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .navigationTitle(task.summary.title)
        .inspector(isPresented: batonInspectorPresentation) {
            if let selectedBaton {
                RelayBatonInspector(baton: selectedBaton)
                    .inspectorColumnWidth(
                        min: 300,
                        ideal: 360,
                        max: 480
                    )
            }
        }
        .sheet(item: $pendingGateDenial) { gate in
            RelayGateDenialView(
                gate: gate,
                cancel: { pendingGateDenial = nil },
                deny: { reason in
                    actions.denyGate(task.id, gate.id, reason)
                    pendingGateDenial = nil
                }
            )
        }
        .confirmationDialog(
            "Stop this relay?",
            isPresented: $isConfirmingStop,
            titleVisibility: .visible
        ) {
            Button("Stop Relay", role: .destructive) {
                actions.stop(task.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Parallax will preserve the relay ledger, worktree, and captured evidence. External actions that already completed cannot be undone."
            )
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .progress:
            RelayProgressView(
                task: task,
                showBaton: { selectedBaton = $0 }
            )
        case .findings:
            RelayFindingsView(findings: task.findings)
        case .evidence:
            RelayEvidenceView(evidence: task.evidence)
        }
    }

    private var batonInspectorPresentation: Binding<Bool> {
        Binding(
            get: { selectedBaton != nil },
            set: { isPresented in
                if !isPresented { selectedBaton = nil }
            }
        )
    }
}

private struct RelayTaskHeaderView: View {
    let task: RelayTaskPresentation
    let pause: () -> Void
    let resume: () -> Void
    let retry: () -> Void
    let requestStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.summary.title)
                        .font(.title2.bold())
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)

                    Text(task.summary.objective)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 16)

                headerActions
            }

            HStack(spacing: 8) {
                RelayStatusBadge(
                    label: task.summary.executionStatus.label,
                    systemImage: task.summary.executionStatus.systemImage,
                    tone: task.summary.executionStatus.tone,
                    accessibilityIdentifier:
                        RelayAccessibilityIdentifier.executionStatus(task.id)
                )
                .accessibilityHint(
                    Text(
                        task.summary.executionStatus.accessibilityDescription
                    )
                )

                RelayStatusBadge(
                    label: task.summary.deliveryStatus.label,
                    systemImage: task.summary.deliveryStatus.systemImage,
                    tone: task.summary.deliveryStatus.tone,
                    accessibilityIdentifier:
                        RelayAccessibilityIdentifier.deliveryStatus(task.id)
                )

                Text(task.summary.lastVerifiedLabel())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 5) {
                Text(task.summary.repositoryName)
                    .fontWeight(.medium)
                if let branch = task.summary.branchName {
                    Text("·")
                    Text(branch)
                        .fontDesign(.monospaced)
                }
                if let stage = task.summary.currentStageLabel {
                    Text("·")
                    Text(
                        String(
                            format: String(localized: "Current stage: %@"),
                            stage
                        )
                    )
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: 8) {
            switch task.summary.executionStatus {
            case .running:
                Button("Pause", action: pause)
                    .accessibilityIdentifier(
                        RelayAccessibilityIdentifier.pause(task.id)
                    )
            case .paused:
                Button("Resume", action: resume)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        RelayAccessibilityIdentifier.resume(task.id)
                    )
            case .failed, .interrupted, .stalled:
                Button("Retry Stage", action: retry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(
                        Text("Creates a new attempt and preserves prior evidence")
                    )
                    .accessibilityIdentifier(
                        RelayAccessibilityIdentifier.retry(task.id)
                    )
            case .draft, .queued, .starting, .needsUser, .pausing,
                 .recovering, .blocked, .stopped, .completed:
                EmptyView()
            }

            if canStop {
                Button("Stop…", role: .destructive, action: requestStop)
                    .accessibilityIdentifier(
                        RelayAccessibilityIdentifier.stop(task.id)
                    )
            }
        }
    }

    private var canStop: Bool {
        switch task.summary.executionStatus {
        case .queued, .starting, .running, .needsUser, .pausing, .paused,
             .recovering, .stalled, .interrupted:
            true
        case .draft, .blocked, .failed, .stopped, .completed:
            false
        }
    }
}

private struct RelayRecoveryCard: View {
    let recovery: RelayRecoveryPresentation
    let taskID: UUID
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: recovery.systemImage)
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                if let title = recovery.title {
                    Text(title)
                        .font(.headline)
                }
                if let detail = recovery.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 12)

            if case .reconciling = recovery {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Reconciling relay state"))
            } else if let actionLabel = recovery.actionLabel {
                Button(actionLabel, action: action)
                    .accessibilityIdentifier(
                        RelayAccessibilityIdentifier.recoveryAction(taskID)
                    )
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}
