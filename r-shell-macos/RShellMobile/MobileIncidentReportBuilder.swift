import Foundation

enum MobileIncidentReportBuilder {
    static func markdown(report: MobileDoctorReport) -> String {
        var lines: [String] = []
        lines.append("# midnight-ssh Incident Report")
        lines.append("")
        lines.append("- Server: \(report.hostLabel)")
        lines.append("- Generated: \(ISO8601DateFormatter().string(from: report.generatedAt))")
        lines.append("- Top severity: \(report.topSeverity.label)")
        lines.append("")
        lines.append("## Findings")
        lines.append("")
        for finding in report.sortedFindings {
            lines.append("### [\(finding.severity.label)] \(finding.title)")
            lines.append("")
            lines.append(finding.detail)
            if let action = finding.actionLabel {
                lines.append("")
                lines.append("Suggested action: \(action)")
            }
            lines.append("")
        }
        lines.append("## Raw Sections")
        lines.append("")
        for section in report.rawSections {
            lines.append("### \(section.title)")
            lines.append("")
            lines.append("```text")
            lines.append(MobileDiagnosticsRedactor.redactSecrets(section.output))
            lines.append("```")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func mobileDiagnosticsSummary(
        profiles: [MobileConnectionProfile],
        sessions: [MobileSessionDiagnostics]
    ) -> String {
        """
        # midnight-ssh Mobile Fleet Summary

        Saved hosts: \(profiles.count)
        Connected sessions: \(sessions.filter { $0.status == "connected" }.count)
        Failed sessions: \(sessions.filter { $0.status == "failed" }.count)
        Public-key profiles: \(profiles.filter { $0.authMethod == .publicKey }.count)
        Password profiles: \(profiles.filter { $0.authMethod == .password }.count)

        Generated at: \(ISO8601DateFormatter().string(from: Date()))
        """
    }
}
