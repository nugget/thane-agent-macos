import SwiftUI
import SwiftData

@main
struct ThaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    private static let modelContainer: ModelContainer = {
        let schema = Schema([ServerConfig.self, Conversation.self, ChatMessage.self])
        let config = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
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
