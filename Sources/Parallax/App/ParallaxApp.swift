import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ParallaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var store: LibraryStore

    init() {
        let settings = AppSettings()
        _settings = State(wrappedValue: settings)
        _store = State(wrappedValue: LibraryStore(settings: settings))
    }

    var body: some Scene {
        WindowGroup("Parallax", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(colorScheme(for: settings.appearance))
                .alert(
                    "Launch profile?",
                    isPresented: $store.isShowingLaunchConfirmation
                ) {
                    Button("Launch", role: .none) { store.confirmLaunch() }
                    Button("Cancel", role: .cancel) { store.cancelLaunch() }
                } message: {
                    if let name = store.pendingLaunchProfileName {
                        Text("Launch “\(name)”?")
                    } else {
                        Text("Launch the selected profile?")
                    }
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Application") {
                    store.beginAddingApplication()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }

            CommandMenu("Library") {
                Button("Import Library...") {
                    store.importLibrary()
                }

                Button("Export Library...") {
                    store.exportLibrary()
                }
            }
        }

        Settings {
            SettingsView(settings: settings)
        }
    }

    private func colorScheme(for appearance: AppAppearance) -> ColorScheme? {
        switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
