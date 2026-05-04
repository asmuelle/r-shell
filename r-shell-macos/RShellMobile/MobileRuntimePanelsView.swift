import SwiftUI

struct MobileRuntimePanelsView: View {
    let connectionId: String

    @State private var mode = Mode.docker
    @State private var dockerSnapshot = MobileDockerSnapshot.empty
    @State private var postgresSnapshot = MobilePostgresSnapshot.empty
    @State private var search = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var lastUpdated: Date?

    private enum Mode: String, CaseIterable, Identifiable {
        case docker = "Docker"
        case postgres = "PostgreSQL"

        var id: String { rawValue }
    }

    @State private var dockerActionResult: MobileDockerActionResult?
    @State private var dockerActionInProgress: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            TextField("Filter", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            switch mode {
            case .docker:
                dockerPane
            case .postgres:
                postgresPane
            }
        }
        .task(id: connectionId) {
            await refresh()
        }
        .onChange(of: mode) { _ in
            search = ""
            Task { await refresh() }
        }
        .sheet(item: $dockerActionResult) { result in
            MobileDockerActionResultSheet(result: result)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Runtime", systemImage: "server.rack")
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
                .accessibilityLabel("Refresh runtime panels")
            }

            Picker("Runtime", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
        }
    }

    private var dockerPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                summaryCell("Containers", "\(dockerSnapshot.containers.count)", .secondary)
                summaryCell("Running", "\(dockerSnapshot.runningCount)", .green)
                summaryCell("Exited", "\(dockerSnapshot.exitedCount)", .orange)
            }

            if let serverVersion = dockerSnapshot.serverVersion, !serverVersion.isEmpty {
                Text("Docker Engine \(serverVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if dockerSnapshot.containers.isEmpty {
                emptyPanel("No Docker containers found.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Containers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(filteredContainers.prefix(12)) { container in
                        dockerContainerRow(container)
                    }
                }
            }

            if !dockerSnapshot.images.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Images")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(filteredImages.prefix(6)) { image in
                        HStack(spacing: 8) {
                            Image(systemName: "shippingbox")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(image.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(image.size) - \(image.created)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private var postgresPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                summaryCell("Sessions", postgresSnapshot.connectionUsage?.activeText ?? "-", .green)
                summaryCell("Max", postgresSnapshot.connectionUsage?.maxText ?? "-", .secondary)
                summaryCell("Waiting Locks", postgresSnapshot.waitingLocksText, postgresSnapshot.waitingLocks == 0 ? .green : .orange)
            }

            if let meta = postgresSnapshot.meta {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meta.version)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text("\(meta.database) as \(meta.user)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !postgresSnapshot.activity.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Activity")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(postgresSnapshot.activity) { row in
                        HStack {
                            Text(row.state)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text("\(row.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if postgresSnapshot.databases.isEmpty {
                emptyPanel("No PostgreSQL database sample available.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Databases")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(filteredDatabases.prefix(8)) { database in
                        HStack(spacing: 8) {
                            Image(systemName: "cylinder.split.1x2")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(database.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(database.size) - \(database.connections) sessions")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private func dockerContainerRow(_ container: MobileDockerContainer) -> some View {
        Button {
            Task { await performDockerAction(.logs, on: container) }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(containerStatusColor(container))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(container.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(container.image)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let stats = container.stats {
                        Text("\(stats.cpu) CPU - \(stats.memory)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if dockerActionInProgress == container.id {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(container.state)
                    .font(.caption2.monospaced())
                    .foregroundStyle(containerStatusColor(container))
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if container.state == "running" {
                Button { Task { await performDockerAction(.stop, on: container) } } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                Button { Task { await performDockerAction(.restart, on: container) } } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
            } else {
                Button { Task { await performDockerAction(.start, on: container) } } label: {
                    Label("Start", systemImage: "play.circle")
                }
            }
            Button { Task { await performDockerAction(.logs, on: container) } } label: {
                Label("View Logs", systemImage: "doc.text.magnifyingglass")
            }
            Button { Task { await performDockerAction(.inspect, on: container) } } label: {
                Label("Inspect", systemImage: "info.circle")
            }
            Button { Task { await performDockerAction(.exec, on: container) } } label: {
                Label("Shell Command", systemImage: "terminal")
            }
        }
        .swipeActions(edge: .trailing) {
            if container.state == "running" {
                Button("Stop", systemImage: "stop.circle") {
                    Task { await performDockerAction(.stop, on: container) }
                }
                .tint(.red)
                Button("Restart", systemImage: "arrow.clockwise") {
                    Task { await performDockerAction(.restart, on: container) }
                }
                .tint(.orange)
            } else if container.state == "exited" || container.state == "dead" {
                Button("Start", systemImage: "play.circle") {
                    Task { await performDockerAction(.start, on: container) }
                }
                .tint(.green)
            }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func emptyPanel(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var filteredContainers: [MobileDockerContainer] {
        let needle = normalizedSearch
        guard !needle.isEmpty else { return dockerSnapshot.containers }
        return dockerSnapshot.containers.filter {
            $0.name.lowercased().contains(needle)
                || $0.image.lowercased().contains(needle)
                || $0.state.lowercased().contains(needle)
                || $0.status.lowercased().contains(needle)
        }
    }

    private var filteredImages: [MobileDockerImage] {
        let needle = normalizedSearch
        guard !needle.isEmpty else { return dockerSnapshot.images }
        return dockerSnapshot.images.filter {
            $0.name.lowercased().contains(needle)
                || $0.size.lowercased().contains(needle)
                || $0.created.lowercased().contains(needle)
        }
    }

    private var filteredDatabases: [MobilePostgresDatabase] {
        let needle = normalizedSearch
        guard !needle.isEmpty else { return postgresSnapshot.databases }
        return postgresSnapshot.databases.filter {
            $0.name.lowercased().contains(needle)
                || $0.size.lowercased().contains(needle)
        }
    }

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        errorMessage = nil

        do {
            switch mode {
            case .docker:
                dockerSnapshot = try await loadDocker()
            case .postgres:
                postgresSnapshot = try await loadPostgres()
            }
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func loadDocker() async throws -> MobileDockerSnapshot {
        let script = """
        command -v docker >/dev/null 2>&1 || { echo __MIDNIGHT_SSH_DOCKER_UNAVAILABLE__; exit 0; }
        echo __MIDNIGHT_SSH_DOCKER_VERSION__
        docker version --format '{{.Server.Version}}' 2>&1 || true
        echo __MIDNIGHT_SSH_DOCKER_CONTAINERS__
        docker ps -a --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.State}}\\t{{.Status}}\\t{{.Ports}}' 2>&1 || true
        echo __MIDNIGHT_SSH_DOCKER_STATS__
        docker stats --no-stream --format '{{.Container}}\\t{{.CPUPerc}}\\t{{.MemUsage}}\\t{{.NetIO}}' 2>/dev/null || true
        echo __MIDNIGHT_SSH_DOCKER_IMAGES__
        docker images --format '{{.Repository}}:{{.Tag}}\\t{{.ID}}\\t{{.Size}}\\t{{.CreatedSince}}' 2>&1 | head -n 12 || true
        """
        let output = try await MobileMonitorBridge.shared.executeCommand(
            connectionId: connectionId,
            command: script
        )
        if output.contains("__MIDNIGHT_SSH_DOCKER_UNAVAILABLE__") {
            throw MobileRuntimeError.unavailable("Docker is not installed on this host.")
        }
        return MobileDockerSnapshot.parse(output)
    }

    private func loadPostgres() async throws -> MobilePostgresSnapshot {
        let script = """
        command -v psql >/dev/null 2>&1 || { echo __MIDNIGHT_SSH_POSTGRES_UNAVAILABLE__; exit 0; }
        query_psql() {
          sql="$1"
          out=$(psql -Atq -d postgres -c "$sql" 2>&1)
          rc=$?
          if [ "$rc" -eq 0 ]; then
            printf '%s\\n' "$out"
            return 0
          fi
          if command -v sudo >/dev/null 2>&1; then
            out=$(sudo -n -u postgres psql -Atq -d postgres -c "$sql" 2>&1)
            rc=$?
            if [ "$rc" -eq 0 ]; then
              printf '%s\\n' "$out"
              return 0
            fi
          fi
          printf '%s\\n' "$out"
          return "$rc"
        }
        echo __MIDNIGHT_SSH_POSTGRES_META__
        query_psql "select current_database()||E'\\t'||current_user||E'\\t'||current_setting('server_version')||E'\\t'||pg_postmaster_start_time();" || true
        echo __MIDNIGHT_SSH_POSTGRES_CONNECTIONS__
        query_psql "select count(*)::text||E'\\t'||current_setting('max_connections') from pg_stat_activity;" || true
        echo __MIDNIGHT_SSH_POSTGRES_LOCKS__
        query_psql "select count(*) from pg_locks where not granted;" || true
        echo __MIDNIGHT_SSH_POSTGRES_ACTIVITY__
        query_psql "select coalesce(state,'unknown')||E'\\t'||count(*)::text from pg_stat_activity group by 1 order by 1;" || true
        echo __MIDNIGHT_SSH_POSTGRES_DATABASES__
        query_psql "select datname||E'\\t'||pg_size_pretty(pg_database_size(datname))||E'\\t'||numbackends::text from pg_stat_database where datistemplate=false order by pg_database_size(datname) desc limit 8;" || true
        """
        let output = try await MobileMonitorBridge.shared.executeCommand(
            connectionId: connectionId,
            command: script
        )
        if output.contains("__MIDNIGHT_SSH_POSTGRES_UNAVAILABLE__") {
            throw MobileRuntimeError.unavailable("PostgreSQL client psql is not installed on this host.")
        }
        return MobilePostgresSnapshot.parse(output)
    }

    private func containerStatusColor(_ container: MobileDockerContainer) -> Color {
        let state = container.state.lowercased()
        let status = container.status.lowercased()
        if state == "running" && !status.contains("unhealthy") {
            return .green
        }
        if status.contains("unhealthy") || state == "dead" {
            return .red
        }
        if state == "paused" || state == "restarting" {
            return .orange
        }
        return .secondary
    }

    @MainActor
    private func performDockerAction(_ action: MobileDockerContainerAction, on container: MobileDockerContainer) async {
        dockerActionInProgress = container.id
        defer { dockerActionInProgress = nil }

        let cmd: String
        let label: String

        switch action {
        case .start:
            cmd = "docker start \(shellQuote(container.name)) 2>&1"
            label = "Start \(container.name)"
        case .stop:
            cmd = "docker stop \(shellQuote(container.name)) 2>&1"
            label = "Stop \(container.name)"
        case .restart:
            cmd = "docker restart \(shellQuote(container.name)) 2>&1"
            label = "Restart \(container.name)"
        case .logs:
            cmd = "docker logs --tail 200 --timestamps \(shellQuote(container.name)) 2>&1"
            label = "Logs: \(container.name)"
        case .inspect:
            cmd = "docker inspect \(shellQuote(container.name)) 2>&1 | head -120"
            label = "Inspect: \(container.name)"
        case .exec:
            cmd = "echo __MIDNIGHT_DOCKER_EXEC__; echo 'Run in terminal: docker exec -it \(container.name) sh'"
            label = "Shell: \(container.name)"
        }

        do {
            let output = try await MobileMonitorBridge.shared.executeCommand(
                connectionId: connectionId,
                command: cmd
            )
            dockerActionResult = MobileDockerActionResult(label: label, output: output)

            MobileActivityLogStore.shared.record(
                title: "Docker \(action.rawValue)",
                detail: container.name,
                connectionId: connectionId,
                systemImage: "shippingbox",
                severity: .info
            )

            if action != .logs, action != .inspect, action != .exec {
                let updated = try? await loadDocker()
                if let updated {
                    dockerSnapshot = updated
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            dockerActionResult = MobileDockerActionResult(label: label, output: error.localizedDescription)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

private struct MobileDockerSnapshot {
    let serverVersion: String?
    let containers: [MobileDockerContainer]
    let images: [MobileDockerImage]

    var runningCount: Int { containers.filter { $0.state == "running" }.count }
    var exitedCount: Int { containers.filter { $0.state == "exited" }.count }

    static let empty = MobileDockerSnapshot(serverVersion: nil, containers: [], images: [])

    static func parse(_ output: String) -> MobileDockerSnapshot {
        var section = Section.none
        var version: String?
        var containers: [MobileDockerContainer] = []
        var stats: [String: MobileDockerStats] = [:]
        var images: [MobileDockerImage] = []

        for rawLine in output.split(whereSeparator: \.isNewline).map(String.init) {
            switch rawLine {
            case "__MIDNIGHT_SSH_DOCKER_VERSION__":
                section = .version
                continue
            case "__MIDNIGHT_SSH_DOCKER_CONTAINERS__":
                section = .containers
                continue
            case "__MIDNIGHT_SSH_DOCKER_STATS__":
                section = .stats
                continue
            case "__MIDNIGHT_SSH_DOCKER_IMAGES__":
                section = .images
                continue
            default:
                break
            }

            switch section {
            case .version:
                if version == nil, !rawLine.isEmpty, !rawLine.lowercased().contains("error") {
                    version = rawLine
                }
            case .containers:
                if let container = MobileDockerContainer.parse(rawLine) {
                    containers.append(container)
                }
            case .stats:
                if let stat = MobileDockerStats.parse(rawLine) {
                    stats[stat.id] = stat
                }
            case .images:
                if let image = MobileDockerImage.parse(rawLine) {
                    images.append(image)
                }
            case .none:
                break
            }
        }

        containers = containers.map { container in
            var copy = container
            copy.stats = stats.first { key, _ in
                container.id.hasPrefix(key) || key.hasPrefix(container.id) || container.name == key
            }?.value
            return copy
        }

        return MobileDockerSnapshot(serverVersion: version, containers: containers, images: images)
    }

    private enum Section {
        case none
        case version
        case containers
        case stats
        case images
    }
}

private struct MobileDockerContainer: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let state: String
    let status: String
    let ports: String
    var stats: MobileDockerStats?

    static func parse(_ line: String) -> MobileDockerContainer? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6 else { return nil }
        return MobileDockerContainer(
            id: fields[0],
            name: fields[1],
            image: fields[2],
            state: fields[3],
            status: fields[4],
            ports: fields[5],
            stats: nil
        )
    }
}

private struct MobileDockerStats: Hashable {
    let id: String
    let cpu: String
    let memory: String
    let netIO: String

    static func parse(_ line: String) -> MobileDockerStats? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4 else { return nil }
        return MobileDockerStats(id: fields[0], cpu: fields[1], memory: fields[2], netIO: fields[3])
    }
}

private struct MobileDockerImage: Identifiable, Hashable {
    let id: String
    let name: String
    let size: String
    let created: String

    static func parse(_ line: String) -> MobileDockerImage? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4 else { return nil }
        return MobileDockerImage(id: fields[1], name: fields[0], size: fields[2], created: fields[3])
    }
}

private struct MobilePostgresSnapshot {
    let meta: MobilePostgresMeta?
    let connectionUsage: MobilePostgresConnectionUsage?
    let waitingLocks: Int?
    let activity: [MobilePostgresActivity]
    let databases: [MobilePostgresDatabase]

    var waitingLocksText: String {
        waitingLocks.map(String.init) ?? "-"
    }

    static let empty = MobilePostgresSnapshot(
        meta: nil,
        connectionUsage: nil,
        waitingLocks: nil,
        activity: [],
        databases: []
    )

    static func parse(_ output: String) -> MobilePostgresSnapshot {
        var section = Section.none
        var meta: MobilePostgresMeta?
        var connectionUsage: MobilePostgresConnectionUsage?
        var waitingLocks: Int?
        var activity: [MobilePostgresActivity] = []
        var databases: [MobilePostgresDatabase] = []

        for rawLine in output.split(whereSeparator: \.isNewline).map(String.init) {
            switch rawLine {
            case "__MIDNIGHT_SSH_POSTGRES_META__":
                section = .meta
                continue
            case "__MIDNIGHT_SSH_POSTGRES_CONNECTIONS__":
                section = .connections
                continue
            case "__MIDNIGHT_SSH_POSTGRES_LOCKS__":
                section = .locks
                continue
            case "__MIDNIGHT_SSH_POSTGRES_ACTIVITY__":
                section = .activity
                continue
            case "__MIDNIGHT_SSH_POSTGRES_DATABASES__":
                section = .databases
                continue
            default:
                break
            }

            switch section {
            case .meta:
                if meta == nil {
                    meta = MobilePostgresMeta.parse(rawLine)
                }
            case .connections:
                if connectionUsage == nil {
                    connectionUsage = MobilePostgresConnectionUsage.parse(rawLine)
                }
            case .locks:
                if waitingLocks == nil {
                    waitingLocks = Int(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            case .activity:
                if let row = MobilePostgresActivity.parse(rawLine) {
                    activity.append(row)
                }
            case .databases:
                if let database = MobilePostgresDatabase.parse(rawLine) {
                    databases.append(database)
                }
            case .none:
                break
            }
        }

        return MobilePostgresSnapshot(
            meta: meta,
            connectionUsage: connectionUsage,
            waitingLocks: waitingLocks,
            activity: activity,
            databases: databases
        )
    }

    private enum Section {
        case none
        case meta
        case connections
        case locks
        case activity
        case databases
    }
}

private struct MobilePostgresMeta: Hashable {
    let database: String
    let user: String
    let version: String
    let startedAt: String

    static func parse(_ line: String) -> MobilePostgresMeta? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4 else { return nil }
        return MobilePostgresMeta(database: fields[0], user: fields[1], version: fields[2], startedAt: fields[3])
    }
}

private struct MobilePostgresConnectionUsage: Hashable {
    let active: Int
    let max: Int

    var activeText: String { "\(active)" }
    var maxText: String { "\(max)" }

    static func parse(_ line: String) -> MobilePostgresConnectionUsage? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2, let active = Int(fields[0]), let max = Int(fields[1]) else { return nil }
        return MobilePostgresConnectionUsage(active: active, max: max)
    }
}

private struct MobilePostgresActivity: Identifiable, Hashable {
    let state: String
    let count: Int

    var id: String { state }

    static func parse(_ line: String) -> MobilePostgresActivity? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2, let count = Int(fields[1]) else { return nil }
        return MobilePostgresActivity(state: fields[0].isEmpty ? "unknown" : fields[0], count: count)
    }
}

private struct MobilePostgresDatabase: Identifiable, Hashable {
    let name: String
    let size: String
    let connections: Int

    var id: String { name }

    static func parse(_ line: String) -> MobilePostgresDatabase? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3, let connections = Int(fields[2]) else { return nil }
        return MobilePostgresDatabase(name: fields[0], size: fields[1], connections: connections)
    }
}

private enum MobileRuntimeError: Error, LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}

private enum MobileDockerContainerAction: String {
    case start
    case stop
    case restart
    case logs
    case inspect
    case exec
}

private struct MobileDockerActionResult: Identifiable {
    let id = UUID()
    let label: String
    let output: String
}

private struct MobileDockerActionResultSheet: View {
    let result: MobileDockerActionResult

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(result.output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            .padding()
            .navigationTitle(result.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        UIPasteboard.general.string = result.output
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
