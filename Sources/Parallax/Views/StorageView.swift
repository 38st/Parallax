import SwiftUI

struct StorageView: View {
    @Bindable var model: AppModel
    @State private var measuring = false
    @State private var cleaning = false
    @State private var removingVM: Space?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Storage").font(.largeTitle.weight(.semibold))
                        Text("Every 6 hours, Parallax deletes chat backups older than 14 days, and VM images and simulator builds that a closed Claude space hasn't used in 14 days.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if measuring || cleaning { ProgressView().controlSize(.small) }
                    Button {
                        Task {
                            cleaning = true
                            defer { cleaning = false }
                            await model.cleanUpNow()
                        }
                    } label: {
                        Label("Clean Up Now", systemImage: "sparkles")
                    }
                    .disabled(cleaning)
                }

                HStack(spacing: 24) {
                    Total(title: "All spaces", bytes: model.storage.values.reduce(0) { $0 + $1.total })
                    Total(title: "VM images", bytes: model.storage.values.reduce(0) { $0 + $1.vmImage })
                    Total(title: "Chat backups", bytes: model.backupStorage ?? 0)
                }

                ForEach(model.apps.filter { !$0.spaces.isEmpty }) { app in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            AppIcon(path: app.path).frame(width: 20, height: 20)
                            Text(app.name).font(.headline)
                        }
                        ForEach(app.spaces.sorted { (model.storage[$0.id]?.total ?? 0) > (model.storage[$1.id]?.total ?? 0) }) { space in
                            SpaceStorageRow(space: space, storage: model.storage[space.id], running: model.running[space.id] != nil,
                                            removeVM: app.kind == .claude ? { removingVM = space } : nil)
                        }
                    }
                }
                Text("Chat sizes count every copy in full. Copies Parallax carried between spaces may share disk space, so the real total can be lower.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .navigationTitle("Storage")
        .task {
            measuring = true
            defer { measuring = false }
            model.refreshRunning()
            await model.measureStorage()
        }
        .confirmationDialog(
            "Remove \(removingVM?.name ?? "this space")'s VM image?",
            isPresented: Binding(get: { removingVM != nil }, set: { if !$0 { removingVM = nil } }),
            presenting: removingVM
        ) { space in
            Button("Remove VM Image", role: .destructive) { Task { await model.removeVMImage(space.id) } }
        } message: { _ in
            Text("Claude downloads it again, about 1 GB, the next time this space needs its VM. Chats aren't affected.")
        }
    }
}

private struct Total: View {
    var title: String
    var bytes: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bytes, format: .byteCount(style: .file)).font(.title2.monospacedDigit().weight(.semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SpaceStorageRow: View {
    var space: Space
    var storage: SpaceStorage?
    var running: Bool
    var removeVM: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RunningDot(running: running)
            VStack(alignment: .leading, spacing: 3) {
                Text(space.name).font(.body.weight(.medium))
                if let storage {
                    Text(parts(storage)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Measuring…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let storage {
                Text(storage.total, format: .byteCount(style: .file)).monospacedDigit()
                if let removeVM, storage.vmImage > 0 {
                    Button("Remove VM Image", action: removeVM)
                        .disabled(running)
                        .help(running ? "Quit this space first" : "Free \(storage.vmImage.formatted(.byteCount(style: .file)))")
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func parts(_ storage: SpaceStorage) -> String {
        [("VM image", storage.vmImage), ("chats", storage.chats), ("build caches", storage.buildCaches), ("other", storage.other)]
            .filter { $0.1 > 0 }
            .map { "\($0.0) \($0.1.formatted(.byteCount(style: .file)))" }
            .joined(separator: " · ")
    }
}
