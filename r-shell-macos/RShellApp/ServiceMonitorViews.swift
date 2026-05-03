import AppKit
import OSLog
import SwiftUI

// MARK: - Remote command runner

struct RemoteCommandResult {
    let output: String
    let exitCode: Int

    var succeeded: Bool { exitCode == 0 }
}

enum RemoteCommandError: LocalizedError {
    case ffi(String)
    case missingExitMarker(String)
    case failed(RemoteCommandResult)

    var errorDescription: String? {
        switch self {
        case .ffi(let detail):
            return detail
        case .missingExitMarker(let output):
            return output.isEmpty ? "Remote command did not return an exit status." : output
        case .failed(let result):
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Remote command failed with exit code \(result.exitCode)."
                : detail
        }
    }
}

enum RemoteCommandRunner {
    static func runRaw(connectionId: String, command: String) async throws -> String {
        do {
            return try await BridgeManager.shared.executeCommand(
                connectionId: connectionId,
                command: command
            )
        } catch {
            throw RemoteCommandError.ffi(error.localizedDescription)
        }
    }

    static func runShell(connectionId: String, script: String) async throws -> RemoteCommandResult {
        let marker = "__RSHELL_EXIT_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let wrapped = """
        (
        \(script)
        ) 2>&1
        status=$?
        printf '\\n\(marker)%s\\n' "$status"
        """
        let output = try await runRaw(
            connectionId: connectionId,
            command: "sh -lc \(shellQuote(wrapped))"
        )
        guard let range = output.range(of: marker, options: .backwards) else {
            throw RemoteCommandError.missingExitMarker(output)
        }
        let body = String(output[..<range.lowerBound])
        let suffix = output[range.upperBound...]
        let statusToken = suffix.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let exitCode = Int(statusToken.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 127
        return RemoteCommandResult(
            output: body.trimmingCharacters(in: .newlines),
            exitCode: exitCode
        )
    }

    static func runChecked(connectionId: String, script: String) async throws -> String {
        let result = try await runShell(connectionId: connectionId, script: script)
        guard result.succeeded else { throw RemoteCommandError.failed(result) }
        return result.output
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

private let fieldSeparator = "\u{1F}"

private func splitFields(_ line: String) -> [String] {
    line.split(separator: Character(fieldSeparator), omittingEmptySubsequences: false).map(String.init)
}

private func placeholderView(icon: String, title: String, message: String) -> some View {
    VStack(spacing: 8) {
        Image(systemName: icon)
            .font(.system(size: 26, weight: .light))
            .foregroundStyle(.tertiary)
        Text(title)
            .font(.callout.weight(.medium))
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

private func monoCell(_ text: String, width: CGFloat? = nil, color: Color = .primary) -> some View {
    Text(text.isEmpty ? "-" : text)
        .font(.caption.monospaced())
        .foregroundStyle(color)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: width, alignment: .leading)
}

private func statusColor(_ value: String) -> Color {
    let lower = value.lowercased()
    if lower.contains("running") || lower == "active" || lower == "healthy" { return .green }
    if lower.contains("failed") || lower.contains("exited") || lower.contains("dead") || lower == "unhealthy" { return .red }
    if lower.contains("activating") || lower.contains("restarting") || lower.contains("paused") { return .orange }
    return .secondary
}

// MARK: - UFW

private struct UFWStatusSnapshot {
    var active: Bool = false
    var rawStatus: String = ""
    var numberedRules: String = ""
    var ipv6: String = "unknown"
    var incomingPolicy: String = "-"
    var outgoingPolicy: String = "-"
    var routedPolicy: String = "-"
    var logging: String = "-"
    var sshClientIp: String = ""
    var sshServerPort: Int?
    var iptables: String = ""
}

private struct UFWRule: Identifiable, Hashable {
    let number: Int
    let action: String
    let target: String
    let source: String
    let comment: String
    let raw: String

    var id: Int { number }
}

private struct UFWLogEntry: Identifiable, Hashable {
    let id: String
    let timestamp: String
    let action: String
    let interface: String
    let source: String
    let destination: String
    let protocolName: String
    let sourcePort: String
    let destinationPort: String
    let raw: String
}

private struct UFWTopTalker: Identifiable, Hashable {
    let source: String
    let count: Int

    var id: String { source }
}

enum UFWProtectionLevel: Equatable {
    case loading
    case unavailable
    case inactive
    case protected
    case open
    case unknown
}

struct UFWProtectionSummary: Equatable {
    let level: UFWProtectionLevel
    let statusText: String
    let extraOpenRules: [String]
    let error: String?

    static let loading = UFWProtectionSummary(
        level: .loading,
        statusText: "Loading UFW status",
        extraOpenRules: [],
        error: nil
    )

    var badgeText: String {
        switch level {
        case .loading: return "..."
        case .unavailable: return "n/a"
        case .inactive: return "off"
        case .protected: return "on"
        case .open: return "open"
        case .unknown: return "?"
        }
    }

    var helpText: String {
        switch level {
        case .open where !extraOpenRules.isEmpty:
            return "\(statusText). Extra open rules: \(extraOpenRules.joined(separator: ", "))"
        case .unknown:
            return error ?? statusText
        default:
            return statusText
        }
    }
}

let ufwUnavailableMarker = "__R_SHELL_UFW_UNAVAILABLE__"

struct UFWOpenRuleExposure: Equatable {
    let target: String
    let source: String
}

func summarizeUFWStatusOutput(_ output: String, sshPort: UInt16?) -> UFWProtectionSummary {
    let statusText = output
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "Unknown"

    if statusText == ufwUnavailableMarker || output.contains(ufwUnavailableMarker) {
        return UFWProtectionSummary(
            level: .unavailable,
            statusText: "UFW not installed",
            extraOpenRules: [],
            error: nil
        )
    }

    let lower = statusText.lowercased()
    if lower.contains("inactive") {
        return UFWProtectionSummary(
            level: .inactive,
            statusText: statusText,
            extraOpenRules: [],
            error: nil
        )
    }

    if lower.contains("active") {
        let extraRules = collectExtraUFWOpenRules(from: output, sshPort: sshPort)
        return UFWProtectionSummary(
            level: extraRules.isEmpty ? .protected : .open,
            statusText: statusText,
            extraOpenRules: extraRules,
            error: nil
        )
    }

    let isPermissionError = lower.contains("permission")
        || lower.contains("need to be root")
        || lower.contains("must be root")
        || lower.contains("password")

    return UFWProtectionSummary(
        level: .unknown,
        statusText: statusText,
        extraOpenRules: [],
        error: isPermissionError ? statusText : nil
    )
}

func summarizeUFWStatus(
    active: Bool,
    statusText: String,
    openRules: [UFWOpenRuleExposure],
    sshPort: UInt16?
) -> UFWProtectionSummary {
    guard active else {
        return UFWProtectionSummary(
            level: .inactive,
            statusText: statusText,
            extraOpenRules: [],
            error: nil
        )
    }

    let extraRules = openRules
        .filter { isPublicUFWSource($0.source) && !isAllowedUFWOpenRule($0.target, sshPort: sshPort) }
        .map(\.target)
    return UFWProtectionSummary(
        level: extraRules.isEmpty ? .protected : .open,
        statusText: statusText,
        extraOpenRules: extraRules,
        error: nil
    )
}

func collectExtraUFWOpenRules(from output: String, sshPort: UInt16?) -> [String] {
    output
        .split(whereSeparator: \.isNewline)
        .compactMap { extractUFWOpenRuleExposure(from: String($0)) }
        .filter { isPublicUFWSource($0.source) && !isAllowedUFWOpenRule($0.target, sshPort: sshPort) }
        .map(\.target)
}

func extractUFWOpenRuleExposure(from line: String) -> UFWOpenRuleExposure? {
    var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.hasPrefix("Status:"),
          !trimmed.hasPrefix("To "),
          !trimmed.hasPrefix("--")
    else { return nil }

    if trimmed.hasPrefix("["),
       let end = trimmed.firstIndex(of: "]") {
        trimmed = String(trimmed[trimmed.index(after: end)...])
            .trimmingCharacters(in: .whitespaces)
    }

    let pattern = #"^(.+?)\s{2,}(ALLOW(?:\s+(?:IN|OUT))?|LIMIT(?:\s+(?:IN|OUT))?)\s{2,}(.+)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
          match.numberOfRanges >= 4,
          let targetRange = Range(match.range(at: 1), in: trimmed),
          let sourceRange = Range(match.range(at: 3), in: trimmed)
    else { return nil }

    let target = trimmed[targetRange]
        .trimmingCharacters(in: .whitespaces)
    let source = stripUFWRuleComment(String(trimmed[sourceRange]))
    guard !target.isEmpty, !source.isEmpty else { return nil }
    return UFWOpenRuleExposure(target: target, source: source)
}

func isPublicUFWSource(_ source: String) -> Bool {
    let normalized = stripUFWRuleComment(source)
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .lowercased()

    return [
        "any",
        "anyone",
        "anyone (v6)",
        "anywhere",
        "anywhere (v6)",
        "0.0.0.0/0",
        "::/0",
        "::/0 (v6)",
    ].contains(normalized)
}

func stripUFWRuleComment(_ source: String) -> String {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let commentRange = trimmed.range(of: " # ") else {
        return trimmed
    }
    return String(trimmed[..<commentRange.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func isAllowedUFWOpenRule(_ rule: String, sshPort: UInt16?) -> Bool {
    let normalized = rule
        .replacingOccurrences(of: "(v6)", with: "")
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .lowercased()

    let knownAllowedServices: Set<String> = [
        "http",
        "https",
        "ssh",
        "openssh",
        "www",
        "www full",
        "www secure",
        "apache",
        "apache full",
        "apache secure",
        "nginx http",
        "nginx https",
        "nginx full",
    ]
    if knownAllowedServices.contains(normalized) {
        return true
    }

    guard let portSpec = normalized.split(whereSeparator: \.isWhitespace).first else {
        return false
    }
    let portPart = portSpec.split(separator: "/").first.map(String.init) ?? String(portSpec)
    let ports = portPart.split(separator: ",").map(String.init)
    guard !ports.isEmpty else { return false }

    var allowedPorts: Set<String> = ["22", "80", "443"]
    if let sshPort {
        allowedPorts.insert(String(sshPort))
    }
    return ports.allSatisfy { allowedPorts.contains($0) }
}

struct UFWMonitorView: View {
    let connectionId: String?
    let connectionLabel: String
    let sshPort: UInt16?

    private enum Mode: String, CaseIterable {
        case status = "Status"
        case rules = "Rules"
        case logs = "Logs"
    }

    private enum ActionFilter: String, CaseIterable {
        case all = "All"
        case allow = "Allow"
        case deny = "Deny"
        case reject = "Reject"
        case limit = "Limit"
    }

    @State private var mode: Mode = .status
    @State private var actionFilter: ActionFilter = .all
    @State private var snapshot = UFWStatusSnapshot()
    @State private var rules: [UFWRule] = []
    @State private var logs: [UFWLogEntry] = []
    @State private var selectedRules: Set<Int> = []
    @State private var ruleSortOrder: [KeyPathComparator<UFWRule>] = [
        .init(\.number)
    ]
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?

    private static let refreshInterval: UInt64 = 30_000_000_000

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if connectionId == nil {
                placeholderView(
                    icon: "network.slash",
                    title: "No connection",
                    message: "Open an SSH workspace to inspect UFW."
                )
            } else if let error {
                placeholderView(
                    icon: "exclamationmark.triangle",
                    title: "UFW unavailable",
                    message: error
                )
            } else {
                content
            }
        }
        .task(id: connectionId) {
            await refreshLoop()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.secondary)
            Text("UFW")
                .font(.subheadline.weight(.medium))
            statusBadge
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            if mode == .rules {
                Picker("", selection: $actionFilter) {
                    ForEach(ActionFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            TextField(mode == .logs ? "Filter src/dst/port" : "Filter", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Spacer()
            Text("30s")
                .font(.caption)
                .foregroundStyle(.secondary)
            if loading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(connectionId == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var statusBadge: some View {
        let summary = ufwProtectionSummary
        let color = ufwProtectionColor(summary)
        return Text(summary.badgeText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
            .help(summary.helpText)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .status:
            statusPane
        case .rules:
            rulesPane
        case .logs:
            logsPane
        }
    }

    private var statusPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let warning = sshLockoutWarning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ufwMetric("Status", snapshot.active ? "Active" : "Inactive", color: ufwProtectionColor(ufwProtectionSummary))
                    ufwMetric("Incoming", snapshot.incomingPolicy, color: policyColor(snapshot.incomingPolicy))
                    ufwMetric("Outgoing", snapshot.outgoingPolicy, color: policyColor(snapshot.outgoingPolicy))
                    ufwMetric("Forward", snapshot.routedPolicy, color: policyColor(snapshot.routedPolicy))
                    ufwMetric("IPv6", snapshot.ipv6, color: snapshot.ipv6.lowercased().contains("yes") ? .green : .secondary)
                    ufwMetric("Logging", snapshot.logging, color: .secondary)
                    ufwMetric("Rules", "\(rules.count)", color: .secondary)
                    ufwMetric("Blocked Logs", "\(logs.filter { $0.action == "BLOCK" }.count)", color: .red)
                }

                HStack(spacing: 10) {
                    topTalkersCard
                    rawStatusCard
                }
            }
            .padding(12)
        }
    }

    private func ufwMetric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var topTalkersCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top Blocked Sources")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let talkers = topBlockedSources
            if talkers.isEmpty {
                Text("No blocked source IPs in the sampled log window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(talkers) { item in
                    HStack {
                        monoCell(item.source)
                        Spacer()
                        Text("\(item.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var rawStatusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Raw Status")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { RemoteCommandRunner.copy(snapshot.rawStatus) }
                    .disabled(snapshot.rawStatus.isEmpty)
            }
            logText(snapshot.rawStatus)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var rulesPane: some View {
        HSplitView {
            Table(filteredRules.sorted(using: ruleSortOrder), selection: $selectedRules, sortOrder: $ruleSortOrder) {
                TableColumn("#", value: \.number) { rule in
                    Text("\(rule.number)")
                        .font(.caption.monospacedDigit())
                }
                .width(min: 45, ideal: 55, max: 70)

                TableColumn("Action", value: \.action) { rule in
                    Text(rule.action)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ruleColor(rule.action))
                }
                .width(min: 90, ideal: 110)

                TableColumn("Port / Proto", value: \.target) { rule in
                    monoCell(rule.target)
                }
                .width(min: 150, ideal: 220)

                TableColumn("Source", value: \.source) { rule in
                    monoCell(rule.source)
                }
                .width(min: 160, ideal: 220)

                TableColumn("Comment", value: \.comment) { rule in
                    monoCell(rule.comment, color: .secondary)
                }
            }
            .contextMenu(forSelectionType: Int.self) { selected in
                if let number = selected.first, let rule = rules.first(where: { $0.number == number }) {
                    Button("Copy Rule") { RemoteCommandRunner.copy(rule.raw) }
                    Button("Copy Delete Command") { RemoteCommandRunner.copy("sudo ufw delete \(rule.number)") }
                }
            }
            .frame(minWidth: 520)

            ruleDetailPane
                .frame(minWidth: 320)
        }
    }

    private var ruleDetailPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rule = selectedRule {
                HStack {
                    Text("Rule \(rule.number)")
                        .font(.headline)
                    Spacer()
                    Button("Copy") { RemoteCommandRunner.copy(rule.raw) }
                }
                Text(rule.raw)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                Text("iptables Matches")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                logText(iptablesMatches(for: rule))
            } else {
                placeholderView(
                    icon: "list.bullet.rectangle",
                    title: "Select a rule",
                    message: "Choose a numbered UFW rule to see its raw line and likely iptables chain entries."
                )
            }
        }
        .padding(10)
    }

    private var logsPane: some View {
        HSplitView {
            List(filteredLogs) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(entry.timestamp)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 155, alignment: .leading)
                        Text(entry.action)
                            .font(.caption2.weight(.semibold).monospaced())
                            .foregroundStyle(entry.action == "BLOCK" ? .red : .green)
                            .frame(width: 52, alignment: .leading)
                        monoCell(entry.protocolName, width: 42, color: .secondary)
                        monoCell("\(entry.source):\(entry.sourcePort)", width: 165)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        monoCell("\(entry.destination):\(entry.destinationPort)")
                    }
                    Text(entry.raw)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Copy Log Line") { RemoteCommandRunner.copy(entry.raw) }
                    Button("Copy Source IP") { RemoteCommandRunner.copy(entry.source) }
                }
            }
            .listStyle(.plain)
            .frame(minWidth: 620)

            VStack(alignment: .leading, spacing: 8) {
                Text("Top Blocked Sources")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(topBlockedSources) { item in
                    HStack {
                        monoCell(item.source)
                        Spacer()
                        Text("\(item.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("Sample Window")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(logs.count) parsed UFW lines from the most recent log sample.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
            .frame(minWidth: 220)
        }
    }

    private func logText(_ value: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(value.isEmpty ? "-" : value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var filteredRules: [UFWRule] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rules.filter { rule in
            let actionMatches: Bool
            switch actionFilter {
            case .all:
                actionMatches = true
            case .allow:
                actionMatches = rule.action.lowercased().contains("allow")
            case .deny:
                actionMatches = rule.action.lowercased().contains("deny")
            case .reject:
                actionMatches = rule.action.lowercased().contains("reject")
            case .limit:
                actionMatches = rule.action.lowercased().contains("limit")
            }
            guard actionMatches else { return false }
            guard !needle.isEmpty else { return true }
            return rule.target.lowercased().contains(needle)
                || rule.source.lowercased().contains(needle)
                || rule.action.lowercased().contains(needle)
                || rule.comment.lowercased().contains(needle)
                || "\(rule.number)".contains(needle)
        }
    }

    private var filteredLogs: [UFWLogEntry] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return logs }
        return logs.filter {
            $0.source.lowercased().contains(needle)
                || $0.destination.lowercased().contains(needle)
                || $0.destinationPort.contains(needle)
                || $0.sourcePort.contains(needle)
                || $0.interface.lowercased().contains(needle)
                || $0.protocolName.lowercased().contains(needle)
        }
    }

    private var selectedRule: UFWRule? {
        guard let number = selectedRules.sorted().first else { return nil }
        return rules.first { $0.number == number }
    }

    private var ufwProtectionSummary: UFWProtectionSummary {
        let statusText = snapshot.rawStatus.lines()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? (snapshot.active ? "Status: active" : "Status: inactive")
        return summarizeUFWStatus(
            active: snapshot.active,
            statusText: statusText,
            openRules: rules
                .filter {
                    let action = $0.action.lowercased()
                    return action.contains("allow") || action.contains("limit")
                }
                .map { UFWOpenRuleExposure(target: $0.target, source: $0.source) },
            sshPort: sshPort
        )
    }

    private func ufwProtectionColor(_ summary: UFWProtectionSummary) -> Color {
        switch summary.level {
        case .protected:
            return .green
        case .inactive, .open:
            return .orange
        case .unknown:
            return .yellow
        case .loading, .unavailable:
            return .secondary
        }
    }

    private var topBlockedSources: [UFWTopTalker] {
        var counts: [String: Int] = [:]
        for entry in logs where entry.action == "BLOCK" && !entry.source.isEmpty {
            counts[entry.source, default: 0] += 1
        }
        var rows: [UFWTopTalker] = []
        for (source, count) in counts {
            rows.append(UFWTopTalker(source: source, count: count))
        }
        rows.sort { lhs, rhs in
            lhs.count == rhs.count ? lhs.source < rhs.source : lhs.count > rhs.count
        }
        let limit = min(5, rows.count)
        guard limit > 0 else { return [] }
        return Array(rows[0..<limit])
    }

    private var sshLockoutWarning: String? {
        guard snapshot.active else { return nil }
        let port = snapshot.sshServerPort ?? Int(sshPort ?? 22)
        let allowed = rules.contains { rule in
            rule.action.lowercased().contains("allow")
                && (rule.target.lowercased().contains("openssh")
                    || rule.target.contains("\(port)")
                    || rule.target.lowercased().contains("ssh"))
        }
        guard !allowed else { return nil }
        let client = snapshot.sshClientIp.isEmpty ? "the current SSH client" : snapshot.sshClientIp
        return "UFW is active, but no ALLOW rule obviously covers SSH port \(port) for \(client). Enabling or deleting rules could lock out this session."
    }

    private func policyColor(_ policy: String) -> Color {
        let lower = policy.lowercased()
        if lower.contains("allow") { return .green }
        if lower.contains("deny") || lower.contains("reject") { return .red }
        return .secondary
    }

    private func ruleColor(_ action: String) -> Color {
        let lower = action.lowercased()
        if lower.contains("allow") { return .green }
        if lower.contains("deny") || lower.contains("reject") { return .red }
        if lower.contains("limit") { return .orange }
        return .secondary
    }

    private func iptablesMatches(for rule: UFWRule) -> String {
        let port = firstNumber(in: rule.target)
        let lines = snapshot.iptables.lines().filter { line in
            guard let port else { return line.localizedCaseInsensitiveContains(rule.target) }
            return line.contains("--dport \(port)")
                || line.contains("--sport \(port)")
                || line.contains(" \(port) ")
                || line.localizedCaseInsensitiveContains(rule.action)
        }
        if lines.isEmpty {
            return "No obvious iptables line matched this rule. UFW's generated chains can vary by distro and backend."
        }
        return lines.joined(separator: "\n")
    }

    private func firstNumber(in text: String) -> String? {
        let pattern = #"\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range])
    }

    private func refreshLoop() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.refreshInterval)
            await refresh()
        }
    }

    private func refresh() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        let script = """
        command -v ufw >/dev/null || { echo ufw not found; exit 127; }
        echo '---STATUS---'
        status_out=$(sudo -n ufw status verbose 2>&1)
        status_rc=$?
        printf '%s\\n' "$status_out"
        [ "$status_rc" -eq 0 ] || exit "$status_rc"
        echo '---NUMBERED---'
        sudo -n ufw status numbered 2>&1 || true
        echo '---IPV6---'
        sudo -n sh -c "grep -E '^IPV6=' /etc/default/ufw 2>/dev/null || true" 2>&1 || true
        echo '---SSH---'
        printf 'SSH_CLIENT=%s\\nSSH_CONNECTION=%s\\n' "$SSH_CLIENT" "$SSH_CONNECTION"
        echo '---LOGS---'
        if sudo -n test -r /var/log/ufw.log 2>/dev/null; then
          sudo -n tail -n 300 /var/log/ufw.log 2>&1
        else
          sudo -n journalctl -k -n 300 --no-pager 2>/dev/null | grep -E 'UFW (BLOCK|ALLOW|AUDIT)' || true
        fi
        echo '---IPTABLES---'
        sudo -n iptables -S 2>/dev/null | nl -ba | sed -n '1,240p' || true
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            parseSnapshot(output)
            error = nil
        } catch {
            self.error = sudoFriendly(error.localizedDescription)
        }
    }

    private func parseSnapshot(_ output: String) {
        let status = output.section(after: "---STATUS---", before: "---NUMBERED---")
        let numbered = output.section(after: "---NUMBERED---", before: "---IPV6---")
        let ipv6 = output.section(after: "---IPV6---", before: "---SSH---")
        let ssh = output.section(after: "---SSH---", before: "---LOGS---")
        let logOutput = output.section(after: "---LOGS---", before: "---IPTABLES---")
        let iptables = output.section(after: "---IPTABLES---", before: nil)

        snapshot = UFWStatusSnapshot(
            active: status.lines().contains { $0.lowercased().hasPrefix("status: active") },
            rawStatus: status,
            numberedRules: numbered,
            ipv6: parseIPv6(ipv6),
            incomingPolicy: parsePolicy(status, key: "incoming"),
            outgoingPolicy: parsePolicy(status, key: "outgoing"),
            routedPolicy: parsePolicy(status, key: "routed"),
            logging: parseLogging(status),
            sshClientIp: parseSSHValue(ssh, key: "SSH_CLIENT").split(separator: " ").first.map(String.init) ?? "",
            sshServerPort: parseSSHServerPort(ssh),
            iptables: iptables
        )
        rules = parseRules(numbered)
        logs = parseLogs(logOutput)
        selectedRules = selectedRules.intersection(Set(rules.map(\.number)))
    }

    private func parseIPv6(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("ipv6=yes") { return "yes" }
        if lower.contains("ipv6=no") { return "no" }
        return "unknown"
    }

    private func parsePolicy(_ status: String, key: String) -> String {
        guard let defaultLine = status.lines().first(where: { $0.lowercased().hasPrefix("default:") }) else {
            return "-"
        }
        let pattern = #"([A-Za-z]+)\s+\(\#(key)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: defaultLine, range: NSRange(defaultLine.startIndex..., in: defaultLine)),
              let range = Range(match.range(at: 1), in: defaultLine)
        else { return "-" }
        return String(defaultLine[range]).lowercased()
    }

    private func parseLogging(_ status: String) -> String {
        guard let line = status.lines().first(where: { $0.lowercased().hasPrefix("logging:") }) else {
            return "-"
        }
        return line.replacingOccurrences(of: "Logging:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseSSHValue(_ ssh: String, key: String) -> String {
        ssh.lines()
            .first { $0.hasPrefix("\(key)=") }?
            .dropFirst(key.count + 1)
            .description ?? ""
    }

    private func parseSSHServerPort(_ ssh: String) -> Int? {
        let connection = parseSSHValue(ssh, key: "SSH_CONNECTION")
        let parts = connection.split(separator: " ").map(String.init)
        if parts.count >= 4, let port = Int(parts[3]) {
            return port
        }
        let client = parseSSHValue(ssh, key: "SSH_CLIENT")
        let clientParts = client.split(separator: " ").map(String.init)
        if clientParts.count >= 3, let port = Int(clientParts[2]) {
            return port
        }
        return nil
    }

    private func parseRules(_ text: String) -> [UFWRule] {
        text.lines().compactMap(parseRuleLine)
    }

    private func parseRuleLine(_ line: String) -> UFWRule? {
        let pattern = #"^\[\s*(\d+)\]\s+(.+?)\s{2,}(ALLOW(?:\s+IN|\s+OUT)?|DENY(?:\s+IN|\s+OUT)?|REJECT(?:\s+IN|\s+OUT)?|LIMIT(?:\s+IN|\s+OUT)?)\s{2,}(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges >= 5,
              let numberRange = Range(match.range(at: 1), in: line),
              let targetRange = Range(match.range(at: 2), in: line),
              let actionRange = Range(match.range(at: 3), in: line),
              let sourceRange = Range(match.range(at: 4), in: line),
              let number = Int(line[numberRange].trimmingCharacters(in: .whitespaces))
        else { return nil }

        var source = String(line[sourceRange]).trimmingCharacters(in: .whitespaces)
        var comment = ""
        if let commentRange = source.range(of: " # ") {
            comment = String(source[commentRange.upperBound...])
            source = String(source[..<commentRange.lowerBound])
        }
        return UFWRule(
            number: number,
            action: String(line[actionRange]).trimmingCharacters(in: .whitespaces),
            target: String(line[targetRange]).trimmingCharacters(in: .whitespaces),
            source: source,
            comment: comment,
            raw: line
        )
    }

    private func parseLogs(_ text: String) -> [UFWLogEntry] {
        text.lines().enumerated().compactMap { index, line in
            guard line.contains("[UFW ") else { return nil }
            let action = extractBracketAction(line)
            let kv = parseKeyValues(line)
            let timestamp = line.components(separatedBy: "[UFW ").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return UFWLogEntry(
                id: "\(index):\(line.hashValue)",
                timestamp: timestamp,
                action: action,
                interface: kv["IN"] ?? kv["OUT"] ?? "",
                source: kv["SRC"] ?? "",
                destination: kv["DST"] ?? "",
                protocolName: kv["PROTO"] ?? "",
                sourcePort: kv["SPT"] ?? "",
                destinationPort: kv["DPT"] ?? "",
                raw: line
            )
        }
    }

    private func extractBracketAction(_ line: String) -> String {
        guard let start = line.range(of: "[UFW "),
              let end = line[start.upperBound...].firstIndex(of: "]")
        else { return "UFW" }
        let content = String(line[start.upperBound..<end])
        return content.replacingOccurrences(of: "UFW ", with: "")
            .split(separator: " ")
            .first
            .map(String.init) ?? "UFW"
    }

    private func parseKeyValues(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        for token in line.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = String(parts[1])
        }
        return result
    }

    private func sudoFriendly(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("a password is required") || lower.contains("sudo") && lower.contains("password") {
            return "UFW inspection uses sudo -n. Configure passwordless sudo for ufw/log read commands, or run the commands manually in the terminal."
        }
        return message
    }
}

// MARK: - systemd

private struct SystemdUnit: Identifiable, Hashable {
    let name: String
    let load: String
    let active: String
    let sub: String
    let description: String

    var id: String { name }
    var statusSortKey: String { "\(active) \(sub)" }
}

struct MonitoredSystemdServiceStatus: Identifiable, Equatable {
    let name: String
    let active: String
    let sub: String
    let uptimeSeconds: UInt64?

    var id: String { name }

    var isRunning: Bool {
        active.lowercased() == "active"
    }
}

struct MonitoredSystemdServicesPane: View {
    let connectionId: String?
    let profileId: String?
    var isActive: Bool = true
    var onSelectService: (String) -> Void = { _ in }

    @ObservedObject private var connectionStore = ConnectionStoreManager.shared
    @State private var statuses: [MonitoredSystemdServiceStatus] = []
    @State private var error: String?
    @State private var loading = false

    private static let pollInterval: UInt64 = 5_000_000_000
    private static let unavailableMarker = "__MIDNIGHT_SSH_SYSTEMD_UNAVAILABLE__"

    private var serviceNames: [String] {
        connectionStore.monitoredSystemdServices(profileId: profileId)
    }

    private var pollKey: String {
        "\(connectionId ?? "none"):\(profileId ?? "none"):\(isActive):\(serviceNames.joined(separator: ","))"
    }

    private var rows: [MonitoredSystemdServiceStatus] {
        let byName = Dictionary(uniqueKeysWithValues: statuses.map { ($0.name, $0) })
        return serviceNames.map {
            byName[$0] ?? MonitoredSystemdServiceStatus(
                name: $0,
                active: "unknown",
                sub: "unknown",
                uptimeSeconds: nil
            )
        }
    }

    var body: some View {
        if !serviceNames.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "switch.2")
                        .foregroundStyle(.secondary)
                    Text("systemd")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if loading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                VStack(spacing: 4) {
                    ForEach(rows) { service in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(service.isRunning ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(service.name)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(formatServiceUptime(service.uptimeSeconds))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelectService(service.name)
                        }
                        .help("\(service.name): \(service.active) \(service.sub)")
                    }
                }
            }
            .task(id: pollKey) {
                guard isActive, connectionId != nil else { return }
                await pollLoop()
            }
        }
    }

    private func pollLoop() async {
        await refreshStatuses()
        while !Task.isCancelled && isActive && !serviceNames.isEmpty {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            await refreshStatuses()
        }
    }

    private func refreshStatuses() async {
        guard let connectionId, !serviceNames.isEmpty else {
            statuses = []
            error = nil
            return
        }

        loading = true
        defer { loading = false }

        let units = serviceNames.map(RemoteCommandRunner.shellQuote).joined(separator: " ")
        let script = """
        command -v systemctl >/dev/null || { echo \(Self.unavailableMarker); exit 0; }
        now_usec=$(awk '{printf "%.0f", $1 * 1000000}' /proc/uptime 2>/dev/null || echo 0)
        for unit in \(units); do
          show=$(systemctl show "$unit" --no-pager -p ActiveState -p SubState -p ActiveEnterTimestampMonotonic 2>/dev/null || true)
          active=$(printf '%s\\n' "$show" | awk -F= '$1=="ActiveState"{print $2; exit}')
          sub=$(printf '%s\\n' "$show" | awk -F= '$1=="SubState"{print $2; exit}')
          mono=$(printf '%s\\n' "$show" | awk -F= '$1=="ActiveEnterTimestampMonotonic"{print $2; exit}')
          uptime="-"
          if [ "${active:-unknown}" = "active" ] && [ -n "$mono" ] && [ "$mono" -gt 0 ] 2>/dev/null && [ "$now_usec" -gt "$mono" ] 2>/dev/null; then
            uptime=$(( (now_usec - mono) / 1000000 ))
          fi
          printf '%s\\t%s\\t%s\\t%s\\n' "$unit" "${active:-unknown}" "${sub:-unknown}" "$uptime"
        done
        """

        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            if output.lines().contains(Self.unavailableMarker) {
                statuses = []
                error = "systemd unavailable"
            } else {
                statuses = parseMonitoredSystemdServiceStatuses(output)
                error = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func parseMonitoredSystemdServiceStatuses(_ output: String) -> [MonitoredSystemdServiceStatus] {
        output.lines().compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return nil }
            return MonitoredSystemdServiceStatus(
                name: parts[0],
                active: parts[1],
                sub: parts[2],
                uptimeSeconds: UInt64(parts[3])
            )
        }
    }

    private func formatServiceUptime(_ seconds: UInt64?) -> String {
        guard let seconds else { return "-" }
        if seconds < 60 { return "\(seconds)s" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

private struct SystemdTimer: Identifiable, Hashable {
    let timer: String
    let next: String
    let left: String
    let last: String
    let passed: String
    let unit: String
    let activates: String

    var id: String { timer }
}

private func parseSystemdUnitLine(_ line: String) -> SystemdUnit? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var fields = trimmed.split(maxSplits: 4, whereSeparator: \.isWhitespace).map(String.init)
    if fields.first == "●" {
        fields.removeFirst()
    }
    guard fields.count >= 4, fields[0].hasSuffix(".service") else { return nil }

    return SystemdUnit(
        name: fields[0],
        load: fields[1],
        active: fields[2],
        sub: fields[3],
        description: fields.count >= 5 ? fields[4] : ""
    )
}

private func parseSystemdTimerLine(_ line: String) -> SystemdTimer? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    if fields.first == "●" {
        fields.removeFirst()
    }
    guard let timerIndex = fields.firstIndex(where: { $0.hasSuffix(".timer") }) else { return nil }

    let timer = fields[timerIndex]
    let activates = fields.dropFirst(timerIndex + 1).joined(separator: " ")
    let schedule = Array(fields[..<timerIndex])
    let parsedSchedule = parseSystemdTimerSchedule(schedule)

    return SystemdTimer(
        timer: timer,
        next: parsedSchedule.next,
        left: parsedSchedule.left,
        last: parsedSchedule.last,
        passed: parsedSchedule.passed,
        unit: timer,
        activates: activates
    )
}

private func parseSystemdTimerSchedule(_ fields: [String]) -> (next: String, left: String, last: String, passed: String) {
    guard !fields.isEmpty else {
        return ("", "", "", "")
    }
    if fields.count >= 4 && fields.prefix(4).allSatisfy({ $0 == "n/a" }) {
        return ("n/a", "n/a", "n/a", "n/a")
    }

    let nextEnd = systemdTimestampEnd(in: fields, from: 0)
    let next = fields[0..<nextEnd].joined(separator: " ")

    var cursor = nextEnd
    let left: String
    let lastStart: Int
    if next == "n/a", cursor < fields.count {
        left = fields[cursor]
        cursor += 1
        lastStart = cursor
    } else if let foundLastStart = systemdTimestampStart(in: fields, from: cursor) {
        lastStart = foundLastStart
        left = fields[cursor..<foundLastStart].joined(separator: " ")
    } else {
        return (next, fields[cursor...].joined(separator: " "), "", "")
    }

    guard lastStart < fields.count else {
        return (next, left, "", "")
    }
    let lastEnd = systemdTimestampEnd(in: fields, from: lastStart)
    let last = fields[lastStart..<lastEnd].joined(separator: " ")
    let passed = lastEnd < fields.count ? fields[lastEnd...].joined(separator: " ") : ""
    return (next, left, last, passed)
}

private func systemdTimestampStart(in fields: [String], from start: Int) -> Int? {
    guard start < fields.count else { return nil }
    for index in start..<fields.count {
        if fields[index] == "n/a" {
            return index
        }
        if isSystemdWeekday(fields[index]),
           index + 2 < fields.count,
           looksLikeSystemdDate(fields[index + 1]),
           looksLikeSystemdTime(fields[index + 2]) {
            return index
        }
        if looksLikeSystemdDate(fields[index]),
           index + 1 < fields.count,
           looksLikeSystemdTime(fields[index + 1]) {
            return index
        }
    }
    return nil
}

private func systemdTimestampEnd(in fields: [String], from start: Int) -> Int {
    guard start < fields.count else { return start }
    if fields[start] == "n/a" {
        return start + 1
    }
    if isSystemdWeekday(fields[start]),
       start + 2 < fields.count,
       looksLikeSystemdDate(fields[start + 1]),
       looksLikeSystemdTime(fields[start + 2]) {
        return min(start + 4, fields.count)
    }
    if looksLikeSystemdDate(fields[start]),
       start + 1 < fields.count,
       looksLikeSystemdTime(fields[start + 1]) {
        return min(start + 3, fields.count)
    }
    return start + 1
}

private func isSystemdWeekday(_ value: String) -> Bool {
    ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].contains(value)
}

private func looksLikeSystemdDate(_ value: String) -> Bool {
    value.count == 10 && value[value.index(value.startIndex, offsetBy: 4)] == "-"
}

private func looksLikeSystemdTime(_ value: String) -> Bool {
    value.contains(":")
}

struct SystemdMonitorView: View {
    let connectionId: String?
    let profileId: String?
    let connectionLabel: String

    private enum Mode: String, CaseIterable {
        case services = "Services"
        case failed = "Failed"
        case timers = "Timers"
        case journal = "Journal"
    }

    @State private var mode: Mode = .services
    @State private var units: [SystemdUnit] = []
    @State private var timers: [SystemdTimer] = []
    @State private var selectedUnit: SystemdUnit?
    @State private var selectedTimer: SystemdTimer?
    @State private var unitDetail: String = ""
    @State private var dependencies: String = ""
    @State private var journal: String = ""
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false
    @State private var liveJournal = false
    @State private var pendingAction: UnitAction?
    @State private var unitSortOrder: [KeyPathComparator<SystemdUnit>] = [
        .init(\.name)
    ]
    @ObservedObject private var connectionStore = ConnectionStoreManager.shared

    private let logger = Logger(subsystem: "com.r-shell", category: "systemd-monitor")
    private static let pollInterval: UInt64 = 5_000_000_000

    fileprivate struct UnitAction: Identifiable {
        let id = UUID()
        let verb: String
        let unit: String
        var destructive: Bool {
            ["stop", "restart", "kill", "disable", "mask"].contains(verb)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if connectionId == nil {
                placeholderView(
                    icon: "network.slash",
                    title: "No connection",
                    message: "Open an SSH workspace to inspect systemd."
                )
            } else if let error {
                errorPane(error)
            } else {
                content
            }
        }
        .task(id: "\(connectionId ?? "none"):\(mode.rawValue)") {
            await refresh()
            if mode == .journal && liveJournal {
                await journalLoop()
            }
        }
        .onChange(of: selectedUnit?.id) { _ in
            Task { await loadSelectedUnitDetail() }
        }
        .confirmationDialog(
            "Confirm systemd action",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            Button("\(action.verb) \(action.unit)", role: action.destructive ? .destructive : nil) {
                Task { await run(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text("Run systemctl \(action.verb) on \(connectionLabel)?")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "switch.2")
                .foregroundStyle(.secondary)
            Text("systemd")
                .font(.subheadline.weight(.medium))
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)
            TextField("Filter", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            if mode == .journal {
                Toggle("Live", isOn: $liveJournal)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(connectionId == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .services, .failed:
            HSplitView {
                unitList
                    .frame(minWidth: 360, idealWidth: 560)
                unitDetailPane
                    .frame(minWidth: 320)
            }
        case .timers:
            timerList
        case .journal:
            journalPane
        }
    }

    private var filteredUnits: [SystemdUnit] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = mode == .failed ? units.filter { $0.active == "failed" || $0.sub == "failed" } : units
        guard !needle.isEmpty else { return base }
        return base.filter {
            $0.name.lowercased().contains(needle)
                || $0.description.lowercased().contains(needle)
                || $0.active.lowercased().contains(needle)
        }
    }

    private var sortedFilteredUnits: [SystemdUnit] {
        filteredUnits.sorted(using: unitSortOrder)
    }

    private var unitList: some View {
        Table(sortedFilteredUnits, selection: Binding(
            get: { selectedUnit?.id },
            set: { id in selectedUnit = units.first { $0.id == id } }
        ), sortOrder: $unitSortOrder) {
            TableColumn("Monitor") { unit in
                Toggle("", isOn: Binding(
                    get: {
                        connectionStore.isMonitoringSystemdService(unit.name, profileId: profileId)
                    },
                    set: {
                        connectionStore.setMonitoringSystemdService($0, serviceName: unit.name, profileId: profileId)
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
                .disabled(connectionId == nil)
                .help("Show \(unit.name) in the monitor pane")
            }
            .width(min: 70, ideal: 80, max: 90)

            TableColumn("Service", value: \.name) { unit in
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(unit.active))
                        .frame(width: 8, height: 8)
                    Text(unit.name)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
            }
            .width(min: 180, ideal: 260)

            TableColumn("Status", value: \.statusSortKey) { unit in
                HStack(spacing: 5) {
                    Text(unit.active)
                        .font(.caption2.monospaced())
                        .foregroundStyle(statusColor(unit.active))
                    Text(unit.sub)
                        .font(.caption2.monospaced())
                        .foregroundStyle(statusColor(unit.sub))
                }
            }
            .width(min: 100, ideal: 130)

            TableColumn("Description", value: \.description) { unit in
                Text(unit.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contextMenu(forSelectionType: String.self) { selected in
            if let unit = selected.first {
                unitActions(unit)
            }
        }
    }

    private var timerList: some View {
        List(filteredTimers) { timer in
            HStack(spacing: 8) {
                monoCell(timer.timer, width: 210)
                monoCell(timer.next, width: 170, color: .secondary)
                monoCell(timer.left, width: 90)
                monoCell(timer.activates)
            }
            .contextMenu {
                Button("Show Linked Service") {
                    mode = .services
                    if let unit = units.first(where: { $0.name == timer.activates }) {
                        selectedUnit = unit
                    }
                }
                Button("Copy Timer") { RemoteCommandRunner.copy(timer.timer) }
            }
        }
        .listStyle(.plain)
    }

    private var filteredTimers: [SystemdTimer] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return timers }
        return timers.filter {
            $0.timer.lowercased().contains(needle)
                || $0.activates.lowercased().contains(needle)
        }
    }

    private var unitDetailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selectedUnit {
                HStack {
                    Text(selectedUnit.name)
                        .font(.headline)
                    Spacer()
                    Menu("Actions") { unitActions(selectedUnit.name) }
                }
                .padding(10)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        detailBlock("Properties", unitDetail)
                        detailBlock("Dependencies", dependencies)
                        detailBlock("Journal", journal)
                    }
                    .padding(10)
                }
            } else {
                placeholderView(
                    icon: "list.bullet.rectangle",
                    title: "Select a unit",
                    message: "Choose a service to inspect properties, dependencies, and recent journal entries."
                )
            }
        }
    }

    private var journalPane: some View {
        VStack(spacing: 0) {
            if let selectedUnit {
                HStack {
                    Text(selectedUnit.name)
                        .font(.caption.monospaced())
                    Spacer()
                    Button("Copy") { RemoteCommandRunner.copy(journal) }
                        .disabled(journal.isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                Divider()
                logText(journal)
            } else {
                placeholderView(
                    icon: "doc.text.magnifyingglass",
                    title: "Select a unit",
                    message: "Pick a service in the Services or Failed tab, then switch back to Journal."
                )
            }
        }
    }

    private func detailBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            logText(value.isEmpty ? "-" : value)
                .frame(minHeight: title == "Journal" ? 160 : 90)
        }
    }

    private func logText(_ value: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(value.isEmpty ? "-" : value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func unitActions(_ unit: String) -> some View {
        Button("Start") { pendingAction = UnitAction(verb: "start", unit: unit) }
        Button("Stop", role: .destructive) { pendingAction = UnitAction(verb: "stop", unit: unit) }
        Button("Restart", role: .destructive) { pendingAction = UnitAction(verb: "restart", unit: unit) }
        Button("Reload") { pendingAction = UnitAction(verb: "reload", unit: unit) }
        Divider()
        Button("Enable") { pendingAction = UnitAction(verb: "enable", unit: unit) }
        Button("Disable", role: .destructive) { pendingAction = UnitAction(verb: "disable", unit: unit) }
        Button("Mask", role: .destructive) { pendingAction = UnitAction(verb: "mask", unit: unit) }
        Button("Unmask") { pendingAction = UnitAction(verb: "unmask", unit: unit) }
        Divider()
        Button("Copy Unit Name") { RemoteCommandRunner.copy(unit) }
    }

    private func refresh() async {
        guard connectionId != nil else { return }
        switch mode {
        case .services, .failed:
            await loadUnits()
        case .timers:
            await loadTimers()
        case .journal:
            await loadSelectedUnitDetail()
        }
    }

    private func loadUnits() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        let script = """
        command -v systemctl >/dev/null || { echo systemctl not found; exit 127; }
        export LC_ALL=C
        out=$(systemctl list-units --type=service --all --no-legend --no-pager 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
          sudo_out=$(sudo -n systemctl list-units --type=service --all --no-legend --no-pager 2>&1)
          sudo_rc=$?
          if [ "$sudo_rc" -eq 0 ]; then
            out=$sudo_out
            rc=0
          else
            out=$(printf 'systemctl list-units failed:\\n%s\\n\\nsudo -n systemctl list-units failed:\\n%s\\n' "$out" "$sudo_out")
            rc=$sudo_rc
          fi
        fi
        if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
          out="systemctl list-units failed with exit code $rc and no output"
        fi
        if [ "$rc" -ne 0 ]; then
          printf '%s\\n' "$out"
          exit "$rc"
        fi
        printf '%s\\n' "$out"
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            let parsed = output.lines().compactMap(parseSystemdUnitLine)
            units = parsed
            if selectedUnit == nil {
                selectedUnit = parsed.first { $0.active == "failed" } ?? parsed.first
            }
            error = nil
            await loadSelectedUnitDetail()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadTimers() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        let script = """
        command -v systemctl >/dev/null || { echo systemctl not found; exit 127; }
        export LC_ALL=C
        out=$(systemctl list-timers --all --no-legend --no-pager 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
          sudo_out=$(sudo -n systemctl list-timers --all --no-legend --no-pager 2>&1)
          sudo_rc=$?
          if [ "$sudo_rc" -eq 0 ]; then
            out=$sudo_out
            rc=0
          else
            out=$(printf 'systemctl list-timers failed:\\n%s\\n\\nsudo -n systemctl list-timers failed:\\n%s\\n' "$out" "$sudo_out")
            rc=$sudo_rc
          fi
        fi
        if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
          out="systemctl list-timers failed with exit code $rc and no output"
        fi
        if [ "$rc" -ne 0 ]; then
          printf '%s\\n' "$out"
          exit "$rc"
        fi
        printf '%s\\n' "$out"
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            timers = output.lines().compactMap(parseSystemdTimerLine)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadSelectedUnitDetail() async {
        guard let connectionId, let selectedUnit else { return }
        let unit = RemoteCommandRunner.shellQuote(selectedUnit.name)
        let script = """
        command -v systemctl >/dev/null || { echo systemctl not found; exit 127; }
        run_systemctl() {
          out=$(systemctl "$@" 2>&1)
          rc=$?
          if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
            sudo -n systemctl "$@" 2>&1
          else
            printf '%s\\n' "$out"
            return "$rc"
          fi
        }
        run_journalctl() {
          out=$(journalctl "$@" 2>&1)
          rc=$?
          if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
            sudo -n journalctl "$@" 2>&1
          else
            printf '%s\\n' "$out"
            return "$rc"
          fi
        }
        echo '---PROPERTIES---'
        run_systemctl show \(unit) --no-pager -p Id -p Description -p LoadState -p ActiveState -p SubState -p UnitFileState -p NRestarts -p MainPID -p ActiveEnterTimestamp -p FragmentPath -p MemoryCurrent -p CPUUsageNSec || true
        echo '---DEPENDENCIES---'
        run_systemctl list-dependencies --plain --no-pager \(unit) | sed -n '1,120p' || true
        echo '---REVERSE---'
        run_systemctl list-dependencies --reverse --plain --no-pager \(unit) | sed -n '1,80p' || true
        echo '---JOURNAL---'
        run_journalctl -u \(unit) -n 160 --no-pager -o short-iso || true
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            unitDetail = output.section(after: "---PROPERTIES---", before: "---DEPENDENCIES---")
            dependencies = output.section(after: "---DEPENDENCIES---", before: "---JOURNAL---")
            journal = output.section(after: "---JOURNAL---", before: nil)
            error = nil
        } catch {
            unitDetail = "Could not load unit details: \(error.localizedDescription)"
            dependencies = ""
            journal = ""
        }
    }

    private func journalLoop() async {
        while !Task.isCancelled && liveJournal {
            await loadSelectedUnitDetail()
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    private func run(_ action: UnitAction) async {
        guard let connectionId else { return }
        pendingAction = nil
        let script = "systemctl \(action.verb) \(RemoteCommandRunner.shellQuote(action.unit)) 2>&1"
        do {
            _ = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            await loadUnits()
        } catch {
            logger.error("systemctl \(action.verb, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    private func errorPane(_ message: String) -> some View {
        placeholderView(icon: "exclamationmark.triangle", title: "systemd unavailable", message: message)
    }
}

// MARK: - Docker

private struct DockerContainer: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let status: String
    let ports: String
    let cpu: String
    let memory: String
    let netIO: String
    let health: String
    let restarts: String
    let composeProject: String
}

private struct DockerAsset: Identifiable, Hashable {
    let id: String
    let columns: [String]
}

struct DockerMonitorView: View {
    let connectionId: String?
    let connectionLabel: String

    private enum Mode: String, CaseIterable {
        case containers = "Containers"
        case logs = "Logs"
        case images = "Images"
        case volumes = "Volumes"
        case networks = "Networks"
        case events = "Events"
        case disk = "Disk"
    }

    @State private var mode: Mode = .containers
    @State private var containers: [DockerContainer] = []
    @State private var selectedContainerId: String?
    @State private var images: [DockerAsset] = []
    @State private var volumes: [DockerAsset] = []
    @State private var networks: [DockerAsset] = []
    @State private var events: String = ""
    @State private var diskUsage: String = ""
    @State private var logs: String = ""
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false
    @State private var liveLogs = false
    @State private var pendingAction: DockerAction?

    private static let pollInterval: UInt64 = 5_000_000_000

    fileprivate struct DockerAction: Identifiable {
        let id = UUID()
        let verb: String
        let target: String
        var destructive: Bool {
            ["stop", "restart", "kill", "rm", "pause"].contains(verb)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if connectionId == nil {
                placeholderView(icon: "network.slash", title: "No connection", message: "Open an SSH workspace to inspect Docker.")
            } else if let error {
                placeholderView(icon: "exclamationmark.triangle", title: "Docker unavailable", message: error)
            } else {
                content
            }
        }
        .task(id: "\(connectionId ?? "none"):\(mode.rawValue)") {
            await refresh()
            if mode == .logs && liveLogs {
                await logsLoop()
            }
        }
        .confirmationDialog(
            "Confirm Docker action",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            Button("docker \(action.verb) \(action.target)", role: action.destructive ? .destructive : nil) {
                Task { await run(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This runs on \(connectionLabel).")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
            Text("Docker")
                .font(.subheadline.weight(.medium))
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 520)
            TextField("Filter", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            if mode == .logs {
                Toggle("Live", isOn: $liveLogs)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(connectionId == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .containers:
            containerList
        case .logs:
            logsPane
        case .images:
            assetList(images, headers: ["Image", "ID", "Size", "Created"])
        case .volumes:
            assetList(volumes, headers: ["Volume", "Driver"])
        case .networks:
            assetList(networks, headers: ["Network", "Driver", "Scope"])
        case .events:
            logText(events)
        case .disk:
            logText(diskUsage)
        }
    }

    private var filteredContainers: [DockerContainer] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return containers }
        return containers.filter {
            $0.name.lowercased().contains(needle)
                || $0.image.lowercased().contains(needle)
                || $0.composeProject.lowercased().contains(needle)
        }
    }

    private var containerList: some View {
        List(selection: $selectedContainerId) {
            ForEach(groupedContainers.keys.sorted(), id: \.self) { group in
                Section(group.isEmpty ? "Standalone" : group) {
                    ForEach(groupedContainers[group] ?? []) { container in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor(container.status + container.health))
                                .frame(width: 8, height: 8)
                            monoCell(container.name, width: 170)
                            monoCell(container.image, width: 180, color: .secondary)
                            monoCell(container.status, width: 170, color: statusColor(container.status))
                            monoCell(container.health, width: 70, color: statusColor(container.health))
                            monoCell(container.cpu, width: 70)
                            monoCell(container.memory, width: 140)
                            monoCell(container.netIO)
                        }
                        .tag(container.id)
                        .contextMenu { dockerActions(container) }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var groupedContainers: [String: [DockerContainer]] {
        Dictionary(grouping: filteredContainers) { $0.composeProject }
    }

    private var logsPane: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Container", selection: $selectedContainerId) {
                    Text("Select a container").tag(nil as String?)
                    ForEach(containers) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(width: 260)
                Spacer()
                Button("Exec Shell Command") {
                    if let container = selectedContainer {
                        runExecShell(container)
                    }
                }
                .disabled(selectedContainer == nil)
                Button("Copy Logs") { RemoteCommandRunner.copy(logs) }
                    .disabled(logs.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            logText(logs)
        }
    }

    private var selectedContainer: DockerContainer? {
        guard let selectedContainerId else { return containers.first }
        return containers.first { $0.id == selectedContainerId }
    }

    private func assetList(_ assets: [DockerAsset], headers: [String]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(headers, id: \.self) { header in
                    Text(header)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            List(assets) { asset in
                HStack(spacing: 10) {
                    ForEach(Array(asset.columns.enumerated()), id: \.offset) { _, column in
                        monoCell(column)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func logText(_ value: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(value.isEmpty ? "-" : value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    private func dockerActions(_ container: DockerContainer) -> some View {
        Button("Start") { pendingAction = DockerAction(verb: "start", target: container.id) }
        Button("Stop", role: .destructive) { pendingAction = DockerAction(verb: "stop", target: container.id) }
        Button("Restart", role: .destructive) { pendingAction = DockerAction(verb: "restart", target: container.id) }
        Button("Pause", role: .destructive) { pendingAction = DockerAction(verb: "pause", target: container.id) }
        Button("Unpause") { pendingAction = DockerAction(verb: "unpause", target: container.id) }
        Button("Kill", role: .destructive) { pendingAction = DockerAction(verb: "kill", target: container.id) }
        Button("Remove", role: .destructive) { pendingAction = DockerAction(verb: "rm", target: container.id) }
        Divider()
        Button("Show Logs") {
            selectedContainerId = container.id
            mode = .logs
            Task { await loadLogs() }
        }
        Button("Run Exec Shell in Terminal") {
            runExecShell(container)
        }
        Button("Copy Exec Shell Command") {
            RemoteCommandRunner.copy(execShellCommand(container))
        }
    }

    private func refresh() async {
        switch mode {
        case .containers, .logs:
            await loadContainers()
            if mode == .logs { await loadLogs() }
        case .images:
            await loadImages()
        case .volumes:
            await loadVolumes()
        case .networks:
            await loadNetworks()
        case .events:
            await loadEvents()
        case .disk:
            await loadDiskUsage()
        }
    }

    private func loadContainers() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        let script = """
        command -v docker >/dev/null || { echo docker not found; exit 127; }
        sep=$(printf '\\037')
        ids=$(docker ps -aq 2>/dev/null)
        [ -n "$ids" ] || exit 0
        docker ps -a --format "{{.ID}}${sep}{{.Names}}${sep}{{.Image}}${sep}{{.Status}}${sep}{{.Ports}}" > /tmp/rshell_docker_ps_$$
        docker stats --no-stream --format "{{.Name}}${sep}{{.CPUPerc}}${sep}{{.MemUsage}}${sep}{{.NetIO}}" > /tmp/rshell_docker_stats_$$ 2>/dev/null || true
        while IFS="$sep" read -r id name image status ports; do
          stats=$(awk -F "$sep" -v n="$name" '$1==n {print $2 FS $3 FS $4; exit}' /tmp/rshell_docker_stats_$$)
          cpu=$(printf "%s" "$stats" | awk -F "$sep" '{print $1}')
          mem=$(printf "%s" "$stats" | awk -F "$sep" '{print $2}')
          net=$(printf "%s" "$stats" | awk -F "$sep" '{print $3}')
          inspect=$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}${sep}{{.RestartCount}}${sep}{{index .Config.Labels \\"com.docker.compose.project\\"}}" "$id" 2>/dev/null || true)
          health=$(printf "%s" "$inspect" | awk -F "$sep" '{print $1}')
          restarts=$(printf "%s" "$inspect" | awk -F "$sep" '{print $2}')
          compose=$(printf "%s" "$inspect" | awk -F "$sep" '{print $3}')
          printf "%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\\n" "$id" "$sep" "$name" "$sep" "$image" "$sep" "$status" "$sep" "$ports" "$sep" "$cpu" "$sep" "$mem" "$sep" "$net" "$sep" "$health" "$sep" "$restarts" "$sep" "$compose"
        done < /tmp/rshell_docker_ps_$$
        rm -f /tmp/rshell_docker_ps_$$ /tmp/rshell_docker_stats_$$
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            containers = output.lines().compactMap { line in
                let p = splitFields(line)
                guard p.count >= 11 else { return nil }
                return DockerContainer(id: p[0], name: p[1], image: p[2], status: p[3], ports: p[4], cpu: p[5], memory: p[6], netIO: p[7], health: p[8], restarts: p[9], composeProject: p[10])
            }
            if selectedContainerId == nil { selectedContainerId = containers.first?.id }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadLogs() async {
        guard let connectionId, let container = selectedContainer else { return }
        let script = "docker logs --tail 240 --timestamps \(RemoteCommandRunner.shellQuote(container.id)) 2>&1"
        do {
            logs = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadImages() async {
        await loadAsset(
            script: "sep=$(printf '\\037'); docker images --format \"{{.Repository}}:{{.Tag}}${sep}{{.ID}}${sep}{{.Size}}${sep}{{.CreatedSince}}\"",
            assign: { images = $0 }
        )
    }

    private func loadVolumes() async {
        await loadAsset(
            script: "sep=$(printf '\\037'); docker volume ls --format \"{{.Name}}${sep}{{.Driver}}\"",
            assign: { volumes = $0 }
        )
    }

    private func loadNetworks() async {
        await loadAsset(
            script: "sep=$(printf '\\037'); docker network ls --format \"{{.Name}}${sep}{{.Driver}}${sep}{{.Scope}}\"",
            assign: { networks = $0 }
        )
    }

    private func loadAsset(script: String, assign: ([DockerAsset]) -> Void) async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        do {
            let output = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: "command -v docker >/dev/null || { echo docker not found; exit 127; }\n\(script) 2>&1"
            )
            let assets = output.lines().enumerated().map { index, line in
                DockerAsset(id: "\(index):\(line)", columns: splitFields(line))
            }
            assign(assets)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadEvents() async {
        guard let connectionId else { return }
        do {
            events = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: "command -v docker >/dev/null || { echo docker not found; exit 127; }\nnow=$(date -u +%Y-%m-%dT%H:%M:%SZ); docker events --since 30m --until \"$now\" --format '{{.Time}}  {{.Type}}  {{.Action}}  {{.Actor.Attributes.name}}' 2>&1"
            )
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadDiskUsage() async {
        guard let connectionId else { return }
        do {
            diskUsage = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: "command -v docker >/dev/null || { echo docker not found; exit 127; }\ndocker system df -v 2>&1"
            )
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func logsLoop() async {
        while !Task.isCancelled && liveLogs {
            await loadLogs()
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    private func run(_ action: DockerAction) async {
        guard let connectionId else { return }
        pendingAction = nil
        do {
            _ = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: "docker \(action.verb) \(RemoteCommandRunner.shellQuote(action.target)) 2>&1"
            )
            await loadContainers()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func execShellCommand(_ container: DockerContainer) -> String {
        "docker exec -it \(RemoteCommandRunner.shellQuote(container.name)) sh"
    }

    private func runExecShell(_ container: DockerContainer) {
        guard let connectionId else { return }
        guard let data = "\(execShellCommand(container))\n".data(using: .utf8) else { return }
        TerminalSessionManager.shared.sendInput(connectionId: connectionId, data: data)
    }
}

// MARK: - PostgreSQL

private struct PostgresSettings: Equatable {
    var database: String = "postgres"
    var host: String = ""
    var port: String = ""
    var user: String = ""
    var extraArgs: String = ""
    var runAsPostgresUser: Bool = true
    var osUser: String = "postgres"

    func baseArgs(binary: String) -> [String] {
        var args = [binary]
        if binary == "psql" {
            args += ["-X", "-v", "ON_ERROR_STOP=1", "-qAt"]
        } else if binary == "pg_dump" {
            args += ["-Fc"]
        }
        if !database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-d", RemoteCommandRunner.shellQuote(database)]
        }
        if !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-h", RemoteCommandRunner.shellQuote(host)]
        }
        if !port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-p", RemoteCommandRunner.shellQuote(port)]
        }
        if !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-U", RemoteCommandRunner.shellQuote(user)]
        }
        if !extraArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(extraArgs)
        }
        return args
    }

    func queryScript(_ sql: String) -> String {
        let command = (baseArgs(binary: "psql") + [
            "-F", "\"$(printf '\\037')\"",
            "-c", RemoteCommandRunner.shellQuote(sql),
        ]).joined(separator: " ")
        return runInConfiguredUser(command, binary: "psql")
    }

    func dumpScript(path: String) -> String {
        let command = (baseArgs(binary: "pg_dump") + [
            "-f", RemoteCommandRunner.shellQuote(path),
        ]).joined(separator: " ")
        return runInConfiguredUser(command, binary: "pg_dump")
    }

    private func runInConfiguredUser(_ command: String, binary: String) -> String {
        let inner = """
        command -v \(binary) >/dev/null || { echo \(binary) not found for $(id -un); exit 127; }
        \(command) 2>&1
        """
        guard runAsPostgresUser else { return inner }

        let user = osUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "postgres"
            : osUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotedUser = RemoteCommandRunner.shellQuote(user)
        let quotedInner = RemoteCommandRunner.shellQuote(inner)
        let suCommand = "sh -lc \(quotedInner)"
        let quotedSuCommand = RemoteCommandRunner.shellQuote(suCommand)
        return """
        if [ "$(id -un)" = \(quotedUser) ]; then
          sh -lc \(quotedInner)
          exit $?
        fi

        rc=127
        if command -v sudo >/dev/null; then
          sudo -n -u \(quotedUser) sh -lc \(quotedInner)
          rc=$?
          [ "$rc" -eq 0 ] && exit 0
        fi

        if command -v su >/dev/null; then
          su \(quotedUser) -c \(quotedSuCommand)
          rc=$?
          [ "$rc" -eq 0 ] && exit 0

          su - \(quotedUser) -c \(quotedSuCommand)
          rc=$?
          [ "$rc" -eq 0 ] && exit 0
        fi

        echo "Could not run \(binary) as \(user). Tried current user, sudo -n -u \(user), su \(user), and su - \(user). Last exit: $rc"
        exit "$rc"
        """
    }
}

private struct SQLResult {
    let columns: [String]
    let rows: [[String]]
}

private struct PGSession: Identifiable, Hashable {
    let pid: String
    let user: String
    let app: String
    let client: String
    let state: String
    let wait: String
    let age: String
    let query: String

    var id: String { pid }
}

private struct PGTableInfo: Identifiable, Hashable {
    let schema: String
    let name: String
    let kind: String
    let size: String
    let estimate: String

    var id: String { "\(schema).\(name)" }
}

struct PostgresMonitorView: View {
    let connectionId: String?
    let connectionLabel: String

    private enum Mode: String, CaseIterable {
        case dashboard = "Dashboard"
        case sessions = "Sessions"
        case locks = "Locks"
        case query = "Query"
        case schema = "Schema"
        case explain = "Explain"
        case slow = "Slow"
        case replication = "Replication"
        case vacuum = "Vacuum"
        case backup = "Backup"
    }

    @EnvironmentObject var transfers: TransferQueueStore
    @State private var settings = PostgresSettings()
    @State private var mode: Mode = .dashboard
    @State private var dashboard: String = ""
    @State private var sessions: [PGSession] = []
    @State private var selectedPid: String?
    @State private var locks: String = ""
    @State private var queryText: String = "select now(), current_database(), current_user;"
    @State private var queryResult = SQLResult(columns: [], rows: [])
    @State private var schemaRows: [PGTableInfo] = []
    @State private var selectedTableId: String?
    @State private var tableDetail: String = ""
    @State private var explainText: String = ""
    @State private var slowQueries: String = ""
    @State private var replication: String = ""
    @State private var vacuum: String = ""
    @State private var backupPath: String = "/tmp/r-shell-postgres.dump"
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false
    @State private var pendingBackendAction: BackendAction?

    fileprivate struct BackendAction: Identifiable {
        let id = UUID()
        let function: String
        let pid: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            connectionForm
            Divider()
            if connectionId == nil {
                placeholderView(icon: "network.slash", title: "No connection", message: "Open an SSH workspace to inspect PostgreSQL.")
            } else if let error {
                placeholderView(icon: "exclamationmark.triangle", title: "PostgreSQL unavailable", message: error)
            } else {
                content
            }
        }
        .task(id: "\(connectionId ?? "none"):\(mode.rawValue)") {
            await refresh()
        }
        .onChange(of: selectedTableId) { _ in
            Task { await loadTableDetail() }
        }
        .confirmationDialog(
            "Confirm backend action",
            isPresented: Binding(
                get: { pendingBackendAction != nil },
                set: { if !$0 { pendingBackendAction = nil } }
            ),
            presenting: pendingBackendAction
        ) { action in
            Button("\(action.function) \(action.pid)", role: action.function.contains("terminate") ? .destructive : nil) {
                Task { await runBackendAction(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text("This executes SELECT \(action.function)(\(action.pid)) on \(settings.database).")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(.secondary)
            Text("PostgreSQL")
                .font(.subheadline.weight(.medium))
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 660)
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(connectionId == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var connectionForm: some View {
        HStack(spacing: 8) {
            TextField("Database", text: $settings.database)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
            TextField("Host", text: $settings.host)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            TextField("Port", text: $settings.port)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            TextField("User", text: $settings.user)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            Toggle("OS user", isOn: $settings.runAsPostgresUser)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Run psql/pg_dump as the selected OS account using sudo -n or su")
            TextField("OS user", text: $settings.osUser)
                .textFieldStyle(.roundedBorder)
                .frame(width: 95)
                .disabled(!settings.runAsPostgresUser)
            TextField("Extra psql args", text: $settings.extraArgs)
                .textFieldStyle(.roundedBorder)
            TextField("Filter", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .dashboard:
            logText(dashboard)
        case .sessions:
            sessionsView
        case .locks:
            logText(locks)
        case .query:
            queryRunner
        case .schema:
            schemaBrowser
        case .explain:
            explainPane
        case .slow:
            logText(slowQueries)
        case .replication:
            logText(replication)
        case .vacuum:
            logText(vacuum)
        case .backup:
            backupPane
        }
    }

    private var sessionsView: some View {
        List(selection: $selectedPid) {
            ForEach(filteredSessions) { session in
                HStack(spacing: 8) {
                    monoCell(session.pid, width: 70)
                    monoCell(session.user, width: 90)
                    monoCell(session.state, width: 90, color: statusColor(session.state))
                    monoCell(session.wait, width: 130)
                    monoCell(session.age, width: 90)
                    monoCell(session.query)
                }
                .tag(session.pid)
                .contextMenu {
                    Button("Cancel Query") {
                        pendingBackendAction = BackendAction(function: "pg_cancel_backend", pid: session.pid)
                    }
                    Button("Terminate Backend", role: .destructive) {
                        pendingBackendAction = BackendAction(function: "pg_terminate_backend", pid: session.pid)
                    }
                    Button("Copy Query") { RemoteCommandRunner.copy(session.query) }
                }
            }
        }
        .listStyle(.plain)
    }

    private var filteredSessions: [PGSession] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sessions }
        return sessions.filter {
            $0.pid.contains(needle)
                || $0.user.lowercased().contains(needle)
                || $0.query.lowercased().contains(needle)
                || $0.state.lowercased().contains(needle)
        }
    }

    private var queryRunner: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Button("Run") { Task { await runQuery() } }
                        .keyboardShortcut(.return, modifiers: [.command])
                    Button("Copy Results") { RemoteCommandRunner.copy(resultText(queryResult)) }
                        .disabled(queryResult.rows.isEmpty)
                    Spacer()
                    Text("Timeout and row limit are enforced by the SQL text or server settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                TextEditor(text: $queryText)
                    .font(.system(.caption, design: .monospaced))
            }
            resultTable(queryResult)
                .frame(minHeight: 180)
        }
    }

    private var schemaBrowser: some View {
        HSplitView {
            List(selection: $selectedTableId) {
                ForEach(filteredTables) { table in
                    HStack {
                        monoCell(table.schema, width: 100, color: .secondary)
                        monoCell(table.name, width: 180)
                        monoCell(table.kind, width: 70)
                        monoCell(table.size, width: 80)
                        monoCell(table.estimate)
                    }
                    .tag(table.id)
                }
            }
            .listStyle(.plain)
            .frame(minWidth: 420)
            logText(tableDetail)
                .frame(minWidth: 320)
        }
    }

    private var filteredTables: [PGTableInfo] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return schemaRows }
        return schemaRows.filter {
            $0.schema.lowercased().contains(needle) || $0.name.lowercased().contains(needle)
        }
    }

    private var explainPane: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Button("Explain Analyze") { Task { await runExplain() } }
                    Button("Copy Plan") { RemoteCommandRunner.copy(explainText) }
                        .disabled(explainText.isEmpty)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                TextEditor(text: $queryText)
                    .font(.system(.caption, design: .monospaced))
            }
            logText(explainText)
                .frame(minHeight: 180)
        }
    }

    private var backupPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Backup")
                .font(.headline)
            TextField("Remote dump path", text: $backupPath)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
            HStack {
                Button("Run pg_dump") { Task { await runBackup(download: false) } }
                Button("Run pg_dump and download") { Task { await runBackup(download: true) } }
            }
            Text("Uses pg_dump -Fc on the remote host. Downloads use the existing SFTP transfer queue.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func logText(_ value: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(value.isEmpty ? "-" : value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private func resultTable(_ result: SQLResult) -> some View {
        VStack(spacing: 0) {
            if result.columns.isEmpty {
                placeholderView(icon: "tablecells", title: "No results", message: "Run a query to see rows.")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            ForEach(result.columns, id: \.self) { column in
                                Text(column)
                                    .font(.caption.weight(.semibold).monospaced())
                                    .frame(minWidth: 120, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 5)
                        Divider()
                        ForEach(Array(result.rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 12) {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                    Text(value)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(minWidth: 120, alignment: .leading)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(8)
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
    }

    private func refresh() async {
        switch mode {
        case .dashboard:
            await loadDashboard()
        case .sessions:
            await loadSessions()
        case .locks:
            await loadLocks()
        case .query:
            break
        case .schema:
            await loadSchema()
        case .explain:
            break
        case .slow:
            await loadSlowQueries()
        case .replication:
            await loadReplication()
        case .vacuum:
            await loadVacuum()
        case .backup:
            break
        }
    }

    private func psql(_ sql: String) async throws -> String {
        guard let connectionId else { return "" }
        return try await RemoteCommandRunner.runChecked(
            connectionId: connectionId,
            script: settings.queryScript(sql)
        )
    }

    private func loadDashboard() async {
        loading = true
        defer { loading = false }
        let sql = """
        select 'version', version()
        union all select 'database', current_database()
        union all select 'user', current_user
        union all select 'server', coalesce(inet_server_addr()::text,'local') || ':' || coalesce(inet_server_port()::text,'')
        union all select 'ssl', current_setting('ssl', true)
        union all select 'uptime', (now() - pg_postmaster_start_time())::text
        union all select 'read_only', current_setting('transaction_read_only')
        union all select 'sessions', (select count(*)::text from pg_stat_activity)
        union all select 'active_sessions', (select count(*)::text from pg_stat_activity where state='active')
        union all select 'locks_waiting', (select count(*)::text from pg_locks where not granted)
        union all select 'database_size', pg_size_pretty(pg_database_size(current_database()))
        union all select 'cache_hit_ratio', coalesce(round((100.0 * blks_hit / nullif(blks_hit + blks_read, 0))::numeric, 2)::text, 'n/a') from pg_stat_database where datname=current_database();
        """
        do {
            let output = try await psql(sql)
            dashboard = output.lines().map { line in
                let p = splitFields(line)
                return p.count >= 2 ? "\(p[0]): \(p[1])" : line
            }.joined(separator: "\n")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadSessions() async {
        loading = true
        defer { loading = false }
        let sql = """
        select pid, usename, coalesce(application_name,''), coalesce(client_addr::text,''), coalesce(state,''), coalesce(wait_event_type||':'||wait_event,''), coalesce(now()-query_start, interval '0')::text, left(regexp_replace(query, E'[\\n\\r\\t]+', ' ', 'g'), 500)
        from pg_stat_activity
        order by query_start nulls last
        limit 300;
        """
        do {
            let output = try await psql(sql)
            sessions = output.lines().compactMap { line in
                let p = splitFields(line)
                guard p.count >= 8 else { return nil }
                return PGSession(pid: p[0], user: p[1], app: p[2], client: p[3], state: p[4], wait: p[5], age: p[6], query: p[7])
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadLocks() async {
        loading = true
        defer { loading = false }
        let sql = """
        select 'blocked='||blocked.pid||' blocking='||blocking.pid||' age='||coalesce(now()-blocked.query_start, interval '0')||E'\\nblocked query: '||left(blocked.query,300)||E'\\nblocking query: '||left(blocking.query,300)||E'\\n'
        from pg_catalog.pg_locks blocked_locks
        join pg_catalog.pg_stat_activity blocked on blocked.pid = blocked_locks.pid
        join pg_catalog.pg_locks blocking_locks
          on blocking_locks.locktype = blocked_locks.locktype
         and blocking_locks.database is not distinct from blocked_locks.database
         and blocking_locks.relation is not distinct from blocked_locks.relation
         and blocking_locks.page is not distinct from blocked_locks.page
         and blocking_locks.tuple is not distinct from blocked_locks.tuple
         and blocking_locks.virtualxid is not distinct from blocked_locks.virtualxid
         and blocking_locks.transactionid is not distinct from blocked_locks.transactionid
         and blocking_locks.classid is not distinct from blocked_locks.classid
         and blocking_locks.objid is not distinct from blocked_locks.objid
         and blocking_locks.objsubid is not distinct from blocked_locks.objsubid
         and blocking_locks.pid != blocked_locks.pid
        join pg_catalog.pg_stat_activity blocking on blocking.pid = blocking_locks.pid
        where not blocked_locks.granted and blocking_locks.granted;
        """
        do {
            locks = try await psql(sql)
            if locks.isEmpty { locks = "No blocking locks reported." }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runQuery() async {
        loading = true
        defer { loading = false }
        do {
            let limited = """
            \(queryText)
            """
            let output = try await psql(limited)
            queryResult = parseSQLResult(output)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func parseSQLResult(_ output: String) -> SQLResult {
        let lines = output.lines()
        guard !lines.isEmpty else { return SQLResult(columns: [], rows: []) }
        let rows = lines.map(splitFields)
        let width = rows.map(\.count).max() ?? 0
        let columns = (0..<width).map { "col\($0 + 1)" }
        return SQLResult(columns: columns, rows: rows)
    }

    private func resultText(_ result: SQLResult) -> String {
        ([result.columns.joined(separator: "\t")] + result.rows.map { $0.joined(separator: "\t") }).joined(separator: "\n")
    }

    private func loadSchema() async {
        loading = true
        defer { loading = false }
        let sql = """
        select n.nspname, c.relname, c.relkind::text, pg_size_pretty(pg_total_relation_size(c.oid)), coalesce(c.reltuples::bigint::text,'')
        from pg_class c
        join pg_namespace n on n.oid=c.relnamespace
        where n.nspname not in ('pg_catalog','information_schema') and c.relkind in ('r','p','v','m','f')
        order by n.nspname, c.relname
        limit 1000;
        """
        do {
            let output = try await psql(sql)
            schemaRows = output.lines().compactMap { line in
                let p = splitFields(line)
                guard p.count >= 5 else { return nil }
                return PGTableInfo(schema: p[0], name: p[1], kind: p[2], size: p[3], estimate: p[4])
            }
            if selectedTableId == nil { selectedTableId = schemaRows.first?.id }
            error = nil
            await loadTableDetail()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadTableDetail() async {
        guard let table = schemaRows.first(where: { $0.id == selectedTableId }) else { return }
        let schema = table.schema.replacingOccurrences(of: "'", with: "''")
        let name = table.name.replacingOccurrences(of: "'", with: "''")
        let sql = """
        select 'Columns';
        select column_name||'  '||data_type||'  nullable='||is_nullable||'  default='||coalesce(column_default,'') from information_schema.columns where table_schema='\(schema)' and table_name='\(name)' order by ordinal_position;
        select 'Indexes';
        select indexname||': '||indexdef from pg_indexes where schemaname='\(schema)' and tablename='\(name)';
        select 'Constraints';
        select constraint_name||': '||constraint_type from information_schema.table_constraints where table_schema='\(schema)' and table_name='\(name)';
        """
        do {
            tableDetail = try await psql(sql)
        } catch {
            tableDetail = error.localizedDescription
        }
    }

    private func runExplain() async {
        loading = true
        defer { loading = false }
        do {
            explainText = try await psql("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) \(queryText)")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadSlowQueries() async {
        loading = true
        defer { loading = false }
        let sql = """
        select left(regexp_replace(query, E'[\\n\\r\\t]+', ' ', 'g'), 500)||E'\\n  calls='||calls||' mean_ms='||round(mean_exec_time::numeric,2)||' max_ms='||round(max_exec_time::numeric,2)||' rows='||rows||E'\\n'
        from pg_stat_statements
        order by total_exec_time desc
        limit 40;
        """
        do {
            slowQueries = try await psql(sql)
            if slowQueries.isEmpty { slowQueries = "pg_stat_statements returned no rows." }
            error = nil
        } catch {
            slowQueries = "pg_stat_statements is not available or not granted:\n\(error.localizedDescription)"
            self.error = nil
        }
    }

    private func loadReplication() async {
        loading = true
        defer { loading = false }
        let sql = """
        select 'in_recovery', pg_is_in_recovery()::text;
        select 'replication', coalesce(string_agg(usename||' '||state||' lag='||coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::text,'0'), E'\\n'), 'none') from pg_stat_replication;
        select 'slots', coalesce(string_agg(slot_name||' '||slot_type||' active='||active||' restart='||coalesce(restart_lsn::text,''), E'\\n'), 'none') from pg_replication_slots;
        """
        do {
            replication = try await psql(sql)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadVacuum() async {
        loading = true
        defer { loading = false }
        let sql = """
        select relname||' dead='||n_dead_tup||' live='||n_live_tup||' last_autovacuum='||coalesce(last_autovacuum::text,'never')||' last_autoanalyze='||coalesce(last_autoanalyze::text,'never')
        from pg_stat_user_tables
        order by n_dead_tup desc
        limit 80;
        """
        do {
            vacuum = try await psql(sql)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runBackendAction(_ action: BackendAction) async {
        pendingBackendAction = nil
        do {
            _ = try await psql("select \(action.function)(\(action.pid));")
            await loadSessions()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runBackup(download: Bool) async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        do {
            _ = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: settings.dumpScript(path: backupPath)
            )
            if download {
                let local = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
                    .first?
                    .appendingPathComponent((backupPath as NSString).lastPathComponent)
                    .path ?? (NSHomeDirectory() + "/Downloads/" + (backupPath as NSString).lastPathComponent)
                transfers.enqueueDownload(
                    connectionId: connectionId,
                    remotePath: backupPath,
                    localPath: local,
                    expectedSize: 0
                )
            }
            dashboard = "Backup completed at \(backupPath)"
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension String {
    func lines() -> [String] {
        split(whereSeparator: \.isNewline).map(String.init)
    }

    func section(after start: String, before end: String?) -> String {
        guard let startRange = range(of: start) else { return "" }
        let lower = startRange.upperBound
        let upper: String.Index
        if let end, let endRange = self[lower...].range(of: end) {
            upper = endRange.lowerBound
        } else {
            upper = endIndex
        }
        return String(self[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
