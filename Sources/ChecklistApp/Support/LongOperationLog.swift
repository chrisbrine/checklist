import Foundation
import SwiftUI

/// One observation of a long command's durable operation, from its acceptance
/// reply or an `operation_get` reply. It never stands for the command's result.
struct LongOperationReceipt: Equatable {
    let operationID: String
    let commandID: String
    let method: String
    let state: String
    var errorCode: String? = nil
}

struct ObservedLongOperation: Identifiable, Equatable {
    var id: String { operationID }
    let operationID: String
    let commandID: String
    let method: String
    var state: String
    /// Time from sending the command to the first reply that named its operation.
    let acceptedAfter: TimeInterval
    var errorCode: String?

    static let unknownState = "unknown"
    var isTerminal: Bool { state == "succeeded" || state == "failed" }
    var title: String {
        switch method {
        case "backup_create": "Back up all projects"
        case "restore_preview": "Preview backup restore"
        case "restore_create": "Prepare restored copy"
        default: method.replacingOccurrences(of:"_",with:" ").capitalized
        }
    }
    var stateText: String {
        switch state {
        case "queued": "Queued"
        case "running": "Running"
        case "succeeded": "Succeeded"
        case "failed": "Failed" + (errorCode.map {" (\($0))"} ?? "")
        default: "State not known; Checklist stopped reading this operation"
        }
    }
    var acceptedText: String { "Accepted in " + String(format:"%.3f",acceptedAfter) + " s" }
    var summary: String { "\(title): \(stateText). \(acceptedText)." }
}

/// CL-370: `operation_get` is bound to the principal that sent the command, so an
/// agent cannot read an owner's operation. The app shows what it observes instead:
/// checks read this text and borrow no owner identity. Window-local and not saved.
@MainActor final class LongOperationLog: ObservableObject {
    static let limit = 10
    @Published private(set) var operations: [ObservedLongOperation] = []

    func observe(_ receipt: LongOperationReceipt,acceptedAfter: @autoclosure () -> TimeInterval) {
        if let index = operations.firstIndex(where: {$0.operationID == receipt.operationID}) {
            // Replies can cross. A later non-terminal reply cannot undo a final state.
            guard !operations[index].isTerminal,operations[index].state != receipt.state else {return}
            operations[index].state = receipt.state;operations[index].errorCode = receipt.errorCode
            return
        }
        operations.insert(ObservedLongOperation(operationID:receipt.operationID,commandID:receipt.commandID,method:receipt.method,
            state:receipt.state,acceptedAfter:acceptedAfter(),errorCode:receipt.errorCode),at:0)
        if operations.count > Self.limit {operations.removeLast(operations.count - Self.limit)}
    }
    /// The wait ended without a final reply. The service operation may still run.
    func stoppedWatching(_ operationID: String) {
        guard let index = operations.firstIndex(where: {$0.operationID == operationID}),!operations[index].isTerminal else {return}
        operations[index].state = ObservedLongOperation.unknownState
    }
}

struct LongOperationRows: View {
    @ObservedObject var log: LongOperationLog
    var body: some View {
        if log.operations.isEmpty {
            Text("Long operations: none since this window opened.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
        }
        ForEach(log.operations) {operation in
            VStack(alignment:.leading,spacing:Spacing.small) {
                Text(operation.summary).checklistFont(.callout)
                Text("Operation ID \(operation.operationID)").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).textSelection(.enabled)
            }
            .accessibilityElement(children:.contain)
            .accessibilityIdentifier("longOperation-\(operation.operationID)")
        }
    }
}
