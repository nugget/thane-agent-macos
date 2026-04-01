import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var configs: [ServerConfig]

    @State private var serverURL = ""
    @State private var token = ""
    @State private var showToken = false

    private var config: ServerConfig? {
        configs.first(where: \.isDefault)
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $serverURL, prompt: Text("http://192.168.1.100:8080"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveConfig)

                HStack {
                    if showToken {
                        TextField("API Token", text: $token)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("API Token", text: $token)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        showToken.toggle()
                    } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section("Connection") {
                HStack {
                    Label(appState.statusText, systemImage: appState.isConnected ? "circle.fill" : "circle")
                        .foregroundStyle(appState.isConnected ? .green : .secondary)

                    Spacer()

                    if appState.isConnected {
                        Button("Disconnect") {
                            appState.disconnect()
                        }
                    } else {
                        Button("Connect") {
                            saveConfig()
                            connectToServer()
                        }
                        .disabled(serverURL.isEmpty || token.isEmpty)
                    }
                }

                if let error = appState.connection.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                if let providerID = appState.connection.providerID {
                    LabeledContent("Provider ID", value: providerID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .padding()
        .onAppear(perform: loadConfig)
    }

    private func loadConfig() {
        if let config {
            serverURL = config.urlString
            token = appState.loadToken(for: config) ?? ""
        }
    }

    private func saveConfig() {
        let cfg: ServerConfig
        if let existing = config {
            existing.urlString = serverURL
            cfg = existing
        } else {
            cfg = ServerConfig(name: "Default", urlString: serverURL)
            modelContext.insert(cfg)
        }
        if !token.isEmpty {
            appState.saveToken(token, for: cfg)
        }
        try? modelContext.save()
    }

    private func connectToServer() {
        guard let config else { return }
        appState.connect(config: config)
    }
}
