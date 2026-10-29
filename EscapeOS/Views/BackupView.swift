import SwiftUI

/// Backup progress controller used from the per-app detail screen.
///
/// The backup runs as a job on `OperationCenter`, so it waits its turn behind other long operations,
/// shows a percentage, speed and time left in the bar, and can be cancelled from there or here.
final class BackupViewModel: ObservableObject {
    enum State {
        case idle
        case running(files: Int, bytes: Int64, current: String)
        case done(BackupResult)
        case failed(String)
    }

    @Published var state: State = .idle

    private let service = BackupService()
    private var jobID: UUID?

    var isBusy: Bool {
        if case .running = state { return true }
        return false
    }

    func start(app: InstalledApp, onFinished: (() -> Void)? = nil) {
        guard !isBusy else { return }
        state = .running(files: 0, bytes: 0, current: "Waiting…")
        let result = Box<BackupResult>()
        jobID = OperationCenter.shared.submit(
            "Backing up \(app.name)",
            kind: .heavy,
            scope: app.containerPath,
            work: { context in
                DispatchQueue.main.async { self.state = .running(files: 0, bytes: 0, current: "Starting…") }
                do {
                    result.value = try self.service.exportBackup(
                        for: app,
                        estimate: { context.meter.setTotals(bytes: $0) },
                        bytes: { context.meter.add(bytes: $0) },
                        progress: { files, bytes, current in
                            context.meter.setDetail(current)
                            DispatchQueue.main.async {
                                self.state = .running(files: files, bytes: bytes, current: current)
                            }
                        },
                        isCancelled: { context.isCancelled }
                    )
                } catch BackupError.cancelled {
                    throw JobCancelled()
                }
                return nil
            },
            finish: { outcome in
                self.jobID = nil
                switch outcome {
                case .done:
                    if let value = result.value {
                        self.state = .done(value)
                        onFinished?()
                    } else {
                        self.state = .idle
                    }
                case .failed(let error):
                    self.state = .failed(error.localizedDescription)
                case .cancelled:
                    self.state = .idle
                }
            }
        )
    }

    func cancel() {
        if let jobID { OperationCenter.shared.cancel(jobID) }
    }
}
