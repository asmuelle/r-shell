import SwiftUI

private enum MacRunbookRisk: String, Codable, CaseIterable, Identifiable {
    case readOnly
    case mutating
    case dangerous

    var id: String { rawValue }

    var label: String {
        switch self {
        case .readOnly: return "Read-only"
        case .mutating: return "Changes server"
        case .dangerous: return "Dangerous"
        }
    }

    var color: Color {
        switch self {
        case .readOnly: return .blue
        case .mutating: return .orange
        case .dangerous: return .red
        }
    }

    var severity: ActivitySeverity {
        switch self {
        case .readOnly: return .info
        case .mutating: return .warning
        case .dangerous: return .critical
        }
    }
}

private struct MacRunbook: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let risk: MacRunbookRisk
    let variableLabel: String?
    let placeholder: String?
    let command: (String) -> String

    static let builtIns: [MacRunbook] = [
        MacRunbook(
            id: "health",
            title: "Health snapshot",
            detail: "Kernel, uptime, memory, disk, and top processes.",
            systemImage: "waveform.path.ecg",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            """
            set +e
            echo "== Host =="
            uname -a
            echo
            echo "== Uptime =="
            uptime
            echo
            echo "== Memory =="
            if command -v free >/dev/null 2>&1; then free -h; else vm_stat 2>/dev/null || true; fi
            echo
            echo "== Disk =="
            df -h
            echo
            echo "== Top CPU =="
            ps -eo pid,user,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -15 || top -b -n 1 | head -30
            """
        },
        MacRunbook(
            id: "auth",
            title: "Inspect SSH logins",
            detail: "Recent accepted, failed, and invalid login attempts.",
            systemImage: "person.badge.key",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            """
            if command -v journalctl >/dev/null 2>&1; then
              journalctl -u ssh -u sshd -n 220 --no-pager 2>&1 | grep -Ei 'failed|invalid|accepted|publickey|password' || true
            elif [ -r /var/log/auth.log ]; then
              grep -Ei 'failed|invalid|accepted|publickey|password' /var/log/auth.log | tail -220
            else
              echo "No auth log source found."
            fi
            """
        },
        MacRunbook(
            id: "disk-growth",
            title: "Find disk growth",
            detail: "Large files changed recently under a path.",
            systemImage: "externaldrive.badge.timemachine",
            risk: .readOnly,
            variableLabel: "Path",
            placeholder: "/var/log"
        ) { path in
            let target = path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/var/log" : path
            return """
            find \(RemoteCommandRunner.shellQuote(target)) -xdev -type f -mtime -14 -size +20M -printf '%TY-%Tm-%Td %TH:%TM %s %p\\n' 2>/dev/null | sort -r | head -80
            """
        },
        MacRunbook(
            id: "restart-service",
            title: "Restart systemd service",
            detail: "Restarts one service and prints the first status lines.",
            systemImage: "arrow.clockwise.circle",
            risk: .mutating,
            variableLabel: "Service",
            placeholder: "nginx.service"
        ) { service in
            let unit = service.trimmingCharacters(in: .whitespacesAndNewlines)
            return "sudo -n systemctl restart \(RemoteCommandRunner.shellQuote(unit)) && systemctl --no-pager --full status \(RemoteCommandRunner.shellQuote(unit)) | sed -n '1,90p'"
        },
        MacRunbook(
            id: "validate-nginx",
            title: "Validate nginx",
            detail: "Runs nginx -t and lists enabled sites.",
            systemImage: "network",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            """
            nginx -t 2>&1
            printf '\\nSites enabled:\\n'
            find /etc/nginx/sites-enabled -maxdepth 1 -type l -printf '%f\\n' 2>/dev/null || true
            """
        },
        MacRunbook(
            id: "certbot-dry-run",
            title: "Dry-run cert renewal",
            detail: "Runs certbot renew --dry-run.",
            systemImage: "checkmark.seal",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            "sudo -n certbot renew --dry-run 2>&1"
        },
    ]
}

private struct SavedMacRunbook: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var command: String
    var risk: MacRunbookRisk
    var createdAt = Date()
}

private struct MacRunbookHistoryEvent: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var command: String
    var exitCode: Int
    var outputPreview: String
    var startedAt: Date
    var durationSeconds: Double
}

@MainActor
private final class SavedMacRunbooksStore: ObservableObject {
    static let shared = SavedMacRunbooksStore()

    @Published private(set) var runbooks: [SavedMacRunbook] = []

    private let key = "midnightSSH.savedMacRunbooks.v1"

    private init() {
        load()
    }

    func add(title: String, command: String, risk: MacRunbookRisk) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanCommand.isEmpty else { return }
        runbooks.insert(SavedMacRunbook(title: cleanTitle, command: cleanCommand, risk: risk), at: 0)
        save()
    }

    func delete(_ runbook: SavedMacRunbook) {
        runbooks.removeAll { $0.id == runbook.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedMacRunbook].self, from: data)
        else { return }
        runbooks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(runbooks) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

@MainActor
private final class MacRunbookHistoryStore: ObservableObject {
    static let shared = MacRunbookHistoryStore()

    @Published private(set) var events: [MacRunbookHistoryEvent] = []

    private let key = "midnightSSH.macRunbookHistory.v1"
    private let limit = 80

    private init() {
        load()
    }

    func record(title: String, command: String, result: RemoteCommandResult, startedAt: Date) {
        let preview = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(4)
            .joined(separator: "\n")

        events.insert(
            MacRunbookHistoryEvent(
                title: title,
                command: command,
                exitCode: result.exitCode,
                outputPreview: preview.isEmpty ? "(no output)" : preview,
                startedAt: startedAt,
                durationSeconds: Date().timeIntervalSince(startedAt)
            ),
            at: 0
        )
        if events.count > limit {
            events.removeLast(events.count - limit)
        }
        save()
    }

    func clear() {
        events.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([MacRunbookHistoryEvent].self, from: data)
        else { return }
        events = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct RunbooksPanelView: View {
    let connectionId: String
    let connectionLabel: String

    @ObservedObject private var savedStore = SavedMacRunbooksStore.shared
    @ObservedObject private var historyStore = MacRunbookHistoryStore.shared

    @State private var selectedRunbookId: String?
    @State private var variableValue = ""
    @State private var pending: PendingRunbook?
    @State private var runningId: String?
    @State private var result: MacRunbookRunResult?
    @State private var errorMessage: String?
    @State private var customTitle = ""
    @State private var customCommand = ""
    @State private var customRisk: MacRunbookRisk = .readOnly

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    customWorkflowForm
                    builtInSection
                    savedSection
                }
                .padding(12)
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)

            historySection
                .frame(minWidth: 280)
        }
        .confirmationDialog(
            pending?.title ?? "Run workflow?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            )
        ) {
            if let pending {
                Button(pending.risk == .dangerous ? "Run Dangerous Workflow" : "Run Workflow") {
                    let item = pending
                    self.pending = nil
                    Task { await run(item) }
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(pending?.detail ?? "")
        }
        .sheet(item: $result) { result in
            MacRunbookResultSheet(result: result)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("Runbooks", systemImage: "play.rectangle")
                    .font(.headline)
                Text(connectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if runningId != nil {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var customWorkflowForm: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $customTitle)
                    .textFieldStyle(.roundedBorder)
                Picker("Risk", selection: $customRisk) {
                    ForEach(MacRunbookRisk.allCases) { risk in
                        Text(risk.label).tag(risk)
                    }
                }
                .pickerStyle(.segmented)
                TextEditor(text: $customCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 88)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    Button("Save") {
                        savedStore.add(title: customTitle, command: customCommand, risk: customRisk)
                        customTitle = ""
                        customCommand = ""
                        customRisk = .readOnly
                    }
                    .disabled(customTitle.trimmed.isEmpty || customCommand.trimmed.isEmpty)

                    Button("Run") {
                        let title = customTitle.trimmed.isEmpty ? "Ad-hoc workflow" : customTitle.trimmed
                        prepare(
                            PendingRunbook(
                                id: "custom:\(UUID().uuidString)",
                                title: title,
                                detail: "Runs the command in the custom workflow editor.",
                                systemImage: "terminal",
                                risk: customRisk,
                                command: customCommand
                            )
                        )
                    }
                    .disabled(customCommand.trimmed.isEmpty || runningId != nil)
                }
                .controlSize(.small)
            }
            .padding(.top, 8)
        } label: {
            Label("Custom Workflow", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.medium))
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var builtInSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Built-ins")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(MacRunbook.builtIns) { runbook in
                builtInRow(runbook)
            }
        }
    }

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if savedStore.runbooks.isEmpty {
                Text("Saved custom workflows appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(savedStore.runbooks) { runbook in
                    savedRow(runbook)
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Button("Clear") { historyStore.clear() }
                    .controlSize(.small)
                    .disabled(historyStore.events.isEmpty)
            }
            .padding(12)
            Divider()

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(12)
                Divider()
            }

            if historyStore.events.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Run a workflow to build a local execution history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(historyStore.events) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: event.exitCode == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(event.exitCode == 0 ? .green : .red)
                            Text(event.title)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(event.startedAt, style: .time)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text("exit \(event.exitCode) · \(String(format: "%.1fs", event.durationSeconds))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(event.outputPreview)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    .padding(.vertical, 3)
                    .contextMenu {
                        Button("Copy Command") { RemoteCommandRunner.copy(event.command) }
                        Button("Copy Output Preview") { RemoteCommandRunner.copy(event.outputPreview) }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func builtInRow(_ runbook: MacRunbook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: runbook.systemImage)
                    .foregroundStyle(runbook.risk.color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(runbook.title)
                        .font(.caption.weight(.semibold))
                    Text(runbook.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                riskBadge(runbook.risk)
            }

            if selectedRunbookId == runbook.id, let label = runbook.variableLabel {
                TextField(label, text: $variableValue, prompt: Text(runbook.placeholder ?? label))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }

            HStack {
                Button(selectedRunbookId == runbook.id ? "Run" : "Prepare") {
                    if selectedRunbookId == runbook.id {
                        prepare(runbook)
                    } else {
                        selectedRunbookId = runbook.id
                        variableValue = ""
                        if runbook.variableLabel == nil {
                            prepare(runbook)
                        }
                    }
                }
                .disabled(runningId != nil || (selectedRunbookId == runbook.id && runbook.variableLabel != nil && variableValue.trimmed.isEmpty))

                if selectedRunbookId == runbook.id {
                    Button("Cancel") {
                        selectedRunbookId = nil
                        variableValue = ""
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func savedRow(_ runbook: SavedMacRunbook) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(runbook.risk.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(runbook.title)
                    .font(.caption.weight(.semibold))
                Text(runbook.command)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                riskBadge(runbook.risk)
            }
            Spacer()
            Button("Run") {
                prepare(
                    PendingRunbook(
                        id: runbook.id.uuidString,
                        title: runbook.title,
                        detail: "Runs a saved custom workflow.",
                        systemImage: "terminal",
                        risk: runbook.risk,
                        command: runbook.command
                    )
                )
            }
            .disabled(runningId != nil)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Copy Command") { RemoteCommandRunner.copy(runbook.command) }
            Button("Delete", role: .destructive) { savedStore.delete(runbook) }
        }
    }

    private func riskBadge(_ risk: MacRunbookRisk) -> some View {
        Text(risk.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(risk.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(risk.color.opacity(0.12), in: Capsule())
    }

    private func prepare(_ runbook: MacRunbook) {
        prepare(
            PendingRunbook(
                id: runbook.id,
                title: runbook.title,
                detail: runbook.detail,
                systemImage: runbook.systemImage,
                risk: runbook.risk,
                command: runbook.command(variableValue)
            )
        )
    }

    private func prepare(_ item: PendingRunbook) {
        if item.risk == .readOnly {
            Task { await run(item) }
        } else {
            pending = item
        }
    }

    @MainActor
    private func run(_ item: PendingRunbook) async {
        guard runningId == nil else { return }
        runningId = item.id
        errorMessage = nil
        let startedAt = Date()
        defer { runningId = nil }

        do {
            let commandResult = try await RemoteCommandRunner.runShell(
                connectionId: connectionId,
                script: item.command
            )
            historyStore.record(
                title: item.title,
                command: item.command,
                result: commandResult,
                startedAt: startedAt
            )
            ActivityLogStore.shared.record(
                title: "Runbook ran",
                detail: item.title,
                connectionId: connectionId,
                icon: item.systemImage,
                severity: commandResult.succeeded ? .success : item.risk.severity
            )
            result = MacRunbookRunResult(
                title: item.title,
                command: item.command,
                output: commandResult.output,
                exitCode: commandResult.exitCode,
                durationSeconds: Date().timeIntervalSince(startedAt)
            )
        } catch {
            ActivityLogStore.shared.record(
                title: "Runbook failed",
                detail: "\(item.title): \(error.localizedDescription)",
                connectionId: connectionId,
                icon: "exclamationmark.triangle.fill",
                severity: .critical
            )
            errorMessage = error.localizedDescription
        }
    }
}

private struct PendingRunbook: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let risk: MacRunbookRisk
    let command: String
}

private struct MacRunbookRunResult: Identifiable {
    let id = UUID()
    let title: String
    let command: String
    let output: String
    let exitCode: Int
    let durationSeconds: Double
}

private struct MacRunbookResultSheet: View {
    let result: MacRunbookRunResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    result.exitCode == 0 ? "Completed" : "Exited \(result.exitCode)",
                    systemImage: result.exitCode == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill"
                )
                .foregroundStyle(result.exitCode == 0 ? .green : .red)
                Spacer()
                Text(String(format: "%.1fs", result.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Command")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(result.command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Output")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(result.output.isEmpty ? "(no output)" : result.output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .frame(minWidth: 560, idealWidth: 720, minHeight: 400, idealHeight: 520)
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
