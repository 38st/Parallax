import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}

@main
struct ParallaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
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
                .alert(
                    "Import Library",
                    isPresented: $store.isShowingImportChoice
                ) {
                    Button("Merge with Existing") { store.confirmImport(replacing: false) }
                    Button("Replace Existing", role: .destructive) { store.confirmImport(replacing: true) }
                    Button("Cancel", role: .cancel) { store.cancelImport() }
                } message: {
                    Text("Replace discards your current library. Merge adds imported applications and profiles without removing existing ones.")
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Add Application") {
                    store.beginAddingApplication()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
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
