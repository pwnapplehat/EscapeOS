import Foundation

/// A clock the tests move by hand, so speed and time-left arithmetic is exact.
final class FakeClock {
    var now: TimeInterval = 1_000
    func tick(_ seconds: TimeInterval) { now += seconds }
}

private func close(_ value: Double?, to expected: Double, within tolerance: Double) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
}

func runProgressMeterTests() {
    T.section("ProgressMeter")
    let mb: Int64 = 1_000_000

    // a fresh meter says nothing it cannot know
    do {
        let clock = FakeClock()
        let meter = ProgressMeter(clock: { clock.now })
        let s = meter.snapshot()
        T.check(s.fraction == nil, "no total, no fraction")
        T.check(s.bytesPerSecond == nil, "no bytes, no speed")
        T.check(s.secondsRemaining == nil, "no total, no time left")
        T.check(!s.isDeterminate, "a fresh meter is indeterminate")
        T.check(ProgressFormat.line(for: s) == nil, "nothing known, nothing to print")
    }

    // fraction comes from bytes when the byte total is known, and is clamped
    do {
        let clock = FakeClock()
        let meter = ProgressMeter(clock: { clock.now })
        meter.setTotals(bytes: 200 * mb)
        meter.add(bytes: 50 * mb)
        T.check(close(meter.snapshot().fraction, to: 0.25, within: 0.0001), "a quarter of the bytes is a quarter")
        meter.add(bytes: 400 * mb)
        T.equal(meter.snapshot().fraction ?? -1, 1.0, "more than the estimate clamps to 100%")
        let negative = ProgressMeter(clock: { clock.now })
        negative.setTotals(bytes: -5)
        T.check(negative.snapshot().fraction == nil, "a negative total is not a total")
        let zero = ProgressMeter(clock: { clock.now })
        zero.setTotals(bytes: 0)
        T.check(zero.snapshot().fraction == nil, "a zero total gives no fraction rather than dividing by it")
    }

    // fraction falls back to items, and bytes win when both are known
    do {
        let clock = FakeClock()
        let items = ProgressMeter(clock: { clock.now })
        items.setTotals(items: 340)
        for _ in 0..<85 { items.completeItem() }
        T.check(close(items.snapshot().fraction, to: 0.25, within: 0.0001), "85 of 340 files is a quarter")
        T.equal(items.snapshot().itemsDone, 85, "items done are counted")

        let both = ProgressMeter(clock: { clock.now })
        both.setTotals(bytes: 100 * mb, items: 10)
        both.add(bytes: 10 * mb)
        for _ in 0..<9 { both.completeItem() }
        T.check(close(both.snapshot().fraction, to: 0.10, within: 0.0001), "bytes win over items when both are known")

        let jump = ProgressMeter(clock: { clock.now })
        jump.setTotals(items: 10)
        jump.setItems(done: 4, detail: "a.txt")
        T.equal(jump.snapshot().itemsDone, 4, "items can be set outright")
        T.equal(jump.snapshot().detail ?? "", "a.txt", "the current file is carried along")
        jump.setDetail(nil)
        T.check(jump.snapshot().detail == nil, "the detail can be cleared")
    }

    // speed over a steady stretch
    do {
        let clock = FakeClock()
        let meter = ProgressMeter(clock: { clock.now })
        clock.tick(0.5)
        meter.add(bytes: mb)
        T.check(meter.snapshot().bytesPerSecond == nil, "half a second is too little to call a speed")
        for _ in 0..<5 {
            clock.tick(0.5)
            meter.add(bytes: mb)
        }
        T.check(close(meter.snapshot().bytesPerSecond, to: 2_000_000, within: 20_000), "1 MB every half second is 2 MB/s")
    }

    // no bytes moved, no speed (including a long stall)
    do {
        let clock = FakeClock()
        let meter = ProgressMeter(clock: { clock.now })
        clock.tick(3)
        T.check(meter.snapshot().bytesPerSecond == nil, "time passing with no bytes is not a speed")
        for _ in 0..<6 {
            clock.tick(0.5)
            meter.add(bytes: mb)
        }
        T.check(meter.snapshot().bytesPerSecond != nil, "bytes arriving give a speed")
        clock.tick(10)
        T.check(meter.snapshot().bytesPerSecond == nil, "a stall longer than the window reads as no speed, not the old one")
    }

    // the window slides: a fast start does not keep a slow finish looking fast
    do {
        let clock = FakeClock()
        let meter = ProgressMeter(clock: { clock.now })
        for _ in 0..<10 { clock.tick(0.5); meter.add(bytes: 5 * mb) }   // 10 MB/s for 5 s
        T.check(close(meter.snapshot().bytesPerSecond, to: 10_000_000, within: 100_000), "first stretch is 10 MB/s")
        for _ in 0..<10 { clock.tick(0.5); meter.add(bytes: mb / 2) }   // 1 MB/s for 5 s
        T.check(close(meter.snapshot().bytesPerSecond, to: 1_000_000, within: 50_000), "the speed follows the last five seconds")
    }

    // time left
    do {
        let clock = FakeClock()
        let meter = ProgressMeter(clock: { clock.now })
        meter.setTotals(bytes: 100 * mb)
        for _ in 0..<2 { clock.tick(0.5); meter.add(bytes: 5 * mb) }
        T.check(meter.snapshot().secondsRemaining == nil, "no time estimate in the first second")
        for _ in 0..<2 { clock.tick(0.5); meter.add(bytes: 5 * mb) }
        T.check(close(meter.snapshot().secondsRemaining, to: 8, within: 0.2), "80 MB left at 10 MB/s is 8 seconds")

        let unknownTotal = ProgressMeter(clock: { clock.now })
        for _ in 0..<6 { clock.tick(0.5); unknownTotal.add(bytes: mb) }
        T.check(unknownTotal.snapshot().secondsRemaining == nil, "no total, no time left")
        T.check(unknownTotal.snapshot().bytesPerSecond != nil, "but the speed is still known")

        let done = ProgressMeter(clock: { clock.now })
        done.setTotals(bytes: 10 * mb)
        for _ in 0..<6 { clock.tick(0.5); done.add(bytes: 2 * mb) }
        T.check(done.snapshot().secondsRemaining == nil, "nothing left, no time left to report")
    }

    // finishing
    do {
        let clock = FakeClock()
        let meter = ProgressMeter(clock: { clock.now })
        meter.finish()
        let s = meter.snapshot()
        T.equal(s.fraction ?? -1, 1.0, "a finished job reads 100% even with no total")
        T.equal(s.secondsRemaining ?? -1, 0, "a finished job has no time left")
    }

    // adds that mean nothing are ignored
    do {
        let clock = FakeClock()
        let meter = ProgressMeter(clock: { clock.now })
        meter.add(bytes: 0)
        meter.add(bytes: -50)
        T.equal(meter.snapshot().bytesDone, 0, "zero and negative adds change nothing")
        meter.set(bytesDone: 500)
        T.equal(meter.snapshot().bytesDone, 500, "a running total can be set outright")
        meter.set(bytesDone: -3)
        T.equal(meter.snapshot().bytesDone, 0, "a negative running total reads as zero")
    }

    // called from several threads at once
    do {
        let meter = ProgressMeter()
        let group = DispatchGroup()
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<1_000 { meter.add(bytes: 10) }
                group.leave()
            }
        }
        group.wait()
        T.equal(meter.snapshot().bytesDone, 40_000, "concurrent adds are all counted")
    }

    // wording
    T.equal(ProgressFormat.percent(0.425), "42%", "percent rounds down, not up")
    T.equal(ProgressFormat.percent(0.999), "99%", "99.9% is not shown as done")
    T.equal(ProgressFormat.percent(1), "100%", "100%")
    T.equal(ProgressFormat.percent(7), "100%", "over 100% is clamped")
    T.equal(ProgressFormat.percent(-0.2), "0%", "below zero is clamped")
    T.equal(ProgressFormat.timeLeft(3), "a few seconds left", "under 5 seconds is a few seconds")
    T.equal(ProgressFormat.timeLeft(12), "about 15 sec left", "seconds round up to five")
    T.equal(ProgressFormat.timeLeft(58), "about 1 min left", "just under a minute reads as a minute")
    T.equal(ProgressFormat.timeLeft(60), "about 1 min left", "exactly a minute")
    T.equal(ProgressFormat.timeLeft(61), "about 2 min left", "minutes round up")
    T.equal(ProgressFormat.timeLeft(3_600), "about 1 h left", "exactly an hour")
    T.equal(ProgressFormat.timeLeft(3_700), "about 1 h 2 min left", "an hour and a bit")
    T.check(ProgressFormat.speed(2_500_000).hasSuffix("/s"), "speed ends in /s")
    T.check(ProgressFormat.speed(2_500_000).contains("MB"), "2.5 MB/s is shown in MB")

    var line = ProgressSnapshot()
    T.check(ProgressFormat.line(for: line) == nil, "an empty snapshot has no line")
    line.fraction = 0.42
    T.equal(ProgressFormat.line(for: line) ?? "", "42%", "only the percent when that is all there is")
    line.bytesPerSecond = 2_000_000
    line.secondsRemaining = 120
    let full = ProgressFormat.line(for: line) ?? ""
    T.check(full.hasPrefix("42% · "), "percent leads")
    T.check(full.hasSuffix("about 2 min left"), "time left ends it")
    T.check(full.contains("/s"), "speed is in the middle")
    var items = ProgressSnapshot()
    items.itemsTotal = 340
    items.itemsDone = 37
    items.fraction = 37.0 / 340.0
    T.equal(ProgressFormat.line(for: items) ?? "", "10% · 37 of 340 files", "item-counted work says how many files")
    items.bytesTotal = 1_000
    T.check(!(ProgressFormat.line(for: items) ?? "").contains("files"), "byte-counted work does not also count files")
    var finishedLine = ProgressSnapshot()
    finishedLine.fraction = 1
    finishedLine.secondsRemaining = 0
    T.equal(ProgressFormat.line(for: finishedLine) ?? "", "100%", "a finished job does not say '0 sec left'")
}
