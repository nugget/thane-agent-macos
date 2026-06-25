import SwiftUI

// The five native data panels. Each reads its `@Observable` manager from
// `AppState`, starts polling in `.task`, and stops on `.onDisappear` so only the
// visible panel hits the server.

// MARK: - System

struct SystemStatusPanel: View {
    @Environment(AppState.self) private var appState
    private var manager: SystemStatusManager { appState.systemStatusManager }

    var body: some View {
        ServerPanelContainer(
            title: "System",
            isLoading: manager.isLoading && manager.status == nil,
            error: manager.status == nil ? manager.lastError : nil,
            retry: { await manager.refresh(appState.nativeClient) }
        ) {
            if let status = manager.status { content(status) }
        }
        .task { manager.start { appState.nativeClient } }
        .onDisappear { manager.stop() }
    }

    @ViewBuilder private func content(_ status: SystemStatus) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 20) {
                    StatCard(label: "Uptime", value: ServerFormat.uptime(status.uptimeSeconds), icon: "clock")
                    StatCard(label: "Version", value: status.version?["version"] ?? "—", icon: "number")
                    StatCard(label: "Services", value: "\(status.health?.count ?? 0)", icon: "square.stack.3d.up")
                }

                if let health = status.health, !health.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Services").font(.headline)
                        ForEach(health.sorted(by: { $0.key < $1.key }), id: \.key) { _, service in
                            HStack(spacing: 8) {
                                Image(systemName: service.ready ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(service.ready ? .green : .red)
                                Text(service.name)
                                Spacer()
                                if let lastError = service.lastError, !service.ready {
                                    Text(lastError)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Sessions

struct SessionsPanel: View {
    @Environment(AppState.self) private var appState
    private var manager: SessionsManager { appState.sessionsManager }

    var body: some View {
        ServerPanelContainer(
            title: "Sessions",
            isLoading: manager.isLoading && manager.stats == nil,
            error: manager.stats == nil ? manager.lastError : nil,
            retry: { await manager.refresh(appState.nativeClient) }
        ) {
            if let stats = manager.stats { content(stats) }
        }
        .task { manager.start { appState.nativeClient } }
        .onDisappear { manager.stop() }
    }

    @ViewBuilder private func content(_ stats: SessionStats) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 20) {
                    StatCard(label: "Input", value: ServerFormat.compact(stats.totalInputTokens), icon: "arrow.down.circle")
                    StatCard(label: "Output", value: ServerFormat.compact(stats.totalOutputTokens), icon: "arrow.up.circle")
                    StatCard(label: "Requests", value: "\(stats.totalRequests)", icon: "number")
                }
                HStack(spacing: 20) {
                    StatCard(label: "Est. cost", value: ServerFormat.usd(stats.estimatedCostUSD), icon: "dollarsign.circle")
                    StatCard(label: "Cache hit", value: ServerFormat.percent(stats.cacheHitRate), icon: "bolt.horizontal")
                    StatCard(
                        label: "Context",
                        value: ServerFormat.percent(Double(stats.contextTokens) / Double(max(stats.contextWindow, 1))),
                        icon: "gauge.with.dots.needle.67percent")
                }

                if let balance = stats.reportedBalanceUSD {
                    HStack {
                        Label("Reported balance", systemImage: "creditcard")
                        Spacer()
                        Text(ServerFormat.usd(balance)).monospacedDigit()
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Loops

struct LoopsPanel: View {
    @Environment(AppState.self) private var appState
    private var manager: LoopsManager { appState.loopsManager }

    var body: some View {
        ServerPanelContainer(
            title: "Loops",
            isLoading: manager.isLoading && !manager.loaded,
            error: manager.loaded ? nil : manager.lastError,
            isEmpty: manager.loaded && manager.loops.isEmpty,
            emptyLabel: "No Active Loops",
            emptyIcon: "arrow.triangle.2.circlepath",
            retry: { await manager.refresh(appState.nativeClient) }
        ) {
            List(manager.loops) { loop in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(loop.name).font(.headline)
                        Spacer()
                        Text(loop.state)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(stateColor(loop.state).opacity(0.2), in: Capsule())
                            .foregroundStyle(stateColor(loop.state))
                    }
                    HStack(spacing: 12) {
                        Label("\(loop.iterations) iters", systemImage: "repeat")
                        Label(ServerFormat.compact(loop.totalInputTokens + loop.totalOutputTokens) + " tok", systemImage: "number")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let lastError = loop.lastError {
                        Text(lastError).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .task { manager.start { appState.nativeClient } }
        .onDisappear { manager.stop() }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "processing": .green
        case "error": .red
        case "stopped": .orange
        default: .secondary
        }
    }
}

// MARK: - Conversations

struct ConversationsPanel: View {
    @Environment(AppState.self) private var appState
    private var manager: ConversationsManager { appState.conversationsManager }

    var body: some View {
        ServerPanelContainer(
            title: "Conversations",
            isLoading: manager.isLoading && !manager.loaded,
            error: manager.loaded ? nil : manager.lastError,
            isEmpty: manager.loaded && manager.conversations.isEmpty,
            emptyLabel: "No Conversations",
            emptyIcon: "bubble.left.and.bubble.right",
            retry: { await manager.loadFirstPage(appState.nativeClient) }
        ) {
            List {
                ForEach(manager.conversations) { conversation in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(conversation.channelBinding?.contactName ?? conversation.id).font(.headline)
                            Spacer()
                            Text("\(conversation.messageCount)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let channel = conversation.channelBinding?.channel {
                            Text(channel).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if manager.canLoadMore {
                    Button("Load more…") {
                        Task { await manager.loadMore(appState.nativeClient) }
                    }
                }
            }
        }
        .task { if !manager.loaded { await manager.loadFirstPage(appState.nativeClient) } }
        .toolbar {
            Button {
                Task { await manager.loadFirstPage(appState.nativeClient) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }
}

// MARK: - Schedules

struct SchedulesPanel: View {
    @Environment(AppState.self) private var appState
    private var manager: SchedulesManager { appState.schedulesManager }

    var body: some View {
        ServerPanelContainer(
            title: "Schedules",
            isLoading: manager.isLoading && !manager.loaded,
            error: manager.loaded ? nil : manager.lastError,
            isEmpty: manager.loaded && manager.tasks.isEmpty,
            emptyLabel: "No Scheduled Tasks",
            emptyIcon: "calendar.badge.clock",
            retry: { await manager.refresh(appState.nativeClient) }
        ) {
            List(manager.tasks) { task in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(task.name).font(.headline)
                        Spacer()
                        if !task.enabled {
                            Text("disabled").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 12) {
                        Label(ServerFormat.schedule(task.schedule), systemImage: "clock")
                        if let nextRun = task.nextRun {
                            Label("next " + ServerFormat.relative(nextRun), systemImage: "calendar")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .task { manager.start { appState.nativeClient } }
        .onDisappear { manager.stop() }
    }
}

// MARK: - Logs

struct LogsPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var manager = appState.logsManager
        ServerPanelContainer(
            title: "Logs",
            isLoading: manager.isLoading && !manager.loaded,
            error: manager.loaded ? nil : manager.lastError,
            isEmpty: manager.loaded && manager.entries.isEmpty,
            emptyLabel: "No Log Entries",
            emptyIcon: "doc.text.magnifyingglass",
            retry: { await manager.refresh(appState.nativeClient) }
        ) {
            List(manager.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.level)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(levelColor(entry.level))
                            .frame(width: 46, alignment: .leading)
                        Text(entry.msg).font(.callout).lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Text(ServerFormat.relative(entry.ts))
                        if let subsystem = entry.subsystem { Text(subsystem) }
                        if let loop = entry.loopName { Text(loop) }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
            }
        }
        .task { if !manager.loaded { await manager.refresh(appState.nativeClient) } }
        .onChange(of: manager.level) {
            Task { await manager.refresh(appState.nativeClient) }
        }
        .toolbar {
            Picker("Level", selection: $manager.level) {
                ForEach(LogLevelFilter.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.menu)
            Button {
                Task { await manager.refresh(appState.nativeClient) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }

    private func levelColor(_ level: String) -> Color {
        switch level.uppercased() {
        case "ERROR": .red
        case "WARN": .orange
        case "DEBUG", "TRACE": .secondary
        default: .primary
        }
    }
}
