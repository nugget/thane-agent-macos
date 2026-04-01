import SwiftUI
import SwiftData

struct ConversationListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Binding var selection: Conversation?

    var body: some View {
        List(selection: $selection) {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.conversations) { conversation in
                        ConversationRow(conversation: conversation)
                            .tag(conversation)
                    }
                    .onDelete { offsets in
                        delete(offsets, from: section.conversations)
                    }
                }
            }
        }
        .navigationTitle("Thane")
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

    // MARK: - Actions

    private func newConversation() {
        let conversation = Conversation()
        modelContext.insert(conversation)
        selection = conversation
    }

    private func delete(_ offsets: IndexSet, from conversations: [Conversation]) {
        for index in offsets {
            let conversation = conversations[index]
            if selection?.id == conversation.id {
                selection = nil
            }
            modelContext.delete(conversation)
        }
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
