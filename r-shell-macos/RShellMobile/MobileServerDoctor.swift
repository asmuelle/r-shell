import Foundation
import SwiftUI

enum MobileServerDoctorRunner {
    static func run(
        connectionId: String,
        hostLabel: String,
        sshPort: UInt16
    ) async -> MobileDoctorReport {
        var findings: [MobileFinding] = []
        var rawSections: [MobileDoctorRawSection] = []

        do {
            let stats = try await MobileMonitorBridge.shared.getSystemStats(connectionId: connectionId)
            findings.append(contentsOf: findingsForStats(stats))
            rawSections.append(MobileDoctorRawSection(title: "System Stats", output: summarize(stats)))
        } catch {
            findings.append(MobileFinding(
                title: "System stats unavailable",
                detail: error.localizedDescription,
                severity: .unknown,
                category: "System"
            ))
        }

        do {
            let processes = try await MobileMonitorBridge.shared.getProcesses(connectionId: connectionId)
            findings.append(contentsOf: findingsForProcesses(processes))
            rawSections.append(MobileDoctorRawSection(
                title: "Top Processes",
                output: processes
                    .sorted { $0.cpuPercent > $1.cpuPercent }
                    .prefix(12)
                    .map { "\($0.pid)\t\($0.user)\tCPU \($0.cpuPercent)%\tMEM \($0.memoryPercent)%\t\($0.command)" }
                    .joined(separator: "\n")
            ))
        } catch {
            findings.append(MobileFinding(
                title: "Process list unavailable",
                detail: error.localizedDescription,
                severity: .unknown,
                category: "Processes"
            ))
        }

        await appendRemoteChecks(
            connectionId: connectionId,
            sshPort: sshPort,
            findings: &findings,
            rawSections: &rawSections
        )

        if findings.isEmpty {
            findings.append(MobileFinding(
                title: "No findings",
                detail: "The available checks did not find anything requiring attention.",
                severity: .ok,
                category: "Summary"
            ))
        }

        return MobileDoctorReport(
            hostLabel: hostLabel,
            findings: findings,
            rawSections: rawSections
        )
    }

    private static func findingsForStats(_ stats: FfiSystemStats) -> [MobileFinding] {
        var findings: [MobileFinding] = []
        let memoryPercent = stats.memoryTotal > 0
            ? Double(stats.memoryUsed) / Double(stats.memoryTotal) * 100
            : 0
        let worstDisk = stats.disks.max { diskPercent($0) < diskPercent($1) }

        findings.append(thresholdFinding(
            title: "CPU usage",
            value: stats.cpuPercent,
            warning: 75,
            critical: 90,
            detail: "CPU \(String(format: "%.0f", stats.cpuPercent))%, load \(String(format: "%.2f", stats.loadAverage1m)).",
            category: "CPU",
            action: "Open top processes"
        ))

        findings.append(thresholdFinding(
            title: "Memory usage",
            value: memoryPercent,
            warning: 80,
            critical: 92,
            detail: "Memory \(String(format: "%.0f", memoryPercent))% used.",
            category: "Memory",
            action: "Inspect memory-heavy processes"
        ))

        if let worstDisk {
            let percent = diskPercent(worstDisk)
            findings.append(thresholdFinding(
                title: "Disk usage on \(worstDisk.mount)",
                value: percent,
                warning: 80,
                critical: 92,
                detail: "\(worstDisk.mount) is \(String(format: "%.0f", percent))% full.",
                category: "Disk",
                action: "Find large recent files"
            ))
        }

        return findings
    }

    private static func findingsForProcesses(_ processes: [FfiProcess]) -> [MobileFinding] {
        var findings: [MobileFinding] = []
        if let cpu = processes.max(by: { $0.cpuPercent < $1.cpuPercent }), cpu.cpuPercent >= 60 {
            findings.append(MobileFinding(
                title: "CPU-heavy process",
                detail: "\(displayName(cpu)) is using \(String(format: "%.1f", cpu.cpuPercent))% CPU.",
                severity: cpu.cpuPercent >= 90 ? .critical : .warning,
                category: "CPU",
                actionLabel: "Inspect process",
                rawOutput: "\(cpu)"
            ))
        }
        if let memory = processes.max(by: { $0.memoryPercent < $1.memoryPercent }), memory.memoryPercent >= 20 {
            findings.append(MobileFinding(
                title: "Memory-heavy process",
                detail: "\(displayName(memory)) is using \(String(format: "%.1f", memory.memoryPercent))% memory.",
                severity: memory.memoryPercent >= 40 ? .critical : .warning,
                category: "Memory",
                actionLabel: "Inspect process",
                rawOutput: "\(memory)"
            ))
        }
        return findings
    }

    private static func appendRemoteChecks(
        connectionId: String,
        sshPort: UInt16,
        findings: inout [MobileFinding],
        rawSections: inout [MobileDoctorRawSection]
    ) async {
        async let services = runTask(connectionId, "Failed Services", failedServicesCommand)
        async let firewall = runTask(connectionId, "Firewall", ufwCommand)
        async let largeFiles = runTask(connectionId, "Large Recent Files", largeFilesCommand)
        async let fail2ban = runTask(connectionId, "Fail2ban", fail2banCommand)
        async let certs = runTask(connectionId, "Certificates", certificateCommand)
        async let updates = runTask(connectionId, "Updates", updateCommand)

        let results = await [services, firewall, largeFiles, fail2ban, certs, updates]
        for result in results {
            switch result {
            case .success(let task):
                rawSections.append(MobileDoctorRawSection(title: task.title, output: task.output))
                findings.append(contentsOf: findingsForTask(task, sshPort: sshPort))
            case .failure(let error):
                findings.append(MobileFinding(
                    title: "Remote check failed",
                    detail: error.localizedDescription,
                    severity: .unknown,
                    category: "Remote"
                ))
            }
        }
    }

    private static func runTask(
        _ connectionId: String,
        _ title: String,
        _ command: String
    ) async -> Result<MobileRemoteTaskResult, Error> {
        do {
            return .success(try await MobileRemoteTaskRunner.shared.run(
                connectionId: connectionId,
                title: title,
                command: command
            ))
        } catch {
            return .failure(error)
        }
    }

    private static func findingsForTask(
        _ task: MobileRemoteTaskResult,
        sshPort: UInt16
    ) -> [MobileFinding] {
        switch task.title {
        case "Failed Services":
            let failed = task.output
                .split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !failed.isEmpty else {
                return [MobileFinding(title: "Systemd services healthy", detail: "No failed units reported.", severity: .ok, category: "Systemd")]
            }
            return [MobileFinding(
                title: "\(failed.count) failed systemd service\(failed.count == 1 ? "" : "s")",
                detail: failed.prefix(4).joined(separator: ", "),
                severity: .critical,
                category: "Systemd",
                actionLabel: "Open service details",
                rawOutput: task.output
            )]

        case "Firewall":
            return firewallFindings(task, sshPort: sshPort)

        case "Large Recent Files":
            let rows = task.output
                .split(whereSeparator: \.isNewline)
                .filter { !$0.contains("__MIDNIGHT_SSH_NO_FIND__") }
            guard !rows.isEmpty else {
                return [MobileFinding(title: "No large recent files found", detail: "The sampled paths did not contain large files changed recently.", severity: .ok, category: "Disk")]
            }
            return [MobileFinding(
                title: "Large recently changed files",
                detail: rows.prefix(3).joined(separator: "\n"),
                severity: .warning,
                category: "Disk",
                actionLabel: "Review files",
                rawOutput: task.output
            )]

        case "Fail2ban":
            guard task.output.lowercased().contains("jail list") || task.output.lowercased().contains("status") else {
                return [MobileFinding(title: "Fail2ban unavailable", detail: "fail2ban-client is not installed or not accessible.", severity: .info, category: "Security")]
            }
            return [MobileFinding(title: "Fail2ban active", detail: firstNonEmptyLine(task.output) ?? "Fail2ban returned status.", severity: .ok, category: "Security", rawOutput: task.output)]

        case "Certificates":
            let expiring = task.output
                .split(whereSeparator: \.isNewline)
                .filter { $0.lowercased().contains("valid:") && !$0.lowercased().contains("valid: ok") }
            if expiring.isEmpty {
                return [MobileFinding(title: "Certificate check complete", detail: firstNonEmptyLine(task.output) ?? "No certificate risk found in sampled sources.", severity: .ok, category: "Certificates", rawOutput: task.output)]
            }
            return [MobileFinding(title: "Certificate expiry risk", detail: expiring.prefix(3).joined(separator: "\n"), severity: .warning, category: "Certificates", actionLabel: "Inspect certificates", rawOutput: task.output)]

        case "Updates":
            var result: [MobileFinding] = []
            if task.output.contains("__REBOOT_REQUIRED__") {
                result.append(MobileFinding(title: "Reboot required", detail: "The server reports /var/run/reboot-required.", severity: .warning, category: "Updates"))
            }
            if task.output.contains("__UPDATES_AVAILABLE__") {
                result.append(MobileFinding(title: "Package updates available", detail: "Package updates are available.", severity: .info, category: "Updates", rawOutput: task.output))
            }
            return result.isEmpty ? [MobileFinding(title: "Update check clean", detail: "No reboot marker or package-update signal found.", severity: .ok, category: "Updates")] : result

        default:
            return []
        }
    }

    private static func firewallFindings(
        _ task: MobileRemoteTaskResult,
        sshPort: UInt16
    ) -> [MobileFinding] {
        let lower = task.output.lowercased()
        if lower.contains("inactive") {
            return [MobileFinding(title: "UFW inactive", detail: "The host firewall is inactive.", severity: .critical, category: "Firewall", actionLabel: "Review UFW", rawOutput: task.output)]
        }
        guard lower.contains("active") else {
            return [MobileFinding(title: "Firewall status unknown", detail: firstNonEmptyLine(task.output) ?? "Could not determine UFW status.", severity: .unknown, category: "Firewall", rawOutput: task.output)]
        }

        let extra = MobileDoctorFirewallParser.extraPublicRules(from: task.output, sshPort: sshPort)
        if extra.isEmpty {
            return [MobileFinding(title: "UFW exposure looks restrained", detail: "Only SSH/HTTP/HTTPS-style public ports were detected.", severity: .ok, category: "Firewall", rawOutput: task.output)]
        }
        return [MobileFinding(title: "Extra public firewall exposure", detail: extra.prefix(5).joined(separator: ", "), severity: .warning, category: "Firewall", actionLabel: "Review UFW rules", rawOutput: task.output)]
    }

    private static func thresholdFinding(
        title: String,
        value: Double,
        warning: Double,
        critical: Double,
        detail: String,
        category: String,
        action: String
    ) -> MobileFinding {
        let severity: MobileFindingSeverity
        if value >= critical {
            severity = .critical
        } else if value >= warning {
            severity = .warning
        } else {
            severity = .ok
        }
        return MobileFinding(
            title: title,
            detail: detail,
            severity: severity,
            category: category,
            actionLabel: severity == .ok ? nil : action
        )
    }

    private static func summarize(_ stats: FfiSystemStats) -> String {
        """
        CPU: \(stats.cpuPercent)%
        Load 1m: \(stats.loadAverage1m)
        Memory: \(stats.memoryUsed)/\(stats.memoryTotal)
        Uptime seconds: \(stats.uptimeSeconds)
        Disks:
        \(stats.disks.map { "\($0.mount) \($0.used)/\($0.total)" }.joined(separator: "\n"))
        """
    }

    private static func diskPercent(_ disk: FfiDiskMount) -> Double {
        guard disk.total > 0 else { return 0 }
        return Double(disk.used) / Double(disk.total) * 100
    }

    private static func displayName(_ process: FfiProcess) -> String {
        process.command.isEmpty ? process.args : process.command
    }

    private static func firstNonEmptyLine(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static let failedServicesCommand = """
    command -v systemctl >/dev/null 2>&1 || exit 0
    systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{print $1" "$2" "$3" "$4" "$5" "$6" "$7" "$8}'
    """

    private static let ufwCommand = """
    if command -v ufw >/dev/null 2>&1; then
      sudo -n ufw status numbered 2>&1 || ufw status numbered 2>&1
    else
      echo "ufw unavailable"
    fi
    """

    private static let largeFilesCommand = """
    if command -v find >/dev/null 2>&1; then
      find /var/log /tmp /home -xdev -type f -mtime -14 -size +50M -printf '%TY-%Tm-%Td %TH:%TM %s %p\\n' 2>/dev/null | sort -r | head -20 || echo __MIDNIGHT_SSH_NO_FIND__
    else
      echo __MIDNIGHT_SSH_NO_FIND__
    fi
    """

    private static let fail2banCommand = """
    if command -v fail2ban-client >/dev/null 2>&1; then
      sudo -n fail2ban-client status 2>&1 || fail2ban-client status 2>&1
    else
      echo "fail2ban unavailable"
    fi
    """

    private static let certificateCommand = """
    if command -v certbot >/dev/null 2>&1; then
      certbot certificates 2>&1 | sed -n '1,120p'
    elif command -v openssl >/dev/null 2>&1 && command -v find >/dev/null 2>&1; then
      find /etc/letsencrypt/live -name fullchain.pem 2>/dev/null | head -20 | while read -r cert; do
        end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | sed 's/notAfter=//')
        printf '%s valid: %s\\n' "$cert" "$end"
      done
    else
      echo "certificate tooling unavailable"
    fi
    """

    private static let updateCommand = """
    [ -f /var/run/reboot-required ] && echo __REBOOT_REQUIRED__
    if command -v apt-get >/dev/null 2>&1; then
      apt-get -s upgrade 2>/dev/null | grep -q '^Inst ' && echo __UPDATES_AVAILABLE__ || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf check-update >/dev/null 2>&1; rc=$?; [ "$rc" = 100 ] && echo __UPDATES_AVAILABLE__ || true
    fi
    """
}

enum MobileDoctorFirewallParser {
    static func extraPublicRules(from output: String, sshPort: UInt16) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .compactMap(extractRule)
            .filter { isPublicSource($0.source) && !isAllowed($0.target, sshPort: sshPort) }
            .map(\.target)
    }

    private static func extractRule(_ line: String) -> (target: String, source: String)? {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("Status:"),
              !trimmed.hasPrefix("To "),
              !trimmed.hasPrefix("--") else { return nil }
        if trimmed.hasPrefix("["),
           let end = trimmed.firstIndex(of: "]") {
            trimmed = String(trimmed[trimmed.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        }
        let pattern = #"^(.+?)\s{2,}(ALLOW|ALLOW IN|LIMIT|LIMIT IN)\s{2,}(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let targetRange = Range(match.range(at: 1), in: trimmed),
              let sourceRange = Range(match.range(at: 3), in: trimmed) else { return nil }
        return (
            target: String(trimmed[targetRange]).trimmingCharacters(in: .whitespaces),
            source: stripComment(String(trimmed[sourceRange]))
        )
    }

    private static func isPublicSource(_ source: String) -> Bool {
        let normalized = stripComment(source)
            .replacingOccurrences(of: "(v6)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["any", "anyone", "anywhere", "0.0.0.0/0", "::/0"].contains(normalized)
    }

    private static func isAllowed(_ target: String, sshPort: UInt16) -> Bool {
        let normalized = target
            .replacingOccurrences(of: "(v6)", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        if ["ssh", "openssh", "http", "https", "www", "www full", "nginx full", "apache full"].contains(normalized) {
            return true
        }
        let first = normalized.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? normalized
        let ports = first.split(separator: "/").first.map(String.init)?.split(separator: ",").map(String.init) ?? []
        let allowed: Set<String> = ["22", "80", "443", String(sshPort)]
        return !ports.isEmpty && ports.allSatisfy { allowed.contains($0) }
    }

    private static func stripComment(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: " # ") else { return trimmed }
        return String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
