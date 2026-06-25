import SwiftUI

/// The native "Server" window: a sidebar of sections backed by the Thane Native
/// API, mirroring `MainView`'s split layout. Complements (does not replace) the
/// web Dashboard.
struct ServerView: View {
    @Environment(AppState.self) private var appState
    @State private var section: ServerSection? = .system

    var body: some View {
        Group {
            if appState.activeServer == nil {
                ContentUnavailableView {
                    Label("Not Connected", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text("Connect to a Thane server to view its status.")
                }
            } else {
                NavigationSplitView {
                    List(selection: $section) {
                        ForEach(ServerSection.allCases) { item in
                            Label(item.title, systemImage: item.icon).tag(item)
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 170, ideal: 190)
                } detail: {
                    detail
                }
            }
        }
        .frame(minWidth: 680, minHeight: 440)
    }

    @ViewBuilder private var detail: some View {
        switch section ?? .system {
        case .system: SystemStatusPanel()
        case .sessions: SessionsPanel()
        case .loops: LoopsPanel()
        case .conversations: ConversationsPanel()
        case .schedules: SchedulesPanel()
        case .logs: LogsPanel()
        }
    }
}

enum ServerSection: String, CaseIterable, Identifiable {
    case system, sessions, loops, conversations, schedules, logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .sessions: "Sessions"
        case .loops: "Loops"
        case .conversations: "Conversations"
        case .schedules: "Schedules"
        case .logs: "Logs"
        }
    }

    var icon: String {
        switch self {
        case .system: "server.rack"
        case .sessions: "gauge.with.dots.needle.67percent"
        case .loops: "arrow.triangle.2.circlepath"
        case .conversations: "bubble.left.and.bubble.right"
        case .schedules: "calendar.badge.clock"
        case .logs: "doc.text.magnifyingglass"
        }
    }
}

/// Shared loading / error / empty / content scaffold for the panels. Keeps the
/// three non-content states consistent and sets the navigation title.
struct ServerPanelContainer<Content: View>: View {
    let title: String
    let isLoading: Bool
    let error: String?
    var isEmpty: Bool = false
    var emptyLabel: String = ""
    var emptyIcon: String = "tray"
    let retry: () async -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label("Couldn’t Load \(title)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await retry() } }
                }
            } else if isEmpty {
                ContentUnavailableView(emptyLabel, systemImage: emptyIcon)
            } else {
                content()
            }
        }
        .navigationTitle(title)
    }
}
