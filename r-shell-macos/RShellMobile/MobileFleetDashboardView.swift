import SwiftUI

struct MobileFleetDashboardView: View {
    let profiles: [MobileConnectionProfile]

    @EnvironmentObject private var sessionStore: MobileSessionStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var activityLog = MobileActivityLogStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    problemSummary

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
                        ForEach(sortedProfiles) { profile in
                            fleetTile(profile)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Fleet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var problemSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs Attention", systemImage: "exclamationmark.triangle")
                .font(.headline)

            let failed = profiles.filter {
                if case .failed = sessionStore.status(for: $0) { return true }
                return false
            }
            let events = activityLog.recentProblems(limit: 5)

            if failed.isEmpty && events.isEmpty {
                Label("No active problems recorded in this app session.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(failed, id: \.id) { profile in
                    problemRow(
                        title: profile.name,
                        detail: sessionStore.status(for: profile).failureMessage ?? "Connection failed",
                        systemImage: "wifi.slash",
                        color: .red
                    )
                }
                ForEach(events, id: \.id) { event in
                    problemRow(
                        title: event.title,
                        detail: event.detail,
                        systemImage: event.systemImage,
                        color: event.severity.color
                    )
                }
            }
        }
    }

    private func problemRow(
        title: String,
        detail: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sortedProfiles: [MobileConnectionProfile] {
        profiles.sorted { lhs, rhs in
            let lhsRank = rank(sessionStore.status(for: lhs))
            let rhsRank = rank(sessionStore.status(for: rhs))
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func fleetTile(_ profile: MobileConnectionProfile) -> some View {
        let status = sessionStore.status(for: profile)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(color(status))
                    .frame(width: 10, height: 10)
                Text(profile.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if profile.favorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }

            Text("\(profile.username)@\(profile.host):\(profile.port)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(status.failureMessage ?? status.label)
                .font(.caption)
                .foregroundStyle(status.failureMessage == nil ? Color.secondary : Color.red)
                .lineLimit(3)

            HStack {
                Label(profile.kind.displayName, systemImage: profile.kind.supportsTerminal ? "terminal" : "folder")
                Spacer()
                Label(profile.authMethod.displayName, systemImage: profile.authMethod == .publicKey ? "key" : "lock")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func rank(_ status: MobileSessionStatus) -> Int {
        switch status {
        case .failed: return 0
        case .connecting: return 1
        case .connected: return 2
        case .disconnected: return 3
        }
    }

    private func color(_ status: MobileSessionStatus) -> Color {
        switch status {
        case .failed: return .red
        case .connecting: return .orange
        case .connected: return .green
        case .disconnected: return .secondary
        }
    }
}
