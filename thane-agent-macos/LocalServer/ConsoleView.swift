import SwiftUI

struct ConsoleView: View {
    @Environment(AppState.self) private var appState

    // Approximate width for 80 monospaced chars at 12pt (~7.2pt/char + padding)
    private let consoleWidth: CGFloat = 606

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(appState.binaryManager.logLines) { line in
                        Text(line.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(line.isError ? Color(red: 1, green: 0.4, blue: 0.3) : Color(red: 0.2, green: 0.9, blue: 0.2))
                            .textSelection(.enabled)
                            .frame(width: consoleWidth, alignment: .leading)
                            .id(line.id)
                    }

                    if appState.binaryManager.logLines.isEmpty {
                        Text("No output yet.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
            }
            .background(Color.black)
            .frame(minWidth: consoleWidth + 20, minHeight: 200)
            .onChange(of: appState.binaryManager.logLines.count) {
                if let last = appState.binaryManager.logLines.last {
                    withAnimation(nil) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.binaryManager.clearLog()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear console")
                .disabled(appState.binaryManager.logLines.isEmpty)
            }
        }
    }
}
