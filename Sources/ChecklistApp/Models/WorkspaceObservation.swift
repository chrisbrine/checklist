import Foundation
import Observation

/// These owners do not forward objectWillChange to the global Store. SwiftUI
/// tracks the fields each consumer actually reads, including existing bindings.
@MainActor @Observable final class TicketWorkspaceObservation {
    var search = ""
    var statusFilter = "all"
    var tagFilter = "all"
    var filters = TicketListFilters()
    var selectedPersonalViewID: String?
    var personalViews: [PersonalTicketView] = []
    var groupBy = "status"
    var orderBy = "manual"
    var pages = TicketPagePreparation()
    var workspace: PreparedTicketWorkspace?
    var fullPreparation = TicketWorkspacePreparation()
}

@MainActor @Observable final class TicketCatalogObservation {
    var projects: [Record]?
    var statuses: [Record]?
    var tags: [Record]?
    var service: Record?
    var needsCount: Int?
    func install(_ page: TicketPage) {
        if !same(projects,page.projects) { projects = page.projects }
        if !same(statuses,page.statuses) { statuses = page.statuses }
        if !same(tags,page.tags) { tags = page.tags }
        if !same(service.map {[$0]},[page.service]) { service = page.service }
        let count = page.outstandingRequestCount + page.humanTaskCount
        if needsCount != count { needsCount = count }
    }
    /// Filter choices are project-scoped. Restore them with cached ticket rows,
    /// without replaying shared health, owner counts or the project catalog.
    func restoreFilters(_ page: TicketPage) {
        if !same(statuses,page.statuses) { statuses = page.statuses }
        if !same(tags,page.tags) { tags = page.tags }
    }
    /// Workspace totals are global owner counts, independent of row scope, filters and pagination.
    func install(workspace page: WorkspacePage) {
        if !same(projects,page.projects) { projects = page.projects }
        if !same(service.map {[$0]},[page.service]) { service = page.service }
        if let count = page.needsCount, needsCount != count { needsCount = count }
    }
    func clear() { projects = nil;statuses = nil;tags = nil;service = nil;needsCount = nil }
    private func same(_ lhs: [Record]?,_ rhs: [Record]) -> Bool {
        guard let lhs else {return false}
        return DisplayValueEquality.records(lhs,rhs)
    }
}

@MainActor @Observable final class SelectedTicketObservation {
    var display: SelectedTicketDisplay?
    var loading = false
    var error: String?
    var collections: [String:Any] = [:]
    var recordsLoading = false
    var recordsError: String?
    var fullRecordID: RecordIdentity?
    var eligibility = SelectedCompletionEligibility()
}

@MainActor @Observable final class DraftObservation {
    var notes: [String:String] = [:]
    var destinations: [String:String] = [:]
    var answers: [String:AnswerDraft] = [:]
    var edits: [String:TaskEditDraft] = [:]
    var captures: [String:CaptureDraft] = [:]
    var failures: [String:String] = [:]
    var recoveryError: String?
}
