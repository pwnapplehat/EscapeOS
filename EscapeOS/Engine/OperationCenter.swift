import Combine
import Foundation
import SwiftUI

/// How a job ended, in the terms a view model needs.
enum OperationResult {
    /// `message` is a short confirmation worth showing ("Created “a.zip”"), if there is one.
    case done(message: String?)
    /// Carries the error itself, so a caller can tell "password needed" from "disk full".
    case failed(Error)
    case cancelled
}

/// The app's one queue of long operations (issue #11), and what the screen shows of it.
///
/// Every heavy file operation (copy, move, compress, extract, share, trash, backup, restore, import)
/// goes through here, so they run one after another rather than fighting over storage, show real
/// progress, and can be cancelled. Quick operations (rename, new folder) are queued the same way, so
/// one can never run in the middle of a heavy job on the same folder, but they only appear on screen
/// if they turn out to be slow.
final class OperationCenter: ObservableObject {
    static let shared = OperationCenter()

    /// A quick job is not shown until it has been going this long, so a rename does not flash a bar.
    static let quickJobGrace: TimeInterval = 0.6

    /// What the bar shows: queued and running jobs, oldest first.
    @Published private(set) var jobs: [JobInfo] = []

    private lazy var queue = JobQueue(completionQueue: .main, onChange: { [weak self] in
        DispatchQueue.main.async { self?.refresh() }
    })
    private var firstSeen: [UUID: Date] = [:]
    private var timer: Timer?

    var runningJob: JobInfo? { jobs.first { $0.state == .running } }
    var waitingJobs: [JobInfo] { jobs.filter { $0.state == .queued } }

    /// Queue a job. `finish` runs on the main queue when it ends, however it ends.
    @discardableResult
    func submit(
        _ title: String,
        kind: JobKind = .heavy,
        scope: String? = nil,
        work: @escaping (JobContext) throws -> String?,
        finish: @escaping (OperationResult) -> Void = { _ in }
    ) -> UUID {
        queue.submit(title: title, kind: kind, scope: scope, work: work, completion: { outcome in
            switch outcome {
            case .succeeded(let message):
                if let message { CopyFeedback.shared.show(message) }
                finish(.done(message: message))
            case .failed(let error):
                finish(.failed(error))
            case .cancelled:
                finish(.cancelled)
            }
        })
    }

    func cancel(_ id: UUID) {
        queue.cancel(id)
    }

    func cancelAll() {
        queue.cancelAll()
    }

    /// True when something for `scope` (an app's container) is queued or running.
    func hasWork(scope: String?) -> Bool {
        queue.hasWork(scope: scope)
    }

    // MARK: - Keeping the screen current

    private func refresh() {
        let all = queue.snapshot()
        let now = Date()
        for job in all where firstSeen[job.id] == nil { firstSeen[job.id] = now }
        let live = Set(all.map(\.id))
        firstSeen = firstSeen.filter { live.contains($0.key) }
        jobs = all.filter { job in
            job.kind == .heavy || now.timeIntervalSince(firstSeen[job.id] ?? now) >= Self.quickJobGrace
        }
        if all.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            // Progress moves between state changes, so the bar is re-read a few times a second while busy.
            let tick = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(tick, forMode: .common)
            timer = tick
        }
    }
}

/// The running job with its progress, over everything else.
struct OperationsBar: View {
    @ObservedObject var center: OperationCenter
    @State private var showQueue = false

    var body: some View {
        if let current = center.runningJob ?? center.waitingJobs.first {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(current.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if center.waitingJobs.count > (current.state == .queued ? 1 : 0) {
                        Button {
                            showQueue = true
                        } label: {
                            Text("+\(center.waitingJobs.count - (current.state == .queued ? 1 : 0)) waiting")
                                .font(.caption.weight(.semibold))
                        }
                        .accessibilityLabel("\(center.waitingJobs.count) more waiting. Show the queue.")
                    }
                    Button {
                        center.cancel(current.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Cancel \(current.title)")
                }
                if let fraction = current.progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack(spacing: 8) {
                    Text(ProgressFormat.line(for: current.progress) ?? (current.state == .queued ? "Waiting…" : "Working…"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let detail = current.progress.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.black.opacity(0.18), radius: 8, y: 2)
            .padding(.horizontal, 12)
            .accessibilityElement(children: .contain)
            .sheet(isPresented: $showQueue) {
                OperationsListView(center: center)
            }
        }
    }
}

/// Everything queued or running, each with its own Cancel.
struct OperationsListView: View {
    @ObservedObject var center: OperationCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if center.jobs.isEmpty {
                    Text("Nothing is running.")
                        .foregroundColor(.secondary)
                }
                ForEach(center.jobs) { job in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.title).font(.body)
                            Text(job.state == .running
                                 ? (ProgressFormat.line(for: job.progress) ?? "Working…")
                                 : "Waiting")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Cancel", role: .destructive) { center.cancel(job.id) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("Operations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !center.jobs.isEmpty {
                        Button("Cancel All", role: .destructive) { center.cancelAll() }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
