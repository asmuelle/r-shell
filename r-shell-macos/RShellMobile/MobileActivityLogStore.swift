import SwiftUI

struct MobileActivityEvent: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let profileId: String?
    let connectionId: String?
    let title: String
    let detail: String
    let systemImage: String
    let severity: MobileFindingSeverity
}

@MainActor
final class MobileActivityLogStore: ObservableObject {
    static let shared = MobileActivityLogStore()

    @Published private(set) var events: [MobileActivityEvent] = []

    private let maxEvents = 200

    private init() {}

    func record(
        title: String,
        detail: String,
        profileId: String? = nil,
        connectionId: String? = nil,
        systemImage: String = "circle",
        severity: MobileFindingSeverity = .info
    ) {
        events.insert(
            MobileActivityEvent(
                date: Date(),
                profileId: profileId,
                connectionId: connectionId,
                title: title,
                detail: detail,
                systemImage: systemImage,
                severity: severity
            ),
            at: 0
        )
        if events.count > maxEvents {
            events.removeLast(events.count - maxEvents)
        }
    }

    func recent(profileId: String?, connectionId: String?, limit: Int = 8) -> [MobileActivityEvent] {
        events
            .filter { event in
                if let profileId, event.profileId == profileId { return true }
                if let connectionId, event.connectionId == connectionId { return true }
                return profileId == nil && connectionId == nil
            }
            .prefix(limit)
            .map { $0 }
    }

    func recentProblems(limit: Int = 6) -> [MobileActivityEvent] {
        events
            .filter { $0.severity == .warning || $0.severity == .critical }
            .prefix(limit)
            .map { $0 }
    }
}

struct MobileActivityTimelineView: View {
    @ObservedObject private var store = MobileActivityLogStore.shared

    let profileId: String?
    let connectionId: String?
    var maxEvents = 8

    private var events: [MobileActivityEvent] {
        store.recent(profileId: profileId, connectionId: connectionId, limit: maxEvents)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Activity", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            if events.isEmpty {
                Text("No activity recorded for this server in this app session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
                    ForEach(events, id: \.id) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: event.systemImage)
                                .foregroundStyle(event.severity.color)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(event.title)
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text(event.date, style: .time)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                Text(event.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(10)
                        if let last = events.last, event.id != last.id {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
