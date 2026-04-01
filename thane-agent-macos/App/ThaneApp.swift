import SwiftUI
import SwiftData

@main
struct ThaneApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(appState)
        }
        .modelContainer(for: ServerConfig.self)

        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: appState.menuBarSymbol)
        }

        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(for: ServerConfig.self)
        }
    }
}
