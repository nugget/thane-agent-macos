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
        WindowGroup {
            MainView()
                .environment(appState)
                .onAppear { appDelegate.appState = appState }
        }
        .modelContainer(Self.modelContainer)

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
        .defaultSize(width: 400, height: 300)
        .windowResizability(.contentMinSize)

        Window("Dashboard", id: "dashboard") {
            DashboardView()
                .environment(appState)
        }
        .defaultSize(width: 1024, height: 768)
        .windowResizability(.contentMinSize)

        Window("About Thane", id: "about") {
            AboutView()
                .environment(appState)
        }
        .windowResizability(.contentSize)
    }
}
