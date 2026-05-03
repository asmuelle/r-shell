import SwiftUI

struct MobileServiceInspection: Identifiable, Hashable {
    let id = UUID()
    let service: String
    let title: String
    let severity: MobileFindingSeverity
    let summary: String
    let output: String
}

struct MobileServiceInspectorView: View {
    let connectionId: String

    @State private var inspections: [MobileServiceInspection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedInspection: MobileServiceInspection?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if inspections.isEmpty, !isLoading {
                Text("Run service inspection to detect common Linux services and surface useful operational views.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(inspections) { inspection in
                    Button {
                        selectedInspection = inspection
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(for: inspection.service))
                                .foregroundStyle(inspection.severity.color)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(inspection.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    MobileSeverityBadge(severity: inspection.severity)
                                }
                                Text(inspection.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(10)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(item: $selectedInspection) { inspection in
            MobileRawOutputSheet(title: inspection.title, command: nil, output: inspection.output)
        }
        .task(id: connectionId) {
            await refresh()
        }
    }

    private var header: some View {
        HStack {
            Label("Service Inspector", systemImage: "server.rack")
                .font(.headline)
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
        }
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await MobileRemoteTaskRunner.shared.run(
                connectionId: connectionId,
                title: "Service Inspection",
                command: Self.inspectionCommand
            )
            inspections = parse(result.output)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func parse(_ output: String) -> [MobileServiceInspection] {
        output
            .components(separatedBy: "\n__MIDNIGHT_SERVICE__ ")
            .compactMap { chunk -> MobileServiceInspection? in
                let normalized = chunk.hasPrefix("__MIDNIGHT_SERVICE__ ")
                    ? String(chunk.dropFirst("__MIDNIGHT_SERVICE__ ".count))
                    : chunk
                let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                guard let header = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !header.isEmpty,
                      header != "__MIDNIGHT_SERVICE_INSPECTION_BEGIN__" else { return nil }
                let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                let service = header.lowercased()
                return MobileServiceInspection(
                    service: service,
                    title: title(for: service),
                    severity: severity(for: service, output: body),
                    summary: summary(for: service, output: body),
                    output: body
                )
            }
            .sorted { lhs, rhs in
                if lhs.severity.rank != rhs.severity.rank {
                    return lhs.severity.rank < rhs.severity.rank
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    private func title(for service: String) -> String {
        switch service {
        case "ssh": return "SSH"
        case "ufw": return "UFW Firewall"
        case "nginx": return "Nginx"
        case "certbot": return "Certbot"
        case "fail2ban": return "Fail2ban"
        case "postfix": return "Postfix"
        case "dovecot": return "Dovecot"
        case "containerd": return "Container Runtime"
        case "apparmor": return "AppArmor"
        case "chrony": return "Chrony"
        case "clamav": return "ClamAV"
        case "apt": return "APT Timers"
        case "rsyslog": return "Rsyslog"
        case "snapd": return "Snapd"
        default: return service
        }
    }

    private func severity(for service: String, output: String) -> MobileFindingSeverity {
        let lower = output.lowercased()
        if lower.contains("failed") || lower.contains("error") || lower.contains("invalid") {
            return .critical
        }
        if lower.contains("inactive") || lower.contains("disabled") || lower.contains("warning") {
            return service == "ufw" ? .critical : .warning
        }
        if lower.contains("not installed") || lower.contains("unavailable") {
            return .info
        }
        return .ok
    }

    private func summary(for service: String, output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.prefix(3).joined(separator: " | ").isEmpty
            ? "No details returned."
            : lines.prefix(3).joined(separator: " | ")
    }

    private func icon(for service: String) -> String {
        switch service {
        case "nginx": return "network"
        case "ufw", "fail2ban", "apparmor", "ssh": return "shield"
        case "certbot": return "checkmark.seal"
        case "postfix", "dovecot": return "envelope"
        case "containerd": return "shippingbox"
        case "chrony": return "clock"
        default: return "gearshape"
        }
    }

    private static let inspectionCommand = """
    echo __MIDNIGHT_SERVICE_INSPECTION_BEGIN__
    svc() { printf '\\n__MIDNIGHT_SERVICE__ %s\\n' "$1"; }

    svc ssh
    systemctl is-active ssh sshd 2>/dev/null | head -1 || true
    sshd -T 2>/dev/null | grep -Ei '^(passwordauthentication|pubkeyauthentication|permitrootlogin|port) ' || true
    last -a 2>/dev/null | head -5 || true

    svc ufw
    if command -v ufw >/dev/null 2>&1; then sudo -n ufw status numbered 2>&1 || ufw status numbered 2>&1; else echo "not installed"; fi

    svc nginx
    if command -v nginx >/dev/null 2>&1; then nginx -t 2>&1; find /etc/nginx/sites-enabled -maxdepth 1 -type l -printf '%f\\n' 2>/dev/null; else echo "not installed"; fi

    svc certbot
    if command -v certbot >/dev/null 2>&1; then certbot certificates 2>&1 | sed -n '1,80p'; else echo "not installed"; fi

    svc fail2ban
    if command -v fail2ban-client >/dev/null 2>&1; then sudo -n fail2ban-client status 2>&1 || fail2ban-client status 2>&1; else echo "not installed"; fi

    svc postfix
    if command -v postqueue >/dev/null 2>&1; then postqueue -p 2>&1 | tail -20; else echo "not installed"; fi

    svc dovecot
    if command -v doveconf >/dev/null 2>&1; then doveconf -n 2>/dev/null | sed -n '1,40p'; else echo "not installed"; fi

    svc containerd
    systemctl is-active containerd docker 2>/dev/null || true
    command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | head -10 || true

    svc apparmor
    if command -v aa-status >/dev/null 2>&1; then aa-status 2>&1 | sed -n '1,60p'; else systemctl is-active apparmor 2>/dev/null || echo "not installed"; fi

    svc chrony
    if command -v chronyc >/dev/null 2>&1; then chronyc tracking 2>&1 | sed -n '1,30p'; else systemctl is-active chrony chronyd 2>/dev/null || echo "not installed"; fi

    svc clamav
    systemctl is-active clamav-daemon clamav-freshclam 2>/dev/null || echo "not installed"

    svc apt
    systemctl list-timers 'apt*' --no-pager --no-legend 2>/dev/null || echo "not installed"

    svc rsyslog
    systemctl is-active rsyslog 2>/dev/null || echo "not installed"

    svc snapd
    systemctl is-active snapd 2>/dev/null || echo "not installed"
    """
}
