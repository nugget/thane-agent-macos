import SwiftUI

struct ConsoleView: View {
    @Environment(AppState.self) private var appState

    private var manager: BinaryManager { appState.binaryManager }

    @State private var minLevel: LogLevel = .all

    enum LogLevel: String, CaseIterable {
        case all   = "All"
        case info  = "Info"
        case warn  = "Warn"
        case error = "Error"

        private static let order: [String: Int] = ["DEBUG": 0, "INFO": 1, "WARN": 2, "ERROR": 3]

        func passes(_ line: BinaryManager.LogLine) -> Bool {
            guard self != .all else { return true }
            guard let level = line.level else { return true }  // always show internal app lines
            let lineVal = Self.order[level] ?? 0
            let minVal  = Self.order[levelString] ?? 0
            return lineVal >= minVal
        }

        private var levelString: String {
            switch self {
            case .all:   "DEBUG"
            case .info:  "INFO"
            case .warn:  "WARN"
            case .error: "ERROR"
            }
        }
    }

    private var filteredLines: [BinaryManager.LogLine] {
        manager.logLines.filter { minLevel.passes($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ConsoleHeaderView(manager: manager)
            Divider()
            logView
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                controlButtons
                Divider()
                Picker("Level", selection: $minLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .help("Minimum log level to display")
                Divider()
                Button {
                    manager.clearLog()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear console")
                .disabled(manager.logLines.isEmpty)
            }
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredLines) { line in
                        Text(line.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(lineColor(line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }

                    if filteredLines.isEmpty {
                        Text(manager.logLines.isEmpty ? "No output yet." : "No lines match the current filter.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.visible)
            .background(Color.black)
            .padding(.bottom, 8)
            .onChange(of: filteredLines.count) {
                if let last = filteredLines.last {
                    withAnimation(nil) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func lineColor(_ line: BinaryManager.LogLine) -> Color {
        if line.isError || line.level == "ERROR" { return Color(red: 1,   green: 0.4, blue: 0.3) }
        if line.level == "WARN"                  { return Color(red: 1,   green: 0.8, blue: 0.2) }
        return Color(red: 0.2, green: 0.9, blue: 0.2)
    }

    @ViewBuilder
    private var controlButtons: some View {
        switch manager.state {
        case .running:
            Button("Restart") { manager.restart() }
            Button("Stop", role: .destructive) { manager.stop() }
        case .stopped, .crashed:
            Button("Start") { manager.start() }
                .disabled(manager.binaryURL == nil)
        case .starting:
            ProgressView().scaleEffect(0.7)
        case .notConfigured:
            EmptyView()
        }
    }
}

// MARK: - Header

private struct ConsoleHeaderView: View {
    let manager: BinaryManager

    var body: some View {
        HStack(spacing: 16) {
            // State indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(manager.state.label)
                    .font(.subheadline.weight(.medium))
            }

            Divider().frame(height: 16)

            // Binary info
            if let url = manager.binaryURL {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(url.lastPathComponent)
                            .font(.subheadline.weight(.medium))
                        if let version = manager.detectedVersion {
                            Text(version)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Binary not configured")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // PID + uptime
            if case .running(let pid) = manager.state {
                HStack(spacing: 12) {
                    LabeledContent("PID") {
                        Text("\(pid)")
                            .font(.system(.caption, design: .monospaced))
                    }

                    if let startedAt = manager.startedAt {
                        LabeledContent("Uptime") {
                            Text(startedAt, style: .timer)
                                .font(.system(.caption, design: .monospaced))
                                .monospacedDigit()
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var stateColor: Color {
        switch manager.state {
        case .running:   .green
        case .starting:  .yellow
        case .crashed:   .red
        case .stopped, .notConfigured: .secondary
        }
    }
}
