import SwiftUI

struct SpaceBrowserView: View {
    let space: WebSpace

    @EnvironmentObject private var store: SpaceStore
    @StateObject private var session: BrowserSession
    @State private var isConfirmingReset = false

    init(space: WebSpace) {
        self.space = space
        _session = StateObject(wrappedValue: BrowserSession(space: space))
    }

    var body: some View {
        WebViewHost(webView: session.webView)
            .safeAreaInset(edge: .top, spacing: 0) {
                if session.isLoading {
                    ProgressView(value: session.estimatedProgress)
                        .progressViewStyle(.linear)
                }
            }
            .navigationTitle(space.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        session.goBack()
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .disabled(!session.canGoBack)

                    Button {
                        session.goForward()
                    } label: {
                        Label("Forward", systemImage: "chevron.forward")
                    }
                    .disabled(!session.canGoForward)

                    Spacer()

                    Button {
                        session.reload()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }

                    Menu {
                        Button {
                            session.openStartPage()
                        } label: {
                            Label("Start Page", systemImage: "house")
                        }

                        Button(role: .destructive) {
                            isConfirmingReset = true
                        } label: {
                            Label("Sign Out and Reset", systemImage: "eraser")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog(
                "Reset \(space.name)?",
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button("Clear Cookies and Website Data", role: .destructive) {
                    store.reset(space) {
                        session.openStartPage()
                    }
                }
            } message: {
                Text("This signs this space out without affecting other spaces.")
            }
    }
}

