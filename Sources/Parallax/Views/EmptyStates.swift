import SwiftUI

struct EmptyLibraryView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        ContentUnavailableView {
            Label("No Applications", systemImage: "rectangle.stack.badge.plus")
        } description: {
            Text("Add an app to create isolated launch profiles.")
        } actions: {
            Button("Add Application") {
                store.beginAddingApplication()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct EmptyProfileView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        ContentUnavailableView {
            Label("No Profile Selected", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("Create a profile to launch this app with profile-specific arguments and environment.")
        } actions: {
            Button("Add Profile") {
                store.addProfile()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
