import SwiftUI

struct ContentView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let application = store.selectedApplication {
                DetailView(store: store, application: application)
            } else {
                EmptyLibraryView(store: store)
            }
        }
        .fileImporter(
            isPresented: $store.isShowingAppImporter,
            allowedContentTypes: [.applicationBundle],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.addApplication(at: url)
            }
        }
        .alert(
            "Parallax could not complete the action",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK") {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}
