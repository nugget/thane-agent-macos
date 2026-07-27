import SwiftUI
import SwiftData

struct ConversationListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Binding var selection: Conversation?
    @State private var searchText = ""

    var body: some View {
        List(selection: $selection) {
            ForEach(filteredSections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.conversations) { conversation in
                        ConversationRow(conversation: conversation)
                            .tag(conversation)
                            .contextMenu {
                                Button("Delete Conversation", systemImage: "trash", role: .destructive) {
                                    delete(conversation)
                                }
                            }
                    }
                    .onDelete { offsets in
                        delete(offsets, from: section.conversations)
                    }
                }
            }
        }
        .navigationTitle("Thane")
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search Conversations")
        .overlay {
            if conversations.isEmpty {
                ContentUnavailableView {
                    Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start a conversation with Thane.")
                } actions: {
                    Button("New Conversation", action: newConversation)
                        .buttonStyle(.borderedProminent)
                }
            } else if filteredSections.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            connectionFooter
        }
        .onReceive(NotificationCenter.default.publisher(for: .newConversation)) { _ in
            newConversation()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: newConversation) {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Conversation (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private var connectionFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: appState.isConnected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(appState.isConnected ? .green : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(appState.statusText)
                    .font(.caption.weight(.medium))
                Text(connectionDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var connectionDetail: String {
        if appState.activeServer?.isLocal == true {
            return "Local Mac"
        }
        if let host = appState.activeServer?.baseURL.host {
            return host
        }
        if case .needsAttention = appState.binaryManager.state {
            return "Local core needs attention"
        }
        return "No active server"
    }

    // MARK: - Sections

    private struct ConversationSection {
        let title: String
        let conversations: [Conversation]
    }

    private var sections: [ConversationSection] {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!
        let weekStart = calendar.date(byAdding: .day, value: -7, to: todayStart)!

        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var lastWeek: [Conversation] = []
        var older: [Conversation] = []

        for conversation in conversations {
            if conversation.updatedAt >= todayStart {
                today.append(conversation)
            } else if conversation.updatedAt >= yesterdayStart {
                yesterday.append(conversation)
            } else if conversation.updatedAt >= weekStart {
                lastWeek.append(conversation)
            } else {
                older.append(conversation)
            }
        }

        return [
            ("Today", today),
            ("Yesterday", yesterday),
            ("Last 7 Days", lastWeek),
            ("Older", older),
        ]
        .filter { !$0.1.isEmpty }
        .map { ConversationSection(title: $0.0, conversations: $0.1) }
    }

    private var filteredSections: [ConversationSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let matches = section.conversations.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                || $0.sortedMessages.contains { $0.content.localizedCaseInsensitiveContains(query) }
            }
            return matches.isEmpty ? nil : ConversationSection(title: section.title, conversations: matches)
        }
    }

    // MARK: - Actions

    private func newConversation() {
        let conversation = Conversation()
        modelContext.insert(conversation)
        selection = conversation
    }

    private func delete(_ offsets: IndexSet, from conversations: [Conversation]) {
        for index in offsets {
            delete(conversations[index])
        }
    }

    private func delete(_ conversation: Conversation) {
        if selection?.id == conversation.id {
            selection = nil
        }
        modelContext.delete(conversation)
    }
}

// MARK: - Row

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title)
                .lineLimit(1)
                .font(.body)

            Text(conversation.updatedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
