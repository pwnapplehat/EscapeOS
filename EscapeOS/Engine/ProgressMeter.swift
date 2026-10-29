import Foundation

/// A frozen reading of how far a long operation has got.
///
/// Issue #11: long operations (compress, copy, extract, backup of a large app) showed only a
/// spinner. Percentage, speed and time left are shown where they can be known, and left out where
/// they cannot: a number that is a guess is worse than none.
struct ProgressSnapshot: Equatable {
    var bytesDone: Int64 = 0
    /// Nil when the total is not known up front (the work is discovered as it goes).
    var bytesTotal: Int64?
    var itemsDone: Int = 0
    var itemsTotal: Int?
    /// What it is working on right now (a file name), for the status line.
    var detail: String?
    /// 0...1, or nil when there is no total to measure against.
    var fraction: Double?
    /// Smoothed over the last few seconds, or nil until there is enough to say.
    var bytesPerSecond: Double?
    /// Nil unless the total, the speed and enough elapsed time are all known.
    var secondsRemaining: TimeInterval?

    var isDeterminate: Bool { fraction != nil }
}

/// Measures progress of one operation and derives percent, speed and time left.
///
/// Written to by the worker thread and read by the UI, so every access takes the lock.
final class ProgressMeter {
    /// How long a stretch the speed is averaged over. Long enough to smooth out a slow file between
    /// two fast ones, short enough that a stall shows.
    static let speedWindow: TimeInterval = 5
    /// Nothing is said about speed until this much time has passed since the first byte.
    static let minSpeedSpan: TimeInterval = 0.75
    /// Time left is not estimated this early: the first seconds are rarely typical.
    static let minElapsedForEstimate: TimeInterval = 1.5

    private let clock: () -> TimeInterval
    private let lock = NSLock()
    private let startTime: TimeInterval
    private var bytesDone: Int64 = 0
    private var bytesTotal: Int64?
    private var itemsDone = 0
    private var itemsTotal: Int?
    private var detail: String?
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var finished = false

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        self.startTime = clock()
        samples.append((startTime, 0))
    }

    // MARK: - Writing

    /// Set what is known about the size of the work. Either may stay nil.
    func setTotals(bytes: Int64? = nil, items: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let bytes { bytesTotal = max(bytes, 0) }
        if let items { itemsTotal = max(items, 0) }
    }

    func add(bytes: Int64) {
        guard bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        bytesDone += bytes
        record()
    }

    /// Set bytes done outright, for sources that report a running total rather than a delta.
    func set(bytesDone value: Int64) {
        lock.lock()
        defer { lock.unlock() }
        bytesDone = max(value, 0)
        record()
    }

    func completeItem(detail: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        itemsDone += 1
        if let detail { self.detail = detail }
    }

    func setItems(done: Int, detail: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        itemsDone = max(done, 0)
        if let detail { self.detail = detail }
    }

    func setDetail(_ text: String?) {
        lock.lock()
        defer { lock.unlock() }
        detail = text
    }

    /// Mark the operation complete: the fraction reads 1 and no time is left.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
    }

    // MARK: - Reading

    func snapshot() -> ProgressSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        var snap = ProgressSnapshot()
        snap.bytesDone = bytesDone
        snap.bytesTotal = bytesTotal
        snap.itemsDone = itemsDone
        snap.itemsTotal = itemsTotal
        snap.detail = detail

        if finished {
            snap.fraction = 1
            snap.secondsRemaining = 0
            snap.bytesPerSecond = speed(at: now)
            return snap
        }

        if let total = bytesTotal, total > 0 {
            snap.fraction = min(max(Double(bytesDone) / Double(total), 0), 1)
        } else if let total = itemsTotal, total > 0 {
            snap.fraction = min(max(Double(itemsDone) / Double(total), 0), 1)
        }

        snap.bytesPerSecond = speed(at: now)

        if let total = bytesTotal, total > 0,
           let rate = snap.bytesPerSecond, rate > 0,
           now - startTime >= Self.minElapsedForEstimate,
           bytesDone < total {
            snap.secondsRemaining = Double(total - bytesDone) / rate
        }
        return snap
    }

    // MARK: - Internals

    private func record() {
        let now = clock()
        // Keep the sample list short: one every tenth of a second is plenty for a speed.
        if let last = samples.last, now - last.time < 0.1 {
            samples[samples.count - 1] = (last.time, bytesDone)
        } else {
            samples.append((now, bytesDone))
        }
        let cutoff = now - Self.speedWindow
        // Keep the newest sample that is at or before the cutoff as the left edge of the window.
        while samples.count > 2, samples[1].time <= cutoff {
            samples.removeFirst()
        }
    }

    private func speed(at now: TimeInterval) -> Double? {
        guard let oldest = samples.first else { return nil }
        let windowStart = max(oldest.time, now - Self.speedWindow)
        // Bytes at the window's left edge: interpolate from the samples around it.
        let bytesAtStart = bytes(at: windowStart)
        let span = now - windowStart
        guard span >= Self.minSpeedSpan else { return nil }
        let moved = bytesDone - bytesAtStart
        guard moved > 0 else { return nil }
        return Double(moved) / span
    }

    private func bytes(at time: TimeInterval) -> Int64 {
        guard let first = samples.first else { return 0 }
        if time <= first.time { return first.bytes }
        var previous = first
        for sample in samples.dropFirst() {
            if sample.time >= time {
                let width = sample.time - previous.time
                guard width > 0 else { return sample.bytes }
                let t = (time - previous.time) / width
                return previous.bytes + Int64(Double(sample.bytes - previous.bytes) * t)
            }
            previous = sample
        }
        return previous.bytes
    }
}

/// Words for a snapshot. Pure, so the wording is tested.
enum ProgressFormat {
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        "\(bytes(Int64(bytesPerSecond.rounded())))/s"
    }

    /// Coarse on purpose: "about 3 min left", not "3:07".
    static func timeLeft(_ seconds: TimeInterval) -> String {
        if seconds < 5 { return "a few seconds left" }
        if seconds < 60 {
            let rounded = Int((seconds / 5).rounded(.up)) * 5
            return rounded >= 60 ? "about 1 min left" : "about \(rounded) sec left"
        }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "about \(minutes) min left" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "about \(hours) h left" : "about \(hours) h \(rest) min left"
    }

    /// One line for the status bar: only the parts that are known, in the order people look for
    /// them. Nil when nothing is known yet (the bar then shows an indeterminate spinner).
    static func line(for snapshot: ProgressSnapshot) -> String? {
        var parts: [String] = []
        if let fraction = snapshot.fraction { parts.append(percent(fraction)) }
        if snapshot.bytesTotal == nil, let total = snapshot.itemsTotal, total > 0 {
            parts.append("\(snapshot.itemsDone) of \(total) files")
        }
        if let rate = snapshot.bytesPerSecond { parts.append(speed(rate)) }
        if let left = snapshot.secondsRemaining, snapshot.fraction != 1 { parts.append(timeLeft(left)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
