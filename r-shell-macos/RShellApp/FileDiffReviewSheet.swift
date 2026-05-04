import SwiftUI

struct FileDiffReviewSheet: View {
    let path: String
    let original: String
    let revised: String
    let isSaving: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var summary: DiffSummary {
        DiffSummary(original: original, revised: revised)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review Changes")
                        .font(.headline)
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(14)

            Divider()

            HStack(spacing: 10) {
                stat("Added", summary.added, .green)
                stat("Removed", summary.removed, .red)
                stat("Changed", summary.changed, .orange)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            HSplitView {
                diffColumn("Before", text: original)
                diffColumn("After", text: revised)
            }
            .frame(minHeight: 360)

            Divider()

            HStack {
                Text("A backup is created for config-like files before upload. Validators run for known formats.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .disabled(isSaving)
                Button("Save Changes", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
            .padding(14)
        }
        .frame(minWidth: 700, idealWidth: 900, minHeight: 480, idealHeight: 620)
    }

    private func stat(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(width: 84, alignment: .leading)
    }

    private func diffColumn(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct DiffSummary {
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
