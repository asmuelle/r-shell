import SwiftUI

struct MobilePackageUpdatesView: View {
    let connectionId: String

    @State private var updates: [MobilePackageUpdate] = []
    @State private var securityCount = 0
    @State private var lastUpdateTimestamp: String?
    @State private var osRelease: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var lastUpdated: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            if let osRelease {
                Text(osRelease)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }

            HStack(spacing: 10) {
                summaryCard("Pending", "\(updates.count)", .secondary)
                summaryCard("Security", "\(securityCount)", securityCount > 0 ? .red : .green)
                if let timestamp = lastUpdateTimestamp {
                    summaryCard("Last Updated", timestamp, .secondary)
                }
            }

            if updates.isEmpty, !isLoading {
                Text("System is up to date or package manager unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(updates.prefix(15)) { update in
                    HStack(spacing: 8) {
                        Image(systemName: update.isSecurity ? "lock.shield.fill" : "shippingbox")
                            .foregroundStyle(update.isSecurity ? .red : .blue)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(update.packageName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text("\(update.currentVersion) → \(update.newVersion)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                }

                if updates.count > 15 {
                    Text("+ \(updates.count - 15) more updates")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: connectionId) {
            await refresh()
        }
    }

    private var header: some View {
        HStack {
            Label("Package Updates", systemImage: "shippingbox")
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
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
        }
    }

    private func summaryCard(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let osInfo = loadOSInfo()
            async let pkgUpdates = loadUpdates()

            osRelease = try? await osInfo
            let (pkgs, security, timestamp) = try await pkgUpdates
            updates = pkgs
            securityCount = security
            lastUpdateTimestamp = timestamp
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadOSInfo() async throws -> String {
        let script = """
        if [ -r /etc/os-release ]; then
          . /etc/os-release && echo "$PRETTY_NAME"
        else
          uname -a 2>/dev/null | head -1
        fi
        """
        return (try? await MobileMonitorBridge.shared.executeCommand(
            connectionId: connectionId,
            command: script
        )) ?? ""
    }

    private func loadUpdates() async throws -> ([MobilePackageUpdate], Int, String?) {
        let script = """
        if command -v apt >/dev/null 2>&1; then
          echo "__PKG_MGR__apt__"
          apt list --upgradable 2>/dev/null | tail -n +2
          echo "===LAST==="
          grep " install " /var/log/dpkg.log 2>/dev/null | tail -1 | awk '{print $1, $2}' || true
        elif command -v dnf >/dev/null 2>&1; then
          echo "__PKG_MGR__dnf__"
          dnf check-update 2>&1 | tail -n +3
          echo "===LAST==="
          dnf history info last 2>/dev/null | grep -i 'begin time' | head -1 || true
        elif command -v yum >/dev/null 2>&1; then
          echo "__PKG_MGR__yum__"
          yum check-update 2>&1 | tail -n +3
          echo "===LAST==="
          yum history info last 2>/dev/null | grep -i 'begin time' | head -1 || true
        else
          echo "__PKG_MGR__none__"
        fi
        """

        let output = try await MobileMonitorBridge.shared.executeCommand(
            connectionId: connectionId,
            command: script
        )

        let sections = output.split(separator: "===LAST===")
        let updatesSection = sections.first.map(String.init) ?? output
        let lastSection = sections.count > 1 ? String(sections[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        var packages: [MobilePackageUpdate] = []
        var security = 0

        let lines = updatesSection
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        let isApt = updatesSection.contains("__PKG_MGR__apt__")
        let isDnf = updatesSection.contains("__PKG_MGR__dnf__") || updatesSection.contains("__PKG_MGR__yum__")

        for line in lines {
            guard !line.hasPrefix("__PKG_MGR__") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("Listing"), !trimmed.hasPrefix("Last metadata") else { continue }

            if isApt {
                let parts = trimmed.split(separator: " ").map(String.init)
                guard parts.count >= 2 else { continue }
                let name = parts[0].split(separator: "/").first.map(String.init) ?? parts[0]
                let current = parts.count >= 4 ? String(parts[4].dropLast()) : "?"
                let new = parts.count >= 2 ? parts[1] : "?"
                let isSecurity = trimmed.lowercased().contains("security") || trimmed.lowercased().contains("-security")
                packages.append(MobilePackageUpdate(
                    packageName: name,
                    currentVersion: current,
                    newVersion: new,
                    isSecurity: isSecurity
                ))
                if isSecurity { security += 1 }
            } else if isDnf {
                let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 3 else { continue }
                let name = parts[0]
                let new = parts[1]
                let isSecurity = trimmed.lowercased().contains("security")
                packages.append(MobilePackageUpdate(
                    packageName: name,
                    currentVersion: parts.count >= 3 ? parts[2] : "installed",
                    newVersion: new,
                    isSecurity: isSecurity
                ))
                if isSecurity { security += 1 }
            }
        }

        return (packages, security, lastSection.isEmpty ? nil : lastSection)
    }
}

private struct MobilePackageUpdate: Identifiable {
    let id = UUID()
    let packageName: String
    let currentVersion: String
    let newVersion: String
    let isSecurity: Bool
}