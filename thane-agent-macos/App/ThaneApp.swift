import SwiftUI
import SwiftData

@main
struct ThaneApp: App {
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

        Window("Console", id: "console") {
            ConsoleView()
                .environment(appState)
        }
        .defaultSize(width: 660, height: 420)
        .windowResizability(.contentMinSize)
    }
}
