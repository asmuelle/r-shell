import SwiftUI

struct MobileServerDoctorView: View {
    let connectionId: String
    let profileName: String
    let sshPort: UInt16

    @State private var report: MobileDoctorReport?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var inspectedFinding: MobileFinding?
    @State private var exportingReport = false
    @State private var exportDocument = MobileTextDocument()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let report {
                summary(report)
                ForEach(report.sortedFindings.prefix(10)) { finding in
                    MobileFindingCard(finding: finding) { inspectedFinding = $0 }
                }
            } else if !isLoading {
                Text("Run Doctor to check health, firewall exposure, failed services, large files, certificates, and update risk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .sheet(item: $inspectedFinding) { finding in
            MobileRawOutputSheet(
                title: finding.title,
                command: nil,
                output: finding.rawOutput ?? finding.detail
            )
        }
        .fileExporter(
            isPresented: $exportingReport,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "midnight-ssh-incident-\(safeFilename(profileName)).md"
        ) { _ in }
    }

    private var header: some View {
        HStack {
            Label("Server Doctor", systemImage: "stethoscope")
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

            Button {
                exportReport()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(report == nil)
            .accessibilityLabel("Export incident report")
        }
    }

    private func summary(_ report: MobileDoctorReport) -> some View {
        HStack(spacing: 10) {
            summaryCell("Top", report.topSeverity.label, report.topSeverity.color)
            summaryCell("Critical", "\(report.findings.filter { $0.severity == .critical }.count)", .red)
            summaryCell("Warnings", "\(report.findings.filter { $0.severity == .warning }.count)", .orange)
            summaryCell("Checks", "\(report.findings.count)", .secondary)
        }
    }

    private func summaryCell(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        report = await MobileServerDoctorRunner.run(
            connectionId: connectionId,
            hostLabel: profileName,
            sshPort: sshPort
        )
        MobileActivityLogStore.shared.record(
            title: "Server Doctor ran",
            detail: "\(report?.findings.count ?? 0) findings for \(profileName)",
            connectionId: connectionId,
            systemImage: "stethoscope",
            severity: report?.topSeverity == .critical ? .critical : (report?.topSeverity == .warning ? .warning : .ok)
        )
    }

    private func exportReport() {
        guard let report else { return }
        exportDocument = MobileTextDocument(
            text: MobileIncidentReportBuilder.markdown(report: report)
        )
        exportingReport = true
    }

    private func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        return mapped.isEmpty ? "server" : mapped
    }
}
