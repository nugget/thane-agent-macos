import SwiftUI
import SwiftData

@main
struct ThaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    private static let modelContainer: ModelContainer = {
        let schema = Schema([ServerConfig.self, Conversation.self, ChatMessage.self])
        let config = ModelConfiguration(schema: schema, url: Self.storeURL)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }()

    /// Bundle-scoped store location. The SwiftData default for non-sandboxed
    /// apps is `~/Library/Application Support/default.store`, which collides
    /// with any other non-sandboxed SwiftData app on the machine and leaves
    /// stale persistent-history state from earlier schema iterations. Anchor
    /// the store under the bundle identifier so it's ours alone.
    private static let storeURL: URL = {
        let bundleID = Bundle.main.bundleIdentifier ?? "info.nugget.thane-agent-macos"
        let dir = URL.applicationSupportDirectory.appending(component: bundleID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(component: "Data.store")
    }()

    var body: some Scene {
        WindowGroup("Thane", id: "main") {
            MainView()
                .environment(appState)
                .onAppear { appDelegate.appState = appState }
        }
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
        .modelContainer(Self.modelContainer)
        .commands {
            AboutCommands()
            ThaneCommands()
        }

        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: appState.menuBarSymbol)
        }

        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(Self.modelContainer)
        }

        Window("Process Health", id: "process-health") {
            ProcessHealthView()
                .environment(appState)
        }
        .defaultSize(width: 620, height: 620)
        .windowResizability(.contentMinSize)

        Window("Dashboard", id: "dashboard") {
            DashboardView()
                .environment(appState)
        }
        .defaultSize(width: 1024, height: 768)
        .windowResizability(.contentMinSize)

        Window("Server", id: "server") {
            ServerView()
                .environment(appState)
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)

        Window("About Thane", id: "about") {
            AboutView()
                .environment(appState)
        }
        .windowResizability(.contentSize)
    }
}

/// A small, deliberate command surface makes the app feel at home under the
/// keyboard as well as the pointer. Window shortcuts follow the familiar
/// numbered-inspector convention used by long-standing Mac utilities.
private struct ThaneCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") {
                NotificationCenter.default.post(name: .newConversation, object: nil)
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Agent") {
            Button("Server Status") {
                openWindow(id: "server")
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Web Dashboard") {
                openWindow(id: "dashboard")
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("Local Thane") {
                openWindow(id: "process-health")
            }
            .keyboardShortcut("3", modifiers: .command)
        }
    }
}

/// Replaces the standard "About" app-menu item with one that opens the custom
/// About window. Owning this through SwiftUI's command system keeps it stable
/// across menu rebuilds — an imperative AppKit menu mutation gets reverted the
/// next time SwiftUI reconstructs the main menu, which is why the previous
/// approach (rewiring the item's action in applicationDidFinishLaunching) only
/// worked on the first invocation per launch.
private struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Thane Agent") {
                openWindow(id: "about")
            }
        }
    }
}
