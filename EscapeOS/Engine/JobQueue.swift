import Foundation

/// Why a queue exists, from the person's side: several heavy tasks started close together run one
/// after another instead of at the same time (issue #11). Two big copies fighting over the same
/// storage are slower than the same two in turn, and a compress that reads a folder while a paste
/// is still writing into it can capture half of it.
///
/// This file has no UI in it, so the order, cancellation and error rules can be tested on the host.
/// `OperationCenter` wraps it for SwiftUI.

enum JobKind: String, Equatable {
    /// Bookkeeping that normally finishes in a blink (rename, create a folder, move to the trash).
    /// It is queued like everything else so it cannot race a heavy job on the same folder; the UI
    /// only mentions it if it turns out to be slow.
    case quick
    case heavy
}

enum JobState: Equatable {
    case queued
    case running
    case succeeded
    case failed(String)
    case cancelled
}

/// What a finished job reports to its submitter.
enum JobOutcome {
    /// `message` is a short confirmation to show ("Created “a.zip”"), if the job has one.
    case succeeded(message: String?)
    case failed(Error)
    case cancelled
}

/// Thrown by a job (usually via `JobContext.checkCancelled`) when it stops because it was cancelled.
struct JobCancelled: Error, LocalizedError {
    var errorDescription: String? { "Cancelled." }
}

/// One entry in the queue as the UI sees it.
struct JobInfo: Identifiable, Equatable {
    let id: UUID
    let title: String
    /// What the job works on (an app's container path, or nil for the device as a whole).
    let scope: String?
    let kind: JobKind
    var state: JobState
    var progress: ProgressSnapshot
}

/// Handed to a running job: how it reports progress and learns it should stop.
final class JobContext {
    let meter: ProgressMeter
    private let lock = NSLock()
    private var cancelRequested = false

    init(meter: ProgressMeter) {
        self.meter = meter
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    /// Call between steps; throws so the job unwinds and cleans up through its normal error path.
    func checkCancelled() throws {
        if isCancelled { throw JobCancelled() }
    }

    fileprivate func requestCancel() {
        lock.lock()
        cancelRequested = true
        lock.unlock()
    }
}

final class JobQueue {
    private final class Record {
        let id = UUID()
        let title: String
        let scope: String?
        let kind: JobKind
        let work: (JobContext) throws -> String?
        let completion: ((JobOutcome) -> Void)?
        let context: JobContext
        var state: JobState = .queued

        init(
            title: String,
            scope: String?,
            kind: JobKind,
            work: @escaping (JobContext) throws -> String?,
            completion: ((JobOutcome) -> Void)?
        ) {
            self.title = title
            self.scope = scope
            self.kind = kind
            self.work = work
            self.completion = completion
            self.context = JobContext(meter: ProgressMeter())
        }
    }

    private let lock = NSLock()
    private var records: [Record] = []
    private var draining = false
    private let worker = DispatchQueue(label: "escapeos.jobs", qos: .userInitiated)
    private let completionQueue: DispatchQueue
    private let onChange: () -> Void
    /// Counts jobs from submission until their completion has been delivered, so tests (and a
    /// quitting app) can wait for the whole thing to settle.
    private let pending = DispatchGroup()

    /// - Parameters:
    ///   - completionQueue: where `completion` closures run. The app passes the main queue.
    ///   - onChange: called after the set of jobs or a job's state changes (not on every byte);
    ///     from any thread.
    init(completionQueue: DispatchQueue = .main, onChange: @escaping () -> Void = {}) {
        self.completionQueue = completionQueue
        self.onChange = onChange
    }

    /// Queue a job. Runs after everything submitted before it.
    ///
    /// - Parameter work: runs on a background thread; returns an optional confirmation message.
    @discardableResult
    func submit(
        title: String,
        kind: JobKind = .heavy,
        scope: String? = nil,
        work: @escaping (JobContext) throws -> String?,
        completion: ((JobOutcome) -> Void)? = nil
    ) -> UUID {
        let record = Record(title: title, scope: scope, kind: kind, work: work, completion: completion)
        pending.enter()
        lock.lock()
        records.append(record)
        let start = !draining
        if start { draining = true }
        lock.unlock()
        onChange()
        if start {
            worker.async { self.drain() }
        }
        return record.id
    }

    /// Cancel a job. A queued one is dropped without ever running; a running one is asked to stop
    /// and stops at its next `checkCancelled()`.
    func cancel(_ id: UUID) {
        var dropped: Record?
        lock.lock()
        if let index = records.firstIndex(where: { $0.id == id }) {
            let record = records[index]
            if record.state == .queued {
                record.state = .cancelled
                records.remove(at: index)
                dropped = record
            } else if record.state == .running {
                record.context.requestCancel()
            }
        }
        lock.unlock()
        if let dropped {
            deliver(dropped, outcome: .cancelled)
            onChange()
        }
    }

    /// Cancel everything queued or running for `scope` (nil cancels all scopes).
    func cancelAll(scope: String? = nil) {
        lock.lock()
        let ids = records.filter { scope == nil || $0.scope == scope }.map(\.id)
        lock.unlock()
        for id in ids { cancel(id) }
    }

    /// Queued and running jobs, oldest first.
    func snapshot() -> [JobInfo] {
        lock.lock()
        let current = records
        lock.unlock()
        return current.map { record in
            JobInfo(
                id: record.id,
                title: record.title,
                scope: record.scope,
                kind: record.kind,
                state: record.state,
                progress: record.context.meter.snapshot()
            )
        }
    }

    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return records.isEmpty
    }

    /// True when a job for `scope` is queued or running.
    func hasWork(scope: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records.contains { $0.scope == scope }
    }

    /// Blocks until every submitted job has finished and been reported. For tests and shutdown.
    @discardableResult
    func waitUntilSettled(timeout: TimeInterval = 10) -> Bool {
        pending.wait(timeout: .now() + timeout) == .success
    }

    // MARK: - Running

    private func drain() {
        while true {
            lock.lock()
            guard let next = records.first(where: { $0.state == .queued }) else {
                draining = false
                lock.unlock()
                return
            }
            next.state = .running
            lock.unlock()
            onChange()

            let outcome = run(next)

            lock.lock()
            records.removeAll { $0.id == next.id }
            switch outcome {
            case .succeeded: next.state = .succeeded
            case .failed(let error): next.state = .failed(error.localizedDescription)
            case .cancelled: next.state = .cancelled
            }
            lock.unlock()
            deliver(next, outcome: outcome)
            onChange()
        }
    }

    private func run(_ record: Record) -> JobOutcome {
        do {
            let message = try record.work(record.context)
            record.context.meter.finish()
            return .succeeded(message: message)
        } catch is JobCancelled {
            return .cancelled
        } catch {
            return .failed(error)
        }
    }

    private func deliver(_ record: Record, outcome: JobOutcome) {
        completionQueue.async {
            record.completion?(outcome)
            self.pending.leave()
        }
    }
}
