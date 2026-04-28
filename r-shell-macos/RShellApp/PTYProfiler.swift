import Foundation
import OSLog

/// Collects performance metrics for PTY streaming: FFI call latency,
/// batch flush frequency, batch sizes, and rendering frame times.
///
/// All metrics are recorded in ring buffers and exposed as a snapshot
/// for debugging (⌥⌘P to show in bottom panel).
@MainActor
class PTYProfiler {
    static let shared = PTYProfiler()
    private let logger = Logger(subsystem: "com.r-shell", category: "profiler")

    // MARK: - Metrics

    struct Snapshot {
        var totalBytesReceived: UInt64 = 0
        var totalFlushes: UInt64 = 0
        var avgBatchSize: Double = 0
        var maxBatchSize: Int = 0
        var flushesPerSecond: Double = 0
        var avgFlushLatencyMs: Double = 0
        var frameTimeMs: Double = 0
    }

    private var bytesReceived: UInt64 = 0
    private var flushCount: UInt64 = 0
    private var batchSizes: [Int] = []
    private var flushTimestamps: [Date] = []
    private var flushLatencies: [Double] = []  // ms
    private var frameTimestamps: [Date] = []

    private let maxSamples = 1000
    private var lastSnapshot = Snapshot()
    private var lastSnapshotTime = Date()

    private init() {}

    // MARK: - Recording

    func recordFlush(batchSize: Int, latencyMs: Double) {
        bytesReceived += UInt64(batchSize)
        flushCount += 1
        batchSizes.append(batchSize)
        flushTimestamps.append(Date())
        flushLatencies.append(latencyMs)

        if batchSizes.count > maxSamples {
            batchSizes.removeFirst(batchSizes.count - maxSamples)
            flushTimestamps.removeFirst(flushTimestamps.count - maxSamples)
            flushLatencies.removeFirst(flushLatencies.count - maxSamples)
        }
    }

    func recordFrame() {
        frameTimestamps.append(Date())
        if frameTimestamps.count > maxSamples {
            frameTimestamps.removeFirst(frameTimestamps.count - maxSamples)
        }
    }

    // MARK: - Snapshot

    func snapshot() -> Snapshot {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSnapshotTime)
        defer { lastSnapshotTime = now }

        let avgBatch = batchSizes.isEmpty ? 0 : Double(batchSizes.reduce(0, +)) / Double(batchSizes.count)
        let maxBatch = batchSizes.max() ?? 0
        let flushRate = elapsed > 0 ? Double(flushTimestamps.count) / elapsed : 0

        // Recent latency (last 100 flushes)
        let recentLatencies = flushLatencies.suffix(100)
        let avgLatency = recentLatencies.isEmpty ? 0 : recentLatencies.reduce(0, +) / Double(recentLatencies.count)

        // Frame rate
        let recentFrames = frameTimestamps.suffix(60)
        let frameTime: Double
        if recentFrames.count >= 2 {
            let interval = recentFrames.last!.timeIntervalSince(recentFrames.first!)
            frameTime = interval / Double(recentFrames.count - 1) * 1000
        } else {
            frameTime = 0
        }

        let snap = Snapshot(
            totalBytesReceived: bytesReceived,
            totalFlushes: flushCount,
            avgBatchSize: avgBatch,
            maxBatchSize: maxBatch,
            flushesPerSecond: flushRate,
            avgFlushLatencyMs: avgLatency,
            frameTimeMs: frameTime
        )

        lastSnapshot = snap

        // Log diagnostic every 30s during heavy output. Pre-format the
        // numeric pieces so the type-checker doesn't have to resolve a
        // single expression with six interpolations + concatenations.
        if flushCount % 500 == 0 && flushCount > 0 {
            let avgBatch = String(format: "%.1f", snap.avgBatchSize)
            let perSec = String(format: "%.1f", snap.flushesPerSecond)
            let lat = String(format: "%.2f", snap.avgFlushLatencyMs)
            let frame = String(format: "%.1f", snap.frameTimeMs)
            logger.info(
                """
                PTY perf: \(snap.totalBytesReceived) bytes, \
                \(snap.totalFlushes) flushes, \
                avg \(avgBatch) B/batch, \(perSec) flushes/s, \
                lat \(lat) ms, frame \(frame) ms
                """
            )
        }

        return snap
    }

    func reset() {
        bytesReceived = 0
        flushCount = 0
        batchSizes.removeAll()
        flushTimestamps.removeAll()
        flushLatencies.removeAll()
        frameTimestamps.removeAll()
    }
}
