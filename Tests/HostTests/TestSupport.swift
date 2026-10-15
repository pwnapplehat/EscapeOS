import Foundation

/// Minimal assertion harness so the host tests need nothing beyond the Swift toolchain.
/// Results are tallied and `finish()` sets the process exit code.
enum T {
    private(set) static var passed = 0
    private(set) static var failed = 0

    static func check(_ condition: @autoclosure () -> Bool, _ name: String, file: String = #fileID, line: Int = #line) {
        if condition() {
            passed += 1
        } else {
            failed += 1
            print("FAIL: \(name)  (\(file):\(line))")
        }
    }

    static func equal<V: Equatable>(_ actual: V, _ expected: V, _ name: String, file: String = #fileID, line: Int = #line) {
        if actual == expected {
            passed += 1
        } else {
            failed += 1
            print("FAIL: \(name)  got \(actual), expected \(expected)  (\(file):\(line))")
        }
    }

    static func section(_ title: String) { print("-- \(title)") }

    static func finish() -> Never {
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
