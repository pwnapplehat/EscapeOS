import Foundation

/// A thread-safe box for what a test's jobs record.
private final class Log {
    private let lock = NSLock()
    private var entries: [String] = []
    private var running = 0
    private(set) var maxRunning = 0

    func add(_ text: String) {
        lock.lock(); entries.append(text); lock.unlock()
    }
    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
    func enter() {
        lock.lock(); running += 1; maxRunning = max(maxRunning, running); lock.unlock()
    }
    func leave() {
        lock.lock(); running -= 1; lock.unlock()
    }
}

private struct Boom: LocalizedError {
    var errorDescription: String? { "boom" }
}

func runJobQueueTests() {
    T.section("JobQueue")
    let callbacks = DispatchQueue(label: "test.callbacks")

    // jobs run one at a time, in the order they were submitted
    do {
        let queue = JobQueue(completionQueue: callbacks)
        let log = Log()
        for index in 0..<20 {
            queue.submit(title: "job \(index)") { _ in
                log.enter()
                log.add("start \(index)")
                Thread.sleep(forTimeInterval: 0.002)
                log.add("end \(index)")
                log.leave()
                return nil
            }
        }
        T.check(queue.waitUntilSettled(), "twenty jobs settle")
        T.equal(log.maxRunning, 1, "never more than one job at a time")
        let expected = (0..<20).flatMap { ["start \($0)", "end \($0)"] }
        T.equal(log.all, expected, "each job finishes before the next starts, in submission order")
        T.check(queue.isIdle, "an empty queue is idle")
    }

    // outcomes
    do {
        let queue = JobQueue(completionQueue: callbacks)
        let log = Log()
        queue.submit(title: "ok", work: { _ in "Created “a.zip”" }, completion: { outcome in
            if case .succeeded(let message) = outcome { log.add("ok:\(message ?? "nil")") } else { log.add("ok:wrong") }
        })
        queue.submit(title: "quiet", work: { _ in nil }, completion: { outcome in
            if case .succeeded(let message) = outcome { log.add("quiet:\(message ?? "nil")") } else { log.add("quiet:wrong") }
        })
        queue.submit(title: "bad", work: { _ in throw Boom() }, completion: { outcome in
            if case .failed(let error) = outcome { log.add("bad:\(error.localizedDescription)") } else { log.add("bad:wrong") }
        })
        queue.submit(title: "stopped", work: { _ in throw JobCancelled() }, completion: { outcome in
            if case .cancelled = outcome { log.add("stopped:cancelled") } else { log.add("stopped:wrong") }
        })
        T.check(queue.waitUntilSettled(), "mixed outcomes settle")
        T.equal(
            log.all,
            ["ok:Created “a.zip”", "quiet:nil", "bad:boom", "stopped:cancelled"],
            "success carries its message, failure its error, a thrown JobCancelled reads as cancelled"
        )
    }

    // a failing job does not stop the ones behind it
    do {
        let queue = JobQueue(completionQueue: callbacks)
        let log = Log()
        queue.submit(title: "first") { _ in throw Boom() }
        queue.submit(title: "second") { _ in log.add("second ran"); return nil }
        T.check(queue.waitUntilSettled(), "queue settles after a failure")
        T.equal(log.all, ["second ran"], "the job after a failed one still runs")
    }

    // cancelling a queued job: it never runs, and its completion hears about it
    do {
        let queue = JobQueue(completionQueue: callbacks)
        let log = Log()
        let gate = DispatchSemaphore(value: 0)
        queue.submit(title: "blocker") { _ in gate.wait(); log.add("blocker done"); return nil }
        let victim = queue.submit(title: "victim", work: { _ in log.add("victim ran"); return nil }, completion: { outcome in
            if case .cancelled = outcome { log.add("victim cancelled") }
        })
        let after = queue.submit(title: "after") { _ in log.add("after ran"); return nil }
        T.equal(queue.snapshot().count, 3, "all three are visible while queued")
        queue.cancel(victim)
        T.equal(queue.snapshot().count, 2, "a cancelled queued job leaves the list at once")
        T.check(!queue.snapshot().contains { $0.id == victim }, "and it is the right one that left")
        _ = after
        gate.signal()
        T.check(queue.waitUntilSettled(), "queue settles")
        T.check(!log.all.contains("victim ran"), "a job cancelled before it started never runs")
        T.check(log.all.contains("victim cancelled"), "its completion reports cancelled")
        T.check(log.all.contains("after ran"), "the job behind it still runs")
    }

    // cancelling a running job: it sees the flag at its next check
    do {
        let queue = JobQueue(completionQueue: callbacks)
        let log = Log()
        let started = DispatchSemaphore(value: 0)
        let id = queue.submit(title: "long", work: { context in
            started.signal()
            for _ in 0..<2_000 {
                try context.checkCancelled()
                Thread.sleep(forTimeInterval: 0.005)
            }
            log.add("ran to the end")
            return nil
        }, completion: { outcome in
            if case .cancelled = outcome { log.add("cancelled") } else { log.add("not cancelled") }
        })
        T.check(started.wait(timeout: .now() + 5) == .success, "the long job starts")
        T.equal(queue.snapshot().first?.state, .running, "a started job reads as running")
        queue.cancel(id)
        T.check(queue.waitUntilSettled(), "queue settles after cancelling the running job")
        T.equal(log.all, ["cancelled"], "a running job stops at its next check and reports cancelled")
    }

    // a running job that finishes before it notices the cancel is a success
    do {
        let queue = JobQueue(completionQueue: callbacks)
        let log = Log()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let id = queue.submit(title: "oblivious", work: { _ in
            started.signal()
            release.wait()
            return "done anyway"
        }, completion: { outcome in
            if case .succeeded(let message) = outcome { log.add("succeeded:\(message ?? "")") } else { log.add("other") }
        })
        _ = started.wait(timeout: .now() + 5)
        queue.cancel(id)
        release.signal()
        T.check(queue.waitUntilSettled(), "settles")
        T.equal(log.all, ["succeeded:done anyway"], "work that was already finished is reported as done, not cancelled")
    }

    // cancelling something that is gone is harmless
    do {
        let queue = JobQueue(completionQueue: callbacks)
        queue.cancel(UUID())
        let id = queue.submit(title: "quick") { _ in nil }
        T.check(queue.waitUntilSettled(), "settles")
        queue.cancel(id)
        T.check(queue.isIdle, "cancelling a finished job changes nothing")
    }

    // cancel all, by scope
    do {
        let queue = JobQueue(completionQueue: callbacks)
        let log = Log()
        let gate = DispatchSemaphore(value: 0)
        queue.submit(title: "hold", scope: "A") { _ in gate.wait(); return nil }
        queue.submit(title: "a2", scope: "A", work: { _ in log.add("a2 ran"); return nil })
        queue.submit(title: "b1", scope: "B", work: { _ in log.add("b1 ran"); return nil })
        T.check(queue.hasWork(scope: "A"), "scope A has work")
        T.check(queue.hasWork(scope: "B"), "scope B has work")
        T.check(!queue.hasWork(scope: "C"), "scope C has none")
        queue.cancelAll(scope: "B")
        T.check(!queue.hasWork(scope: "B"), "cancelling B clears B")
        T.check(queue.hasWork(scope: "A"), "and leaves A")
        gate.signal()
        T.check(queue.waitUntilSettled(), "settles")
        T.equal(log.all, ["a2 ran"], "only the cancelled scope's jobs were dropped")
    }

    // progress is visible while a job runs
    do {
        let queue = JobQueue(completionQueue: callbacks)
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.submit(title: "copying", kind: .heavy, scope: "app") { context in
            context.meter.setTotals(bytes: 1_000)
            context.meter.add(bytes: 250)
            context.meter.setDetail("big.bin")
            reached.signal()
            release.wait()
            return nil
        }
        T.check(reached.wait(timeout: .now() + 5) == .success, "the job reports progress")
        let info = queue.snapshot().first
        T.equal(info?.title ?? "", "copying", "the title is carried")
        T.equal(info?.scope ?? "", "app", "the scope is carried")
        T.equal(info?.kind, .heavy, "the kind is carried")
        T.equal(info?.progress.bytesDone ?? -1, 250, "bytes done are visible")
        T.equal(info?.progress.detail ?? "", "big.bin", "the file being worked on is visible")
        T.check(abs((info?.progress.fraction ?? -1) - 0.25) < 0.0001, "the fraction is visible")
        release.signal()
        T.check(queue.waitUntilSettled(), "settles")
    }

    // a job may submit another from its completion
    do {
        let queue = JobQueue(completionQueue: callbacks)
        let log = Log()
        queue.submit(title: "first", work: { _ in log.add("first"); return nil }, completion: { _ in
            queue.submit(title: "second") { _ in log.add("second"); return nil }
        })
        // The second job is entered into the group before the first one's completion leaves it, so
        // settling cannot slip through the gap between them.
        T.check(queue.waitUntilSettled(), "settles")
        T.equal(log.all, ["first", "second"], "a follow-up queued from a completion runs after it")
    }

    // state changes are announced, without a flood
    do {
        let counter = Log()
        let queue = JobQueue(completionQueue: callbacks, onChange: { counter.add("change") })
        queue.submit(title: "one") { context in
            for _ in 0..<500 { context.meter.add(bytes: 1) }
            return nil
        }
        T.check(queue.waitUntilSettled(), "settles")
        Thread.sleep(forTimeInterval: 0.05)
        let changes = counter.all.count
        T.check(changes >= 3, "submit, start and finish are announced (saw \(changes))")
        T.check(changes <= 6, "bytes of progress are not announced one by one (saw \(changes))")
    }

    // many jobs, none lost and none repeated
    do {
        let queue = JobQueue(completionQueue: callbacks)
        let log = Log()
        let group = DispatchGroup()
        for thread in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                for index in 0..<50 {
                    queue.submit(title: "t\(thread)-\(index)") { _ in log.add("t\(thread)-\(index)"); return nil }
                }
                group.leave()
            }
        }
        group.wait()
        T.check(queue.waitUntilSettled(timeout: 20), "200 jobs from four threads settle")
        T.equal(log.all.count, 200, "every job ran")
        T.equal(Set(log.all).count, 200, "none ran twice")
        for thread in 0..<4 {
            let mine = log.all.filter { $0.hasPrefix("t\(thread)-") }.compactMap { Int($0.dropFirst("t\(thread)-".count)) }
            T.equal(mine, Array(0..<50), "thread \(thread)'s jobs ran in the order it submitted them")
        }
    }
}
