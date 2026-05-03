import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum MobileTaskRisk: String, Codable, Sendable {
    case readOnly
    case mutating
    case dangerous

    var label: String {
        switch self {
        case .readOnly: return "Read-only"
        case .mutating: return "Changes server"
        case .dangerous: return "Dangerous"
        }
    }
}

enum MobileFindingSeverity: String, Codable, CaseIterable, Sendable {
    case ok
    case info
    case warning
    case critical
    case unknown

    var label: String {
        switch self {
        case .ok: return "OK"
        case .info: return "Info"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    var rank: Int {
        switch self {
        case .critical: return 0
        case .warning: return 1
        case .unknown: return 2
        case .info: return 3
        case .ok: return 4
        }
    }
}

struct MobileRemoteTaskResult: Identifiable, Codable, Sendable {
    let id: UUID
    let title: String
    let command: String
    let risk: MobileTaskRisk
    let exitCode: Int32
    let output: String
    let startedAt: Date
    let durationSeconds: Double

    var succeeded: Bool { exitCode == 0 }

    init(
        id: UUID = UUID(),
        title: String,
        command: String,
        risk: MobileTaskRisk,
        exitCode: Int32,
        output: String,
        startedAt: Date,
        durationSeconds: Double
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.risk = risk
        self.exitCode = exitCode
        self.output = output
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
    }
}

struct MobileFinding: Identifiable, Codable, Sendable {
    let id: UUID
    let title: String
    let detail: String
    let severity: MobileFindingSeverity
    let category: String
    let actionLabel: String?
    let rawOutput: String?

    init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        severity: MobileFindingSeverity,
        category: String,
        actionLabel: String? = nil,
        rawOutput: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.severity = severity
        self.category = category
        self.actionLabel = actionLabel
        self.rawOutput = rawOutput
    }
}

struct MobileDoctorReport: Identifiable, Codable, Sendable {
    let id: UUID
    let generatedAt: Date
    let hostLabel: String
    let findings: [MobileFinding]
    let rawSections: [MobileDoctorRawSection]

    init(
        id: UUID = UUID(),
        generatedAt: Date = Date(),
        hostLabel: String,
        findings: [MobileFinding],
        rawSections: [MobileDoctorRawSection]
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.hostLabel = hostLabel
        self.findings = findings
        self.rawSections = rawSections
    }

    var sortedFindings: [MobileFinding] {
        findings.sorted { lhs, rhs in
            if lhs.severity.rank != rhs.severity.rank {
                return lhs.severity.rank < rhs.severity.rank
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    var topSeverity: MobileFindingSeverity {
        sortedFindings.first?.severity ?? .unknown
    }
}

struct MobileDoctorRawSection: Identifiable, Codable, Sendable {
    let id: UUID
    let title: String
    let output: String

    init(id: UUID = UUID(), title: String, output: String) {
        self.id = id
        self.title = title
        self.output = output
    }
}

struct MobileTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            text = ""
            return
        }
        text = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct MobileSeverityBadge: View {
    let severity: MobileFindingSeverity

    var body: some View {
        Text(severity.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(severity.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(severity.color.opacity(0.12), in: Capsule())
    }
}

struct MobileFindingCard: View {
    let finding: MobileFinding
    var onInspect: ((MobileFinding) -> Void)?

    var body: some View {
        Button {
            onInspect?(finding)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(finding.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer()
                    MobileSeverityBadge(severity: finding.severity)
                }

                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)

                if let actionLabel = finding.actionLabel {
                    Label(actionLabel, systemImage: "arrow.right.circle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(onInspect == nil)
    }
}

struct MobileRawOutputSheet: View {
    let title: String
    let command: String?
    let output: String

    @Environment(\.dismiss) private var dismiss
    @State private var showRaw = false

    private var sections: [MobileOutputSection] {
        MobileOutputSection.parse(output)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    overview

                    if let command {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Command", systemImage: "terminal")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(command)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }

                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))
                            Text(section.preview)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }

                    DisclosureGroup("Raw Output", isExpanded: $showRaw) {
                        Text(output.isEmpty ? "(no output)" : output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy") {
                        UIPasteboard.general.string = output
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var overview: some View {
        HStack(spacing: 10) {
            overviewCell("Sections", "\(sections.count)", Color.blue)
            overviewCell("Lines", "\(output.split(whereSeparator: \.isNewline).count)", Color.secondary)
            overviewCell("Raw", showRaw ? "Shown" : "Hidden", showRaw ? Color.orange : Color.green)
        }
    }

    private func overviewCell(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MobileOutputSection: Identifiable {
    let id = UUID()
    let title: String
    let lines: [String]

    var preview: String {
        let text = lines
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(18)
            .joined(separator: "\n")
        return text.isEmpty ? "(no details)" : text
    }

    static func parse(_ output: String) -> [MobileOutputSection] {
        let lines = output.components(separatedBy: .newlines)
        guard !lines.isEmpty else {
            return [MobileOutputSection(title: "Output", lines: [])]
        }

        var sections: [MobileOutputSection] = []
        var currentTitle = "Summary"
        var currentLines: [String] = []

        func flush() {
            let trimmed = currentLines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !trimmed.isEmpty {
                sections.append(MobileOutputSection(title: currentTitle, lines: currentLines))
            }
            currentLines = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isHeading(trimmed), !currentLines.isEmpty {
                flush()
                currentTitle = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            } else {
                currentLines.append(line)
            }
        }
        flush()

        return sections.isEmpty ? [MobileOutputSection(title: "Output", lines: lines)] : sections
    }

    private static func isHeading(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 64 else { return false }
        if line.hasSuffix(":") { return true }
        if line.hasPrefix("__MIDNIGHT_SERVICE__") { return true }
        return line.allSatisfy { $0.isUppercase || $0.isWhitespace || $0 == "-" }
    }
}

struct MobileFileDiffReviewSheet: View {
    let path: String
    let original: String
    let revised: String
    let isSaving: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var summary: MobileDiffSummary {
        MobileDiffSummary(original: original, revised: revised)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    diffStat("Added", summary.added, Color.green)
                    diffStat("Removed", summary.removed, Color.red)
                    diffStat("Changed", summary.changed, Color.orange)
                }
                .padding()

                TabView {
                    ScrollView([.vertical, .horizontal]) {
                        Text(original.isEmpty ? "(empty)" : original)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .tabItem { Label("Before", systemImage: "minus") }

                    ScrollView([.vertical, .horizontal]) {
                        Text(revised.isEmpty ? "(empty)" : revised)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .tabItem { Label("After", systemImage: "plus") }
                }
            }
            .navigationTitle("Review Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onConfirm)
                        .disabled(isSaving)
                }
            }
        }
    }

    private func diffStat(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MobileDiffSummary {
    let added: Int
    let removed: Int
    let changed: Int

    init(original: String, revised: String) {
        let oldLines = original.components(separatedBy: .newlines)
        let newLines = revised.components(separatedBy: .newlines)
        let maxCount = max(oldLines.count, newLines.count)
        var added = 0
        var removed = 0
        var changed = 0

        for index in 0..<maxCount {
            let old = index < oldLines.count ? oldLines[index] : nil
            let new = index < newLines.count ? newLines[index] : nil
            switch (old, new) {
            case (nil, .some(_)):
                added += 1
            case (.some(_), nil):
                removed += 1
            case let (.some(lhs), .some(rhs)) where lhs != rhs:
                changed += 1
            default:
                break
            }
        }

        self.added = added
        self.removed = removed
        self.changed = changed
    }
}

enum MobileRemoteTaskError: LocalizedError {
    case missingExitMarker(String)

    var errorDescription: String? {
        switch self {
        case .missingExitMarker(let title):
            return "\(title) did not return a parseable exit marker."
        }
    }
}
