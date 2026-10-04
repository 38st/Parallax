import AppKit
import SwiftUI

enum WorkspaceSidebarMetrics {
    static let minimumWidth: CGFloat = 240
    static let idealWidth: CGFloat = 280
}

struct WorkspaceSidebarToggle: View {
    var body: some View {
        Button {
            NSApp.sendAction(
                #selector(NSSplitViewController.toggleSidebar(_:)),
                to: nil,
                from: nil
            )
        } label: {
            Label("Toggle Sidebar", systemImage: "sidebar.left")
        }
        .help("Toggle Sidebar")
        .keyboardShortcut("s", modifiers: [.control, .command])
    }
}

extension View {
    func workspaceSidebarColumn() -> some View {
        frame(minWidth: WorkspaceSidebarMetrics.minimumWidth)
        .navigationSplitViewColumnWidth(
            min: WorkspaceSidebarMetrics.minimumWidth,
            ideal: WorkspaceSidebarMetrics.idealWidth
        )
        .toolbar(removing: .sidebarToggle)
    }

    func workspaceSidebarToggle() -> some View {
        toolbar {
            ToolbarItem(placement: .navigation) {
                WorkspaceSidebarToggle()
            }
        }
    }
}
