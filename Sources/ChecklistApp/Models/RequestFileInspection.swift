import Foundation
import Combine

/// Captures only the form/selection being inspected, never question answer text.
struct RequestFileInspectionScope: Equatable {
    struct Selection: Equatable {
        let fileID: Data
        let paths: [Data]
    }
    let identity: [Data]
    let revisions: [Int]
    let selections: [Selection]
    let paths: [String]
    init(request: Record, draft: AnswerDraft, fileRequests: [Record], storeIncarnation: String) {
        identity = [request.string("project_id"), request.id, RequestDraftIdentity.form(request), draft.targetIdentity, storeIncarnation].map { Data($0.utf8) }
        revisions = [request.integer("revision"), request.integer("form_revision"), draft.formRevision]
        selections = fileRequests.map { Selection(fileID: Data($0.id.utf8), paths: (draft.paths[$0.id] ?? []).map { Data($0.utf8) }) }
        paths = fileRequests.flatMap { draft.paths[$0.id] ?? [] }
    }
    static func == (left: Self, right: Self) -> Bool {
        left.identity == right.identity && left.revisions == right.revisions && left.selections == right.selections
    }
}

/// Both queued progress and completion must retain this exact generation/scope.
struct RequestFileInspectionGate {
    struct Ticket: Equatable { let id = UUID(); let scope: RequestFileInspectionScope }
    private(set) var current: Ticket?
    mutating func begin(_ scope: RequestFileInspectionScope) -> Ticket {
        let ticket = Ticket(scope: scope); current = ticket; return ticket
    }
    mutating func cancel() { current = nil }
    func accepts(_ ticket: Ticket, currentScope: RequestFileInspectionScope) -> Bool {
        current == ticket && ticket.scope == currentScope
    }
}

private final class RequestFileCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    func cancel() { lock.lock(); canceled = true; lock.unlock() }
    var isCanceled: Bool { lock.lock(); defer { lock.unlock() }; return canceled }
}

@MainActor
final class RequestFileInspector: ObservableObject {
    typealias Worker = ([String], [String: String], @escaping () -> Bool, @escaping (RequestFileHashProgress) -> Void) -> RequestFileInspectionResult?
    @Published private(set) var progress: RequestFileHashProgress?
    private let worker: Worker
    private let queue = DispatchQueue(label: "org.checklist.request-file-hashing", qos: .userInitiated)
    private var gate = RequestFileInspectionGate()
    private var cancellation: RequestFileCancellation?
    private var checkedScope: RequestFileInspectionScope?
    init(worker: @escaping Worker = { paths, hashes, canceled, progress in
        RequestDraftIdentity.inspectFiles(paths: paths, expectedHashes: hashes, isCanceled: canceled, progress: progress)
    }) { self.worker = worker }
    var isChecking: Bool { progress != nil }
    func ready(for scope: RequestFileInspectionScope) -> Bool { checkedScope == scope && !isChecking }

    func cancel() {
        cancellation?.cancel(); cancellation = nil
        gate.cancel(); checkedScope = nil; progress = nil
    }
    func inspect(scope: RequestFileInspectionScope, expectedHashes: [String: String], force: Bool = false, completion: @escaping (RequestFileInspectionScope, RequestFileInspectionResult) -> Void) {
        if !force, gate.current?.scope == scope || checkedScope == scope { return }
        cancel()
        let ticket = gate.begin(scope), stop = RequestFileCancellation()
        cancellation = stop
        progress = RequestFileHashProgress(completedFiles: 0, totalFiles: scope.paths.count, bytesRead: 0, fileSize: 0)
        let work = worker
        queue.async { [weak self] in
            let result = work(scope.paths, expectedHashes, { stop.isCanceled }) { update in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.gate.accepts(ticket, currentScope: scope), !stop.isCanceled else { return }
                    self.progress = update
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let result, self.gate.accepts(ticket, currentScope: scope), !stop.isCanceled else { return }
                self.checkedScope = scope; self.progress = nil; self.cancellation = nil
                completion(scope, result)
            }
        }
    }
    deinit { cancellation?.cancel() }
}
