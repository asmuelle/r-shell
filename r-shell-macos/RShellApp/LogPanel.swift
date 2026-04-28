import SwiftUI
import RShellMacOS

/// Log viewer with source selector, tail, search, and export.
struct LogPanel: View {
    let connectionId: String
    @StateObject private var poller = MonitorPollingManager.shared
    @State private var logSources: [LogSource] = []
    @State private var selectedSource: LogSource?
    @State private var searchQuery = ""
    @State private var lineCount: Int = 50
    @State private var isLiveTail = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Picker("Source", selection: $selectedSource) {
                    Text("Select a log source").tag(nil as LogSource?)
                    ForEach(logSources) { source in
                        Text(source.name).tag(source as LogSource?)
                    }
                }
                .frame(width: 220)

                TextField("Search…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 160)
                    .onSubmit { performSearch() }

                Stepper(value: $lineCount, in: 10...500, step: 10) {
                    Text("\(lineCount) lines")
                        .font(.caption)
                        .frame(width: 60)
                }
                .controlSize(.small)

                Toggle("Live", isOn: $isLiveTail)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Auto-refresh every 3s")

                Spacer()

                Button("Refresh") { tailLog() }
                    .font(.caption)
                    .disabled(selectedSource == nil)

                Button("Export…") { exportLog() }
                    .font(.caption)
                    .disabled(poller.logEntries.isEmpty)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Log entries
            if poller.logEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("Select a log source and refresh")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                listContent
            }
        }
        .onAppear { discoverSources() }
        .onChange(of: isLiveTail) { live in
            if live { startLiveTail() } else { stopLiveTail() }
        }
        .onChange(of: selectedSource?.id) { _ in tailLog() }
    }

    // MARK: - Log list

    private var listContent: some View {
        ScrollViewReader { scroll in
            List(Array(poller.logEntries.enumerated()), id: \.element.id) { _, entry in
                HStack(spacing: 6) {
                    if let ts = entry.timestamp {
                        Text(ts)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 120, alignment: .leading)
                    }

                    if let level = entry.level {
                        Text(level)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(levelColor(level))
                            .frame(width: 40)
                    }

                    Text(entry.message)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(3)
                }
            }
            .listStyle(.plain)
            .onChange(of: poller.logEntries.count) { _ in
                if let last = poller.logEntries.last {
                    scroll.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Actions

    private func discoverSources() {
        // Once FFI: rshell_execute_command(connectionId: connectionId, command: discoverScript)
        logSources = [
            LogSource(name: "syslog", path: "/var/log/system.log"),
            LogSource(name: "auth", path: "/var/log/auth.log"),
        ]
    }

    private func tailLog() {
        guard let source = selectedSource else { return }
        poller.tailLog(connectionId: connectionId, path: source.path, lines: lineCount)
    }

    private func performSearch() {
        guard let source = selectedSource, !searchQuery.isEmpty else { return }
        poller.searchLog(connectionId: connectionId, path: source.path, query: searchQuery)
    }

    private func startLiveTail() {
        isLiveTail = true
        tailLog()
    }

    private func stopLiveTail() {
        isLiveTail = false
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(selectedSource?.name ?? "log").txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let text = poller.logEntries.map { $0.raw }.joined(separator: "\n")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func levelColor(_ level: String) -> Color {
        switch level.uppercased() {
        case "ERR", "ERROR", "CRIT": return .red
        case "WARN", "WARNING": return .orange
        case "INFO": return .primary
        case "DEBUG", "TRACE": return .secondary
        default: return .primary
        }
    }
}
