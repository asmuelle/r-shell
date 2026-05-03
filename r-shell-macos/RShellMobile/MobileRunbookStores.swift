import Foundation

struct MobileSavedRunbook: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var command: String
    var risk: MobileTaskRisk
    var createdAt = Date()
}

struct MobileRunbookHistoryEvent: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var command: String
    var exitCode: Int32
    var outputPreview: String
    var startedAt: Date
    var durationSeconds: Double
}

@MainActor
final class MobileSavedRunbooksStore: ObservableObject {
    static let shared = MobileSavedRunbooksStore()

    @Published private(set) var runbooks: [MobileSavedRunbook] = []

    private let key = "midnightSSH.mobileSavedRunbooks.v1"

    private init() {
        load()
    }

    func add(title: String, command: String, risk: MobileTaskRisk) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanCommand.isEmpty else { return }
        runbooks.insert(MobileSavedRunbook(title: cleanTitle, command: cleanCommand, risk: risk), at: 0)
        save()
    }

    func delete(_ runbook: MobileSavedRunbook) {
        runbooks.removeAll { $0.id == runbook.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([MobileSavedRunbook].self, from: data)
        else { return }
        runbooks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(runbooks) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

@MainActor
final class MobileRunbookHistoryStore: ObservableObject {
    static let shared = MobileRunbookHistoryStore()

    @Published private(set) var events: [MobileRunbookHistoryEvent] = []

    private let key = "midnightSSH.mobileRunbookHistory.v1"
    private let limit = 80

    private init() {
        load()
    }

    func record(_ result: MobileRemoteTaskResult) {
        let preview = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(4)
            .joined(separator: "\n")

        events.insert(
            MobileRunbookHistoryEvent(
                title: result.title,
                command: result.command,
                exitCode: result.exitCode,
                outputPreview: preview.isEmpty ? "(no output)" : preview,
                startedAt: result.startedAt,
                durationSeconds: result.durationSeconds
            ),
            at: 0
        )
        if events.count > limit {
            events.removeLast(events.count - limit)
        }
        save()
    }

    func clear() {
        events.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([MobileRunbookHistoryEvent].self, from: data)
        else { return }
        events = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
