import SwiftUI

struct MobileDiskAnalyzerView: View {
    let connectionId: String

    @State private var entries: [MobileDiskEntry] = []
    @State private var currentPath = "/"
    @State private var navigationStack: [String] = ["/"]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var lastUpdated: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            pathBreadcrumb

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            if isLoading {
                ProgressView("Scanning \(currentPath)...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }

            if entries.isEmpty, !isLoading {
                Text("Tap refresh to scan disk usage at \(currentPath).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(sortedEntries) { entry in
                    diskEntryRow(entry)
                }
            }
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack {
            Label("Disk Analyzer", systemImage: "externaldrive")
                .font(.headline)
            Spacer()
            if let lastUpdated {
                Text(lastUpdated, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await scan() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
            .accessibilityLabel("Refresh disk analyzer")
        }
    }

    private var pathBreadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(navigationStack.indices, id: \.self) { index in
                    Button {
                        navigateTo(index: index)
                    } label: {
                        Text(displayPathComponent(at: index))
                            .font(.caption.monospaced())
                            .foregroundStyle(index == navigationStack.count - 1 ? Color.primary : Color.blue)
                    }
                    .buttonStyle(.borderless)

                    if index < navigationStack.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var sortedEntries: [MobileDiskEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.sizeBytes > rhs.sizeBytes
        }
    }

    @ViewBuilder
    private func diskEntryRow(_ entry: MobileDiskEntry) -> some View {
        Button {
            if entry.isDirectory {
                navigateInto(entry.path)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Text(entry.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(entry.sizeFormatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(entry.sizePercent > 80 ? .red : entry.sizePercent > 50 ? .orange : .secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func navigateInto(_ path: String) {
        navigationStack.append(path)
        currentPath = path
        Task { await scan() }
    }

    private func navigateTo(index: Int) {
        let target = navigationStack[index]
        navigationStack = Array(navigationStack.prefix(index + 1))
        currentPath = target
        Task { await scan() }
    }

    private func displayPathComponent(at index: Int) -> String {
        let path = navigationStack[index]
        if index == 0 && path == "/" { return "/" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    @MainActor
    private func scan() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let script = """
            find \(shellQuote(currentPath)) -maxdepth 1 -mindepth 1 2>/dev/null | while IFS= read -r item; do
              if [ -d "$item" ]; then
                size=$(du -sk "$item" 2>/dev/null | cut -f1)
                echo "D\\t$item\\t${size:-0}"
              else
                size=$(stat -f%z "$item" 2>/dev/null || stat -c%s "$item" 2>/dev/null || echo 0)
                echo "F\\t$item\\t${size:-0}"
              fi
            done
            """
            let output = try await MobileMonitorBridge.shared.executeCommand(
                connectionId: connectionId,
                command: script
            )
            entries = parseDiskEntries(output)
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func parseDiskEntries(_ output: String) -> [MobileDiskEntry] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = String(line).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 3 else { return nil }
                let isDir = parts[0] == "D"
                let path = parts[1]
                let kb = Double(parts[2]) ?? 0
                let name = URL(fileURLWithPath: path).lastPathComponent
                let bytes = UInt64(kb * 1024)
                let totalKB = entriesTotalKB
                let percent = totalKB > 0 ? (kb / totalKB * 100) : 0
                return MobileDiskEntry(
                    name: name,
                    path: path,
                    isDirectory: isDir,
                    sizeBytes: bytes,
                    sizePercent: min(percent, 100)
                )
            }
    }

    private var entriesTotalKB: Double {
        entries.reduce(0) { acc, entry in
            acc + Double(entry.sizeBytes) / 1024
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

private struct MobileDiskEntry: Identifiable {
    let name: String
    let path: String
    let isDirectory: Bool
    let sizeBytes: UInt64
    let sizePercent: Double

    var id: String { path }

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}
