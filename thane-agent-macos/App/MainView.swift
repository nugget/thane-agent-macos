import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            List {
                Section("Status") {
                    Label(appState.statusText, systemImage: appState.isConnected ? "circle.fill" : "circle")
                        .foregroundStyle(appState.isConnected ? .green : .secondary)
                }
            }
            .navigationTitle("Thane")
        } detail: {
            ContentUnavailableView(
                "No Conversation Selected",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Select or start a conversation to begin chatting.")
            )
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
