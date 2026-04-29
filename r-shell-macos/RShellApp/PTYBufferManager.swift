import Foundation
import OSLog

/// Accumulates terminal output data into a buffer and flushes adaptively.
///
/// Three flush modes adapt to the current workload:
/// - **Low throughput** (interactive typing): flush every 16ms (~60 fps)
/// - **High throughput** (`cat`, `yes`): flush at 16KB or every 100ms
/// - **Burst** (sudden large output): flush immediately at 64KB
///
/// The mode auto-detects based on recent throughput and adjusts thresholds.
/// This keeps interactive sessions responsive while avoiding FFI overhead
/// during bulk output.
@MainActor
class PTYBufferManager {
    private let logger = Logger(subsystem: "com.r-shell", category: "pty-buffer")
    private var buffer = Data()
    private var flushTimer: DispatchSourceTimer?
    private let onFlush: (Data) -> Void
    private var workloadHints = WorkloadHints()

    /// Current active threshold (auto-tuned).
    private var currentThreshold = 16 * 1024
    private var currentInterval: DispatchTimeInterval = .milliseconds(50)

    var currentBufferSize: Int { buffer.count }

    init(onFlush: @escaping (Data) -> Void) {
        self.onFlush = onFlush
    }

    // MARK: - Public API

    func append(_ data: Data) {
        let start = CFAbsoluteTimeGetCurrent()
        buffer.append(data)
        workloadHints.record(bytes: data.count)

        if buffer.count >= 64 * 1024 {
            flush(withLatency: CFAbsoluteTimeGetCurrent() - start)
            return
        }

        tuneThresholds()

        if buffer.count >= currentThreshold {
            flush(withLatency: CFAbsoluteTimeGetCurrent() - start)
            return
        }

        if flushTimer == nil {
            startTimer()
        }
    }

    func flush() {
        flush(withLatency: 0)
    }

    func reset() {
        cancel()
        buffer.removeAll()
        workloadHints.reset()
    }

    /// Explicitly cancel the flush timer and release the dispatch source.
    /// Must be called before the manager is deallocated — the `@MainActor`
    /// deinit cannot touch the timer itself. `TerminalSessionManager`
    /// calls this from `unregisterSession` during session teardown.
    func cancel() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    // MARK: - Adaptive tuning

    private func tuneThresholds() {
        let recentBps = workloadHints.bytesPerSecond

        switch recentBps {
        case ..<10_000:         // Interactive: ~10 KB/s
            currentThreshold = 4 * 1024     // 4 KB
            currentInterval = .milliseconds(16)  // ~60 fps
        case 10_000..<500_000:  // Moderate: 10–500 KB/s
            currentThreshold = 16 * 1024    // 16 KB
            currentInterval = .milliseconds(50)
        default:                // High throughput: >500 KB/s
            currentThreshold = 32 * 1024    // 32 KB
            currentInterval = .milliseconds(100)

            // At very high throughput, skip timer and rely on threshold only
            if recentBps > 2_000_000 {
                cancelTimer()
                return
            }
        }
    }

    // MARK: - Timer

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + currentInterval, repeating: currentInterval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.flush()
            }
        }
        timer.resume()
        flushTimer = timer
    }

    private func cancelTimer() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    // MARK: - Flush

    private func flush(withLatency additionalLatency: Double) {
        cancelTimer()
        guard !buffer.isEmpty else { return }

        let start = CFAbsoluteTimeGetCurrent()
        let chunk = buffer
        buffer = Data()

        let latencyMs = (CFAbsoluteTimeGetCurrent() - start + additionalLatency) * 1000
        onFlush(chunk)

        PTYProfiler.shared.recordFlush(batchSize: chunk.count, latencyMs: latencyMs)
    }

    deinit {
        // The DispatchSourceTimer is released alongside the manager. We
        // can't call the @MainActor `cancelTimer()` from a non-isolated
        // deinit; `TerminalSessionManager.unregisterSession` calls
        // `cancel()` before removing the session.
    }
}

// MARK: - Workload detection

private struct WorkloadHints {
    private var samples: [(time: CFAbsoluteTime, bytes: Int)] = []
    private let window: CFAbsoluteTime = 1.0  // 1-second window

    mutating func record(bytes: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        samples.append((now, bytes))
        prune(now: now)
    }

    /// Best-effort throughput; relies on `record(bytes:)` to keep `samples`
    /// pruned to the active window. Computed properties can't mutate, so we
    /// don't re-prune here.
    var bytesPerSecond: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let totalBytes = samples.reduce(0) { $0 + $1.bytes }
        let span = last.time - first.time
        return span > 0 ? Double(totalBytes) / span : 0
    }

    private mutating func prune(now: CFAbsoluteTime) {
        samples.removeAll { now - $0.time > window }
    }

    mutating func reset() {
        samples.removeAll()
    }
}
