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

// MARK: - Identity

struct IdentityPanel: View {
    @Environment(AppState.self) private var appState
    private var manager: IdentityManager { appState.identityManager }

    var body: some View {
        ServerPanelContainer(
            title: "Identity",
            isLoading: manager.isLoading && manager.evidence == nil,
            error: manager.evidence == nil ? manager.lastError : nil,
            retry: { await manager.refresh(appState.nativeClient) }
        ) {
            if let evidence = manager.evidence { content(evidence) }
        }
        .task { manager.start { appState.nativeClient } }
        .onDisappear { manager.stop() }
        .toolbar {
            Button {
                Task { await manager.refresh(appState.nativeClient) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh identity evidence")
        }
    }

    private func content(_ evidence: IdentityEvidence) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                identityHeader(evidence)
                verificationSection(evidence)
                coreSection(evidence)
                publicMaterialSection(evidence)

                Text("This is locally verified evidence reported by Thane, not a remote trust verdict.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private func identityHeader(_ evidence: IdentityEvidence) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: evidenceIsVerified(evidence) ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 24))
                .foregroundStyle(evidenceIsVerified(evidence) ? Color.green : Color.orange)
                .frame(width: 42, height: 42)
                .background(
                    (evidenceIsVerified(evidence) ? Color.green : Color.orange).opacity(0.12),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(evidence.instance.name)
                    .font(.title2.weight(.semibold))
                Text(evidence.instance.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(evidenceIsVerified(evidence) ? "Local evidence checks passed" : "Local evidence needs attention")
                    .font(.callout)
                    .foregroundStyle(evidenceIsVerified(evidence) ? .green : .orange)
            }
            Spacer()
        }
    }

    private func verificationSection(_ evidence: IdentityEvidence) -> some View {
        GroupBox("Verification Evidence") {
            VStack(alignment: .leading, spacing: 10) {
                verificationRow("Birth Admission", evidence.core.verification.admission)
                Divider()
                verificationRow("Active Core", evidence.core.verification.head)
                if !evidence.core.head.worktreeClean {
                    Divider()
                    Label("Tracked core content differs from HEAD.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.top, 4)
        }
    }

    private func verificationRow(_ title: String, _ check: IdentityVerificationCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.isVerified ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(check.isVerified ? .green : .red)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private func coreSection(_ evidence: IdentityEvidence) -> some View {
        GroupBox("Core Provenance") {
            VStack(alignment: .leading, spacing: 10) {
                evidenceRow("Founding posture", anchorLabel(evidence.core.birth.anchor))
                Divider()
                objectRow("Birth commit", evidence.core.birth.commit)
                evidenceRow(
                    "Asserted birth",
                    "\(ServerFormat.relative(evidence.core.birth.assertedAt)) · signed claim"
                )
                Divider()
                objectRow("Current commit", evidence.core.currentCommit)
                evidenceRow("Worktree", evidence.core.head.worktreeClean ? "Clean" : "Modified")
                evidenceRow("Trust-file revisions", "\(evidence.core.head.trustFileChangeCount)")
                Divider()
                evidenceRow("Observed", ServerFormat.relative(evidence.observedAt))
                evidenceRow("Evidence schema", "\(evidence.schemaVersion)")
            }
            .padding(.top, 4)
        }
    }

    private func publicMaterialSection(_ evidence: IdentityEvidence) -> some View {
        GroupBox("Founding Public Material") {
            VStack(alignment: .leading, spacing: 10) {
                materialRow("Identity key", evidence.instance.identityKey)
                Divider()
                materialRow("Channel CA", evidence.instance.channelCA)
            }
            .padding(.top, 4)
        }
    }

    private func materialRow(_ title: String, _ material: PublicIdentityMaterial) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(material.algorithm).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(material.fingerprint)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func objectRow(_ title: String, _ object: GitObjectID) -> some View {
        evidenceRow(title, "\(object.algorithm):\(object.oid)")
    }

    private func evidenceRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    private func evidenceIsVerified(_ evidence: IdentityEvidence) -> Bool {
        evidence.core.verification.admission.isVerified
            && evidence.core.verification.head.isVerified
            && evidence.core.head.worktreeClean
    }

    private func anchorLabel(_ anchor: String) -> String {
        switch anchor {
        case "operator": "Operator anchored"
        case "self_signed": "Self-signed"
        case "unknown": "Unknown"
        default: anchor.replacingOccurrences(of: "_", with: " ").capitalized
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
                    StatCard(label: "Messages", value: ServerFormat.compact(stats.messageCount), icon: "tray.full")
                    StatCard(label: "Requests", value: ServerFormat.compact(stats.totalRequests), icon: "number")
                    StatCard(label: "Est. cost", value: ServerFormat.usd(stats.estimatedCostUSD), icon: "dollarsign.circle")
                }
                HStack(spacing: 20) {
                    StatCard(label: "Input", value: ServerFormat.compact(stats.totalInputTokens), icon: "arrow.down.circle")
                    StatCard(label: "Output", value: ServerFormat.compact(stats.totalOutputTokens), icon: "arrow.up.circle")
                    StatCard(label: "Cache hit", value: ServerFormat.percent(stats.cacheHitRate), icon: "bolt.horizontal")
                }

                // Context-window utilization, with the raw token counts (the
                // percentage alone reads as "empty" on a fresh, low-token session).
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Context window", systemImage: "gauge.with.dots.needle.67percent")
                        Spacer()
                        Text("\(ServerFormat.compact(stats.contextTokens)) / \(stats.contextWindow > 0 ? ServerFormat.compact(stats.contextWindow) : "—")")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if stats.contextWindow > 0 {
                        ProgressView(
                            value: Double(min(max(stats.contextTokens, 0), stats.contextWindow)),
                            total: Double(stats.contextWindow))
                    }
                }
                .padding(.horizontal, 4)

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
