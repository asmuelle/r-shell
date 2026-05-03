import MapKit
import SwiftUI

struct MobileConnectionMapView: View {
    let connectionId: String

    @State private var snapshot = MobileRemoteIPMapSnapshot.empty
    @State private var isLoading = false
    @State private var lastError: String?

    private static let maxGeolocatedIPs = 24
    private static let remoteAddressScript = """
    set +e

    emit_connected() {
      [ -n "$1" ] || return 0
      printf 'CONNECTED\\t%s\\n' "$1"
    }

    if [ -n "${SSH_CONNECTION:-}" ]; then
      set -- $SSH_CONNECTION
      emit_connected "$1"
    fi

    if [ -n "${SSH_CLIENT:-}" ]; then
      set -- $SSH_CLIENT
      emit_connected "$1"
    fi

    if command -v ss >/dev/null 2>&1; then
      ss -Htn state established 2>/dev/null | awk 'NF >= 5 {print "CONNECTED\\t" $NF}'
    elif command -v netstat >/dev/null 2>&1; then
      netstat -ant 2>/dev/null | awk 'toupper($0) ~ /ESTABLISHED/ && NF >= 5 {print "CONNECTED\\t" $(NF-1)}'
    fi

    if command -v fail2ban-client >/dev/null 2>&1; then
      f2b_status="$(sudo -n fail2ban-client status 2>/dev/null || fail2ban-client status 2>/dev/null || true)"
      jails="$(printf '%s\\n' "$f2b_status" | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ')"
      for jail in $jails; do
        jail="$(printf '%s' "$jail" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$jail" ] || continue
        (sudo -n fail2ban-client status "$jail" 2>/dev/null || fail2ban-client status "$jail" 2>/dev/null || true) \
          | sed -n 's/.*Banned IP list:[[:space:]]*//p' \
          | tr ' ' '\\n' \
          | awk 'NF {print "BANNED\\t" $1}'
      done
    fi

    if command -v ufw >/dev/null 2>&1; then
      if sudo -n test -r /var/log/ufw.log 2>/dev/null; then
        sudo -n tail -n 500 /var/log/ufw.log 2>/dev/null
      elif command -v journalctl >/dev/null 2>&1; then
        sudo -n journalctl -k -n 500 --no-pager 2>/dev/null
      else
        true
      fi | awk 'index($0, "[UFW BLOCK]") || index($0, "[UFW DENY]") {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^SRC=/) {
            sub(/^SRC=/, "", $i)
            print "BANNED\\t" $i
          }
        }
      }'
    fi
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            MobileWorldMapCanvas(points: snapshot.points)
                .frame(height: 180)

            HStack(spacing: 12) {
                legend(color: .green, label: "Connected", count: snapshot.connectedCount)
                legend(color: .red, label: "Blocked", count: snapshot.bannedCount)
                Spacer()
                if snapshot.truncatedCount > 0 {
                    Text("+\(snapshot.truncatedCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let lastError {
                Label(lastError, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if snapshot.connectedCount == 0 && snapshot.bannedCount == 0 && !isLoading {
                Text("No public connected or blocked IPs found.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if snapshot.points.isEmpty && !isLoading {
                Text("IPs were found, but geolocation is unavailable.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        .task(id: connectionId) {
            await refresh()
        }
    }

    private var header: some View {
        HStack {
            Label("Connection Map", systemImage: "map")
                .font(.headline)

            Spacer()

            if let updatedAt = snapshot.updatedAt {
                Text(updatedAt, style: .time)
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
            .accessibilityLabel("Refresh connection map")
        }
    }

    private func legend(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(label) \(count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let output = try await MobileMonitorBridge.shared.executeCommand(
                connectionId: connectionId,
                command: Self.remoteAddressScript
            )
            let addresses = MobileRemoteIPParser.parse(output)
            let sourceIPs = Self.cappedSourceIPs(
                connected: addresses.connected,
                banned: addresses.banned
            )
            let locations = await MobileIPGeolocationService.shared.lookup(sourceIPs.visible)
            snapshot = MobileRemoteIPMapSnapshot(
                connectedCount: addresses.connected.count,
                bannedCount: addresses.banned.count,
                truncatedCount: sourceIPs.truncated,
                points: makePoints(
                    connected: addresses.connected,
                    banned: addresses.banned,
                    locations: locations
                ),
                updatedAt: Date()
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func cappedSourceIPs(
        connected: [String],
        banned: [String]
    ) -> (visible: [String], truncated: Int) {
        let all = MobileRemoteIPParser.unique(connected + banned)
        let visible = Array(all.prefix(maxGeolocatedIPs))
        return (visible, max(0, all.count - visible.count))
    }

    private func makePoints(
        connected: [String],
        banned: [String],
        locations: [String: MobileIPGeolocation]
    ) -> [MobileRemoteIPMapPoint] {
        let connectedOnly = connected.filter { !banned.contains($0) }
        let connectedPoints = connectedOnly.compactMap { ip -> MobileRemoteIPMapPoint? in
            guard let location = locations[ip] else { return nil }
            return MobileRemoteIPMapPoint(ip: ip, kind: .connected, location: location)
        }
        let bannedPoints = banned.compactMap { ip -> MobileRemoteIPMapPoint? in
            guard let location = locations[ip] else { return nil }
            return MobileRemoteIPMapPoint(ip: ip, kind: .banned, location: location)
        }
        return connectedPoints + bannedPoints
    }
}

private struct MobileRemoteIPMapSnapshot {
    let connectedCount: Int
    let bannedCount: Int
    let truncatedCount: Int
    let points: [MobileRemoteIPMapPoint]
    let updatedAt: Date?

    static let empty = MobileRemoteIPMapSnapshot(
        connectedCount: 0,
        bannedCount: 0,
        truncatedCount: 0,
        points: [],
        updatedAt: nil
    )
}

private enum MobileRemoteIPMapPointKind {
    case connected
    case banned

    var color: Color {
        switch self {
        case .connected:
            return .green
        case .banned:
            return .red
        }
    }
}

private struct MobileRemoteIPMapPoint: Identifiable {
    let ip: String
    let kind: MobileRemoteIPMapPointKind
    let location: MobileIPGeolocation

    var id: String { "\(kind):\(ip)" }
}

private struct MobileWorldMapCanvas: View {
    let points: [MobileRemoteIPMapPoint]

    @State private var region = Self.worldRegion

    private static let worldRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 18, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 145, longitudeDelta: 360)
    )

    private var regionKey: String {
        points
            .map { point in
                "\(point.id):\(point.location.coordinate.latitude):\(point.location.coordinate.longitude)"
            }
            .joined(separator: "|")
    }

    var body: some View {
        Map(coordinateRegion: $region, annotationItems: points) { point in
            MapAnnotation(coordinate: point.location.coordinate.mapCoordinate) {
                Circle()
                    .fill(point.kind.color)
                    .frame(width: point.kind == .banned ? 12 : 10, height: point.kind == .banned ? 12 : 10)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 1.25)
                    )
                    .shadow(color: point.kind.color.opacity(0.65), radius: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .onAppear {
            fitRegionToPoints()
        }
        .onChange(of: regionKey) { _ in
            fitRegionToPoints()
        }
    }

    private func fitRegionToPoints() {
        guard !points.isEmpty else {
            region = Self.worldRegion
            return
        }

        let latitudes = points.map(\.location.coordinate.latitude)
        let longitudes = points.map(\.location.coordinate.longitude)
        guard let minLatitude = latitudes.min(),
              let maxLatitude = latitudes.max()
        else {
            region = Self.worldRegion
            return
        }

        let longitudeFit = Self.fittedLongitudeCenterAndSpan(longitudes)
        let latitudeDelta = Self.paddedDelta(maxLatitude - minLatitude, minimum: 18, maximum: 145)
        let longitudeDelta = Self.paddedDelta(longitudeFit.span, minimum: 28, maximum: 360)
        let latitudeCenter = max(-72, min(72, (minLatitude + maxLatitude) / 2))

        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: latitudeCenter,
                longitude: Self.normalizedLongitude(longitudeFit.center)
            ),
            span: MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: longitudeDelta
            )
        )
    }

    private static func paddedDelta(_ delta: Double, minimum: Double, maximum: Double) -> Double {
        let padded = delta <= 0 ? minimum : delta * 1.4 + minimum * 0.35
        return min(maximum, max(minimum, padded))
    }

    private static func fittedLongitudeCenterAndSpan(_ longitudes: [Double]) -> (center: Double, span: Double) {
        guard !longitudes.isEmpty else { return (0, 360) }
        let sorted = longitudes
            .map { normalized360($0) }
            .sorted()
        guard sorted.count > 1 else {
            return (sorted[0], 0)
        }

        var largestGap = -1.0
        var gapAfterIndex = 0
        for index in sorted.indices {
            let current = sorted[index]
            let next = index == sorted.index(before: sorted.endIndex)
                ? sorted[0] + 360
                : sorted[sorted.index(after: index)]
            let gap = next - current
            if gap > largestGap {
                largestGap = gap
                gapAfterIndex = index
            }
        }

        let startIndex = sorted.index(after: gapAfterIndex) == sorted.endIndex
            ? sorted.startIndex
            : sorted.index(after: gapAfterIndex)
        let start = sorted[startIndex]
        let end = sorted[gapAfterIndex] < start
            ? sorted[gapAfterIndex] + 360
            : sorted[gapAfterIndex]
        return (center: start + (end - start) / 2, span: end - start)
    }

    private static func normalized360(_ longitude: Double) -> Double {
        let value = longitude.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        let value = (longitude + 180).truncatingRemainder(dividingBy: 360)
        return (value < 0 ? value + 360 : value) - 180
    }
}

private struct MobileGeoCoordinate {
    let longitude: Double
    let latitude: Double

    var mapCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct MobileIPGeolocation {
    let coordinate: MobileGeoCoordinate
    let city: String?
    let country: String?
}

private actor MobileIPGeolocationService {
    static let shared = MobileIPGeolocationService()

    private var cache: [String: MobileIPGeolocation] = [:]
    private var failed = Set<String>()

    func lookup(_ ips: [String]) async -> [String: MobileIPGeolocation] {
        let unique = MobileRemoteIPParser.unique(ips)
        var result: [String: MobileIPGeolocation] = [:]

        for ip in unique {
            if let cached = cache[ip] {
                result[ip] = cached
                continue
            }
            if failed.contains(ip) {
                continue
            }
            guard !Task.isCancelled else { break }
            if let location = await fetch(ip) {
                cache[ip] = location
                result[ip] = location
            } else {
                failed.insert(ip)
            }
        }

        return result
    }

    private func fetch(_ ip: String) async -> MobileIPGeolocation? {
        guard let encodedIP = ip.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://ipwho.is/\(encodedIP)?fields=success,message,ip,latitude,longitude,city,country,country_code")
        else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(MobileIPWhoIsResponse.self, from: data)
            guard decoded.success,
                  let latitude = decoded.latitude,
                  let longitude = decoded.longitude,
                  (-90...90).contains(latitude),
                  (-180...180).contains(longitude)
            else { return nil }
            return MobileIPGeolocation(
                coordinate: MobileGeoCoordinate(longitude: longitude, latitude: latitude),
                city: decoded.city,
                country: decoded.country
            )
        } catch {
            return nil
        }
    }
}

private struct MobileIPWhoIsResponse: Decodable {
    let success: Bool
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let country: String?
}

private enum MobileRemoteIPParser {
    static func parse(_ output: String) -> (connected: [String], banned: [String]) {
        var connected: [String] = []
        var banned: [String] = []

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let ip = extractIPAddress(from: String(parts[1])),
                  isPublicIPAddress(ip)
            else { continue }

            switch parts[0] {
            case "CONNECTED":
                appendUnique(ip, to: &connected)
            case "BANNED":
                appendUnique(ip, to: &banned)
            default:
                continue
            }
        }

        return (connected, banned)
    }

    static func unique(_ values: [String]) -> [String] {
        values.reduce(into: [String]()) { result, value in
            if !result.contains(value) {
                result.append(value)
            }
        }
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        if !values.contains(value) {
            values.append(value)
        }
    }

    private static func extractIPAddress(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ipv4 = extractIPv4(from: trimmed) {
            return ipv4
        }

        if let start = trimmed.firstIndex(of: "["),
           let end = trimmed[start...].firstIndex(of: "]") {
            let candidate = String(trimmed[trimmed.index(after: start)..<end])
            return looksLikeIPv6(candidate) ? normalizeIPv6(candidate) : nil
        }

        let token = trimmed
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .first
            .map(String.init) ?? trimmed
        let withoutCIDR = token.split(separator: "/", maxSplits: 1).first.map(String.init) ?? token
        let withoutZone = withoutCIDR.split(separator: "%", maxSplits: 1).first.map(String.init) ?? withoutCIDR
        let candidate = withoutZone.trimmingCharacters(in: CharacterSet(charactersIn: "[]()<>;"))
        return looksLikeIPv6(candidate) ? normalizeIPv6(candidate) : nil
    }

    private static func extractIPv4(from value: String) -> String? {
        let pattern = #"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let swiftRange = Range(match.range, in: value)
        else { return nil }
        let candidate = String(value[swiftRange])
        let octets = candidate.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets.allSatisfy { (0...255).contains($0) } ? candidate : nil
    }

    private static func looksLikeIPv6(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:")
        return value.contains(":")
            && value.rangeOfCharacter(from: allowed.inverted) == nil
            && (value.contains("::") || value.split(separator: ":").count >= 3)
    }

    private static func normalizeIPv6(_ value: String) -> String {
        value.lowercased()
    }

    private static func isPublicIPAddress(_ ip: String) -> Bool {
        if ip.contains(":") {
            return isPublicIPv6(ip)
        }
        return isPublicIPv4(ip)
    }

    private static func isPublicIPv4(_ ip: String) -> Bool {
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        let first = octets[0]
        let second = octets[1]
        let third = octets[2]

        if first == 0 || first == 10 || first == 127 { return false }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 && second == 168 { return false }
        if first == 192 && second == 0 && third == 2 { return false }
        if first == 198 && (second == 18 || second == 19) { return false }
        if first == 198 && second == 51 && third == 100 { return false }
        if first == 203 && second == 0 && third == 113 { return false }
        if first >= 224 { return false }
        return true
    }

    private static func isPublicIPv6(_ ip: String) -> Bool {
        let lower = ip.lowercased()
        if lower == "::" || lower == "::1" { return false }
        if lower.hasPrefix("fe80:") { return false }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return false }
        if lower.hasPrefix("ff") { return false }
        if lower.hasPrefix("2001:db8") { return false }
        return true
    }
}
