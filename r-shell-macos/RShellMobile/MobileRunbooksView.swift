import SwiftUI

struct MobileRunbook: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let risk: MobileTaskRisk
    let variableLabel: String?
    let placeholder: String?
    let command: (String) -> String

    static let builtIns: [MobileRunbook] = [
        MobileRunbook(
            id: "tail-auth",
            title: "Inspect failed SSH logins",
            detail: "Shows recent auth failures from journalctl or auth.log.",
            systemImage: "person.badge.key",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            """
            if command -v journalctl >/dev/null 2>&1; then
              journalctl -u ssh -u sshd -n 180 --no-pager 2>&1 | grep -Ei 'failed|invalid|accepted|publickey|password' || true
            elif [ -r /var/log/auth.log ]; then
              grep -Ei 'failed|invalid|accepted|publickey|password' /var/log/auth.log | tail -180
            else
              echo "No auth log source found."
            fi
            """
        },
        MobileRunbook(
            id: "disk-growth",
            title: "Find disk growth",
            detail: "Lists large files changed recently in common writable paths.",
            systemImage: "externaldrive.badge.timemachine",
            risk: .readOnly,
            variableLabel: "Path",
            placeholder: "/var/log"
        ) { path in
            let target = path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/var/log" : path
            return """
            find \(shellQuote(target)) -xdev -type f -mtime -14 -size +20M -printf '%TY-%Tm-%Td %TH:%TM %s %p\\n' 2>/dev/null | sort -r | head -50
            """
        },
        MobileRunbook(
            id: "restart-service",
            title: "Restart systemd service",
            detail: "Restarts a named service and shows its status.",
            systemImage: "arrow.clockwise.circle",
            risk: .mutating,
            variableLabel: "Service",
            placeholder: "nginx.service"
        ) { service in
            let name = service.trimmingCharacters(in: .whitespacesAndNewlines)
            return """
            sudo -n systemctl restart \(shellQuote(name)) && systemctl --no-pager --full status \(shellQuote(name)) | sed -n '1,80p'
            """
        },
        MobileRunbook(
            id: "validate-nginx",
            title: "Validate nginx",
            detail: "Runs nginx -t and shows enabled sites.",
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
        MobileRunbook(
            id: "renew-certbot",
            title: "Dry-run cert renewal",
            detail: "Runs certbot renew --dry-run.",
            systemImage: "checkmark.seal",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            "sudo -n certbot renew --dry-run 2>&1"
        },
        MobileRunbook(
            id: "fail2ban-ban",
            title: "Ban IP with fail2ban",
            detail: "Bans an IP in the sshd jail.",
            systemImage: "hand.raised",
            risk: .dangerous,
            variableLabel: "IP address",
            placeholder: "203.0.113.10"
        ) { ip in
            "sudo -n fail2ban-client set sshd banip \(shellQuote(ip.trimmingCharacters(in: .whitespacesAndNewlines)))"
        },
        MobileRunbook(
            id: "failed-services",
            title: "List failed services",
            detail: "Shows all systemd services in failed state.",
            systemImage: "exclamationmark.triangle",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            "systemctl list-units --state=failed --no-pager --no-legend 2>/dev/null || echo 'systemctl not available'"
        },
        MobileRunbook(
            id: "disk-inodes",
            title: "Check disk inodes",
            detail: "Shows inode usage across mounted filesystems (inode exhaustion causes 'no space' errors when disk isn't full).",
            systemImage: "rectangle.stack",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            "df -i 2>/dev/null | awk 'NR==1 || $5+0 > 80 {print}' || echo 'df not available'"
        },
        MobileRunbook(
            id: "zombie-procs",
            title: "Find zombie processes",
            detail: "Lists zombie (Z-state) processes that may need parent restart.",
            systemImage: "text.badge.xmark",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            """
            ps aux 2>/dev/null | awk '$8 ~ /Z/ {print $0}' || true
            count=$(ps aux 2>/dev/null | awk '$8 ~ /Z/ {count++} END {print count}' || echo 0)
            echo ""
            if [ "$count" -eq 0 ]; then echo "No zombie processes found."; fi
            """
        },
        MobileRunbook(
            id: "listening-ports",
            title: "Show listening services",
            detail: "TCP listeners with process info (ss -tlnp).",
            systemImage: "antenna.radiowaves.left.and.right",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            "ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo 'Neither ss nor netstat available'"
        },
        MobileRunbook(
            id: "memory-pressure",
            title: "Memory pressure check",
            detail: "Shows free -h and a quick vmstat sample.",
            systemImage: "memorychip",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            """
            echo "=== Memory ==="
            free -h 2>/dev/null || vm_stat 2>/dev/null || echo "memory info unavailable"
            echo ""
            echo "=== VM snapshot (3 x 1s) ==="
            vmstat 1 3 2>/dev/null || true
            """
        },
        MobileRunbook(
            id: "cert-expiry",
            title: "Check certificate expiry",
            detail: "Shows end dates for Let's Encrypt and common certificate paths.",
            systemImage: "calendar.badge.exclamationmark",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            """
            if command -v openssl >/dev/null 2>&1; then
              echo "=== Let's Encrypt ==="
              for f in /etc/letsencrypt/live/*/cert.pem 2>/dev/null; do
                printf '%s: ' "$(basename "$(dirname "$f")")"
                openssl x509 -in "$f" -noout -enddate 2>/dev/null
              done
              echo ""
              echo "=== Other common paths ==="
              for f in /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/nginx/ssl/*.crt /etc/apache2/ssl/*.crt; do
                if [ -r "$f" ]; then
                  printf '%s: ' "$f"
                  openssl x509 -in "$f" -noout -enddate 2>/dev/null
                fi
              done
            else
              echo "openssl not available"
            fi
            """
        },
        MobileRunbook(
            id: "unattended-upgrades",
            title: "Check unattended upgrades log",
            detail: "Shows recent entries from unattended-upgrades log.",
            systemImage: "clock.arrow.2.circlepath",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            """
            if [ -r /var/log/unattended-upgrades/unattended-upgrades.log ]; then
              tail -50 /var/log/unattended-upgrades/unattended-upgrades.log
            elif [ -r /var/log/unattended-upgrades.log ]; then
              tail -50 /var/log/unattended-upgrades.log
            else
              echo "No unattended-upgrades log found."
            fi
            """
        },
        MobileRunbook(
            id: "kernel-info",
            title: "Kernel & boot info",
            detail: "Shows uname, OS release, dmesg tail, and last boot time.",
            systemImage: "gearshape.2",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            """
            echo "=== Kernel ==="
            uname -a
            echo ""
            echo "=== OS Release ==="
            cat /etc/os-release 2>/dev/null || lsb_release -a 2>/dev/null || echo "unknown"
            echo ""
            echo "=== Uptime ==="
            uptime
            echo ""
            echo "=== Last boot ==="
            who -b 2>/dev/null || uptime -s 2>/dev/null || echo "unknown"
            echo ""
            echo "=== Recent dmesg (tail 30) ==="
            dmesg -T 2>/dev/null | tail -30 || dmesg 2>/dev/null | tail -30 || echo "dmesg not readable"
            """
        },
        MobileRunbook(
            id: "user-sessions",
            title: "Active user sessions",
            detail: "Shows who/w output for all logged-in users.",
            systemImage: "person.2",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            "w 2>/dev/null || who -a 2>/dev/null || echo 'no user session info available'"
        },
        MobileRunbook(
            id: "package-history",
            title: "Recent package activity",
            detail: "Shows last 30 dpkg or dnf operations.",
            systemImage: "shippingbox.circle",
            risk: .readOnly,
            variableLabel: nil,
            placeholder: nil
        ) { _ in
            """
            if command -v dpkg >/dev/null 2>&1; then
              grep -i ' install \\| upgrade \\| remove \\| purge ' /var/log/dpkg.log 2>/dev/null | tail -30 || echo "No dpkg log"
            elif command -v dnf >/dev/null 2>&1; then
              dnf history list 2>/dev/null | head -20 || echo "No dnf history"
            elif command -v yum >/dev/null 2>&1; then
              yum history list 2>/dev/null | head -20 || echo "No yum history"
            else
              echo "Unsupported package manager"
            fi
            """
        },
    ]

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

struct MobileRunbooksView: View {
    let connectionId: String

    @ObservedObject private var savedStore = MobileSavedRunbooksStore.shared
    @ObservedObject private var historyStore = MobileRunbookHistoryStore.shared

    @State private var selected: MobileRunbook?
    @State private var variableValue = ""
    @State private var pendingRunbook: PendingMobileRunbook?
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var result: MobileRemoteTaskResult?
    @State private var customTitle = ""
    @State private var customCommand = ""
    @State private var customRisk: MobileTaskRisk = .readOnly

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            customWorkflowForm

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Built-ins")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(MobileRunbook.builtIns) { runbook in
                runbookRow(runbook)
            }

            savedSection
            historySection
        }
        .confirmationDialog(
            "Run runbook?",
            isPresented: Binding(
                get: { pendingRunbook != nil },
                set: { if !$0 { pendingRunbook = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingRunbook {
                Button(pendingRunbook.risk == .dangerous ? "Run Dangerous Action" : "Run") {
                    let runbook = pendingRunbook
                    self.pendingRunbook = nil
                    Task { await run(runbook) }
                }
            }
            Button("Cancel", role: .cancel) { pendingRunbook = nil }
        } message: {
            Text(pendingRunbook?.detail ?? "")
        }
        .sheet(item: $result) { result in
            MobileRawOutputSheet(title: result.title, command: result.command, output: result.output)
        }
    }

    private var header: some View {
        HStack {
            Label("Runbooks", systemImage: "play.rectangle")
                .font(.headline)
            Spacer()
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var customWorkflowForm: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $customTitle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                Picker("Risk", selection: $customRisk) {
                    ForEach([MobileTaskRisk.readOnly, .mutating, .dangerous], id: \.rawValue) { risk in
                        Text(risk.label).tag(risk)
                    }
                }
                .pickerStyle(.segmented)

                TextEditor(text: $customCommand)
                    .font(.caption.monospaced())
                    .frame(minHeight: 88)
                    .padding(4)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

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
                            PendingMobileRunbook(
                                id: "custom:\(UUID().uuidString)",
                                title: title,
                                detail: "Runs the command in the custom workflow editor.",
                                systemImage: "terminal",
                                risk: customRisk,
                                command: customCommand
                            )
                        )
                    }
                    .disabled(isRunning || customCommand.trimmed.isEmpty)
                }
                .controlSize(.small)
            }
            .padding(.top, 8)
        } label: {
            Label("Custom Workflow", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.medium))
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(savedStore.runbooks) { runbook in
                    savedRunbookRow(runbook)
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { historyStore.clear() }
                    .controlSize(.mini)
                    .disabled(historyStore.events.isEmpty)
            }

            if historyStore.events.isEmpty {
                Text("Runbook history is stored locally on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(historyStore.events.prefix(5), id: \.id) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: event.exitCode == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(event.exitCode == 0 ? .green : .red)
                            Text(event.title)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(event.startedAt, style: .time)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Text("exit \(event.exitCode) · \(String(format: "%.1fs", event.durationSeconds))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(event.outputPreview)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func runbookRow(_ runbook: MobileRunbook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: runbook.systemImage)
                    .foregroundStyle(runbook.risk == .dangerous ? .red : .blue)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(runbook.title)
                        .font(.subheadline.weight(.semibold))
                    Text(runbook.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(runbook.risk.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(runbook.risk == .dangerous ? .red : .secondary)
            }

            if selected?.id == runbook.id, let label = runbook.variableLabel {
                TextField(label, text: $variableValue, prompt: Text(runbook.placeholder ?? label))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button(selected?.id == runbook.id ? "Run" : "Prepare") {
                    if selected?.id == runbook.id {
                        prepare(runbook)
                    } else {
                        selected = runbook
                        variableValue = ""
                        if runbook.variableLabel == nil {
                            prepare(runbook)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || (selected?.id == runbook.id && runbook.variableLabel != nil && variableValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                if selected?.id == runbook.id {
                    Button("Cancel") {
                        selected = nil
                        variableValue = ""
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func savedRunbookRow(_ runbook: MobileSavedRunbook) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(runbook.risk == .dangerous ? .red : .blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(runbook.title)
                    .font(.subheadline.weight(.semibold))
                Text(runbook.command)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(runbook.risk.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(runbook.risk == .dangerous ? .red : .secondary)
            }

            Spacer()

            Button("Run") {
                prepare(
                    PendingMobileRunbook(
                        id: runbook.id.uuidString,
                        title: runbook.title,
                        detail: "Runs a saved custom workflow.",
                        systemImage: "terminal",
                        risk: runbook.risk,
                        command: runbook.command
                    )
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRunning)
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Delete", role: .destructive) {
                savedStore.delete(runbook)
            }
        }
    }

    private func prepare(_ runbook: MobileRunbook) {
        let item = PendingMobileRunbook(
            id: runbook.id,
            title: runbook.title,
            detail: runbook.detail,
            systemImage: runbook.systemImage,
            risk: runbook.risk,
            command: runbook.command(variableValue)
        )
        prepare(item)
    }

    private func prepare(_ item: PendingMobileRunbook) {
        if item.risk == .readOnly {
            Task { await run(item) }
        } else {
            pendingRunbook = item
        }
    }

    @MainActor
    private func run(_ runbook: PendingMobileRunbook) async {
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }

        do {
            result = try await MobileRemoteTaskRunner.shared.run(
                connectionId: connectionId,
                title: runbook.title,
                command: runbook.command,
                risk: runbook.risk
            )
            if let result {
                historyStore.record(result)
            }
            MobileActivityLogStore.shared.record(
                title: "Runbook ran",
                detail: runbook.title,
                connectionId: connectionId,
                systemImage: runbook.systemImage,
                severity: result?.succeeded == true ? .ok : .warning
            )
        } catch {
            MobileActivityLogStore.shared.record(
                title: "Runbook failed",
                detail: "\(runbook.title): \(error.localizedDescription)",
                connectionId: connectionId,
                systemImage: "exclamationmark.triangle.fill",
                severity: .critical
            )
            errorMessage = error.localizedDescription
        }
    }
}

private struct PendingMobileRunbook: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let risk: MobileTaskRisk
    let command: String
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
