import SwiftUI
import UIKit

struct MobileSnippetsView: View {
    let connectionId: String
    let profileName: String

    @State private var search = ""
    @State private var serviceName = ""
    @State private var isRunning = false
    @State private var runningId: String?
    @State private var result: MobileSnippetResult?
    @State private var pendingCommand: MobilePendingSnippetCommand?

    private let snippets = MobileSnippet.defaultSnippets

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            TextField("Filter snippets", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                ForEach(filteredSnippets) { snippet in
                    snippetButton(snippet)
                }
            }

            destructiveSection
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .sheet(item: $result) { result in
            MobileSnippetResultView(result: result)
        }
        .confirmationDialog(
            pendingCommand?.title ?? "Confirm Action",
            isPresented: Binding(
                get: { pendingCommand != nil },
                set: { if !$0 { pendingCommand = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingCommand {
                Button(pendingCommand.confirmTitle, role: .destructive) {
                    let command = pendingCommand
                    self.pendingCommand = nil
                    Task { await run(title: command.title, command: command.command, id: command.id) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingCommand = nil
            }
        } message: {
            Text(pendingCommand?.message ?? "")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("Snippets", systemImage: "command")
                    .font(.headline)
                Text(profileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func snippetButton(_ snippet: MobileSnippet) -> some View {
        Button {
            Task { await run(snippet) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: snippet.systemImage)
                    .font(.headline)
                    .foregroundStyle(snippet.tint)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(snippet.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(snippet.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if runningId == snippet.id {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
    }

    private var destructiveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Confirmed Actions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("service name, e.g. nginx.service", text: $serviceName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                Button {
                    confirmRestartService()
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(isRunning || normalizedServiceName.isEmpty)
            }

            Text("Restart uses sudo -n systemctl and will fail unless the server allows it without an interactive password.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var filteredSnippets: [MobileSnippet] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return snippets }
        return snippets.filter {
            $0.title.lowercased().contains(needle)
                || $0.subtitle.lowercased().contains(needle)
        }
    }

    private var normalizedServiceName: String {
        serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ snippet: MobileSnippet) async {
        await run(title: snippet.title, command: snippet.command, id: snippet.id)
    }

    @MainActor
    private func run(title: String, command: String, id: String) async {
        guard !isRunning else { return }

        isRunning = true
        runningId = id
        defer {
            isRunning = false
            runningId = nil
        }

        do {
            let output = try await MobileMonitorBridge.shared.executeCommand(
                connectionId: connectionId,
                command: command
            )
            result = MobileSnippetResult(
                title: title,
                command: command,
                output: output.isEmpty ? "(no output)" : output,
                error: nil
            )
        } catch {
            result = MobileSnippetResult(
                title: title,
                command: command,
                output: "",
                error: error.localizedDescription
            )
        }
    }

    private func confirmRestartService() {
        let name = normalizedServiceName
        guard !name.isEmpty else { return }
        pendingCommand = MobilePendingSnippetCommand(
            id: "restart-service:\(name)",
            title: "Restart \(name)",
            confirmTitle: "Restart Service",
            message: "This will run sudo -n systemctl restart \(name) on \(profileName).",
            command: "sudo -n systemctl restart \(shellQuote(name)) && systemctl status --no-pager --lines=20 \(shellQuote(name))"
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

private struct MobileSnippet: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let command: String

    static let defaultSnippets: [MobileSnippet] = [
        MobileSnippet(
            id: "health",
            title: "Health Snapshot",
            subtitle: "Kernel, uptime, memory, disk, and top CPU processes.",
            systemImage: "waveform.path.ecg",
            tint: .green,
            command: """
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
            df -h /
            echo
            echo "== Top CPU =="
            ps -eo pid,user,pcpu,pmem,comm,args --sort=-pcpu 2>/dev/null | head -n 10 || ps aux | head -n 10
            """
        ),
        MobileSnippet(
            id: "warnings",
            title: "Recent Warnings",
            subtitle: "Tail warning and error logs with journal/syslog fallback.",
            systemImage: "exclamationmark.triangle",
            tint: .orange,
            command: """
            set +e
            if command -v journalctl >/dev/null 2>&1; then
              journalctl -p warning -n 120 --no-pager -o short-iso 2>&1
            elif [ -r /var/log/syslog ]; then
              tail -n 120 /var/log/syslog
            elif [ -r /var/log/system.log ]; then
              tail -n 120 /var/log/system.log
            else
              echo "No readable log source found."
            fi
            """
        ),
        MobileSnippet(
            id: "firewall",
            title: "Inspect Firewall",
            subtitle: "UFW numbered status and recent blocked sources.",
            systemImage: "shield.lefthalf.filled",
            tint: .blue,
            command: """
            set +e
            if command -v ufw >/dev/null 2>&1; then
              echo "== UFW Status =="
              sudo -n ufw status numbered 2>&1
              echo
              echo "== Recent UFW Blocks =="
              if sudo -n test -r /var/log/ufw.log 2>/dev/null; then
                sudo -n tail -n 80 /var/log/ufw.log 2>/dev/null
              elif command -v journalctl >/dev/null 2>&1; then
                sudo -n journalctl -k -n 120 --no-pager 2>/dev/null | grep -E '\\[UFW (BLOCK|DENY)\\]' | tail -n 80
              else
                echo "No readable UFW log source found."
              fi
            else
              echo "ufw is not installed."
            fi
            """
        ),
        MobileSnippet(
            id: "ports",
            title: "Listening Ports",
            subtitle: "Show TCP/UDP listeners and owning processes when available.",
            systemImage: "point.3.connected.trianglepath.dotted",
            tint: .cyan,
            command: """
            set +e
            if command -v ss >/dev/null 2>&1; then
              sudo -n ss -tulpen 2>/dev/null || ss -tulpen 2>/dev/null || ss -tuln
            elif command -v netstat >/dev/null 2>&1; then
              sudo -n netstat -tulpen 2>/dev/null || netstat -an | grep -E 'LISTEN|UDP'
            else
              echo "No ss or netstat command found."
            fi
            """
        ),
        MobileSnippet(
            id: "failed-services",
            title: "Failed Services",
            subtitle: "List failed systemd units and recent status details.",
            systemImage: "xmark.octagon",
            tint: .red,
            command: """
            set +e
            if command -v systemctl >/dev/null 2>&1; then
              systemctl --failed --no-pager
              echo
              for unit in $(systemctl --failed --no-legend --plain | awk '{print $1}' | head -n 5); do
                echo "== $unit =="
                systemctl status --no-pager --lines=16 "$unit"
              done
            else
              echo "systemctl is not available on this host."
            fi
            """
        ),
        MobileSnippet(
            id: "docker",
            title: "Docker Snapshot",
            subtitle: "Containers, stats, and recent images.",
            systemImage: "shippingbox",
            tint: .purple,
            command: """
            set +e
            if command -v docker >/dev/null 2>&1; then
              echo "== Containers =="
              docker ps -a
              echo
              echo "== Stats =="
              docker stats --no-stream 2>/dev/null || true
              echo
              echo "== Images =="
              docker images | head -n 20
            else
              echo "docker is not installed."
            fi
            """
        ),
        MobileSnippet(
            id: "postgres",
            title: "PostgreSQL Snapshot",
            subtitle: "Version, sessions, locks, and database sizes.",
            systemImage: "cylinder.split.1x2",
            tint: .indigo,
            command: """
            set +e
            if ! command -v psql >/dev/null 2>&1; then
              echo "psql is not installed."
              exit 0
            fi
            run_psql() {
              psql -Atq -d postgres -c "$1" 2>&1 || sudo -n -u postgres psql -Atq -d postgres -c "$1" 2>&1
            }
            echo "== Version =="
            run_psql "select version();"
            echo
            echo "== Connections =="
            run_psql "select count(*)::text || '/' || current_setting('max_connections') from pg_stat_activity;"
            echo
            echo "== Waiting Locks =="
            run_psql "select count(*) from pg_locks where not granted;"
            echo
            echo "== Database Sizes =="
            run_psql "select datname || E'\\t' || pg_size_pretty(pg_database_size(datname)) from pg_database where datistemplate=false order by pg_database_size(datname) desc limit 10;"
            """
        ),
    ]
}

private struct MobilePendingSnippetCommand: Identifiable {
    let id: String
    let title: String
    let confirmTitle: String
    let message: String
    let command: String
}

private struct MobileSnippetResult: Identifiable {
    let id = UUID()
    let title: String
    let command: String
    let output: String
    let error: String?
}

private struct MobileSnippetResultView: View {
    let result: MobileSnippetResult

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                if let error = result.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(result.command)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(4)
                }

                ScrollView {
                    Text(result.output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding()
            .navigationTitle(result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = result.error ?? result.output
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }
}
