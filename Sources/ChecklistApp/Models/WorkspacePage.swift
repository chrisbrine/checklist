import Foundation
import Observation

struct WorkspacePageQuery: Equatable {
    let surface: String
    let project: String?
    var text = ""
    var record = ""
    var archived = false
    var limit = 50
    var since = ""
    static func == (a:Self,b:Self)->Bool {
        a.limit == b.limit && a.since == b.since && a.surface == b.surface && a.project.map(RecordIdentity.init) == b.project.map(RecordIdentity.init) && RecordIdentity(a.text)==RecordIdentity(b.text) && RecordIdentity(a.record)==RecordIdentity(b.record) && a.archived==b.archived
    }
    func parameters(cursor:String? = nil)->[String:Any] {
        var p:[String:Any] = ["surface":surface,"text":text,"record_id":record,"include_archived":archived,"limit":limit]
        p["project_id"] = project;p["cursor"] = cursor
        if !since.isEmpty {p["since"] = since}
        return p
    }
}
struct WorkspacePage {
    let query: WorkspacePageQuery
    var rows: [Record]
    var total: Int
    let needsCount: Int?
    let next: String?
    let previous: String?
    let projects: [Record]
    let service: Record
    let contentCursor: String
    init(_ response:[String:Any],query:WorkspacePageQuery)throws {
        guard let version=response["workspace_version"] as? NSNumber,CFGetTypeID(version) != CFBooleanGetTypeID(),version.doubleValue==1,
              response["surface"] as? String==query.surface,
              let record=response["record_id"] as? String,RecordIdentity(record)==RecordIdentity(query.record),
              let rows=response["rows"] as? [[String:Any]],rows.count<=100,
              let total=response["total"] as? NSNumber,CFGetTypeID(total) != CFBooleanGetTypeID(),total.doubleValue.isFinite,total.doubleValue.rounded(.towardZero)==total.doubleValue,total.doubleValue>=Double(rows.count),total.doubleValue<Double(Int.max),
              let projects=response["projects"] as? [[String:Any]],let service=response["service"] as? [String:Any],
              let store=service["store_incarnation"] as? String,!store.isEmpty,
              let cursor=response["content_cursor"] as? String,!cursor.isEmpty else {throw TicketPageError.invalid("workspace")}
        // Selected ticket history shares this row model but is not a badge-count source.
        if query.surface == "record_history", response["needs_you_count"] == nil { needsCount = nil }
        else {
            guard let needs=response["needs_you_count"] as? NSNumber,CFGetTypeID(needs) != CFBooleanGetTypeID(),needs.doubleValue.isFinite,needs.doubleValue.rounded(.towardZero)==needs.doubleValue,needs.doubleValue>=0,needs.doubleValue<Double(Int.max) else {throw TicketPageError.invalid("workspace.needs_you_count")}
            needsCount = needs.intValue
        }
        let ids=Set(projects.compactMap{$0["id"] as? String}.map(RecordIdentity.init))
        var seen=Set<RecordIdentity>()
        for row in rows {
            guard let id=row["id"] as? String,!id.isEmpty,seen.insert(RecordIdentity(id)).inserted,
                  let pid=row["project_id"] as? String,ids.contains(RecordIdentity(pid)),query.project.map({RecordIdentity($0)==RecordIdentity(pid)}) ?? true else {throw TicketPageError.invalid("workspace.scope")}
        }
        func token(_ key:String)throws->String? {
            if response[key] is NSNull{return nil}
            guard let value=response[key] as? String,!value.isEmpty else {throw TicketPageError.invalid(key)}
            return value
        }
        let next=try token("next_cursor"),previous=try token("previous_cursor")
        guard response["has_more"] as? Bool==(next != nil) else {throw TicketPageError.invalid("workspace.cursor")}
        self.query=query;self.rows=rows.map(Record.init);self.total=total.intValue;self.next=next;self.previous=previous
        self.projects=projects.map(Record.init);self.service=Record(values:service);contentCursor=cursor
    }
}

/// A single page per actual consumer. Starting another query retires its request;
/// late replies cannot install, and older pages are replaced rather than appended.
@MainActor @Observable final class WorkspacePageObservation {
    var page: WorkspacePage?
    private(set) var rows: [Record] = []
    private(set) var retainedRequest: Record?
    private(set) var needsRefresh = false
    var loading=false
    var error:String?
    private(set) var query:WorkspacePageQuery?
    private var generation=UUID()
    var readScope: UUID {generation}
    func begin(_ query:WorkspacePageQuery)->UUID {
        if self.query != query {page=nil;rows=[];retainedRequest=nil;needsRefresh=false}
        self.query=query;generation=UUID();loading=true;error=nil;return generation
    }
    @discardableResult func receive(_ response:[String:Any],query:WorkspacePageQuery,generation:UUID)throws->Bool {
        guard self.generation==generation,self.query==query else{return false}
        var incoming = try WorkspacePage(response,query:query)
        // Keep unchanged row values and publish rows only when their contents or order change.
        // SwiftUI reconciles changed/inserted/removed rows using their stable record identities.
        let existing = Dictionary(uniqueKeysWithValues: rows.map { (RecordIdentity($0.id), $0) })
        incoming.rows = incoming.rows.map { row in
            guard let old = existing[RecordIdentity(row.id)], Self.same([old], [row]) else { return row }
            return old
        }
        if !Self.same(rows, incoming.rows) { rows = incoming.rows }
        if query.surface == "record", let request = incoming.rows.first, request.string("record_type") == "request" {
            retainedRequest = request
        }
        page=incoming;needsRefresh=false;loading=false;return true
    }
    private static func same(_ lhs: [Record], _ rhs: [Record]) -> Bool {
        DisplayValueEquality.records(lhs,rhs)
    }
    func restore(_ page: WorkspacePage) {
        cancel(clear: true)
        query = page.query; self.page = page; rows = page.rows
    }
    /// A known commit retires content without canceling the read that observed it.
    func discardContent() { page = nil; rows = []; retainedRequest = nil; needsRefresh = false }
    /// Coverage retires freshness and reusable caches, not the visible projection.
    /// A different query or authority reset still clears these rows immediately.
    func markNeedsRefresh() { needsRefresh = true }
    func applyAnsweredRequest(_ record: Record) {
        guard var current = page, let index = current.rows.firstIndex(where: {
            RecordIdentity($0.id) == RecordIdentity(record.id) && RecordIdentity($0.string("project_id")) == RecordIdentity(record.string("project_id"))
        }) else { return }
        cancel()
        if current.query.surface == "requests" {
            current.rows.remove(at:index); current.total = max(0,current.total - 1)
        } else if current.query.surface == "record" {
            current.rows[index] = Record(values:current.rows[index].values.merging(record.values) { _,new in new })
        }
        if !Self.same(rows, current.rows) { rows = current.rows }
        if current.query.surface == "record" { retainedRequest = current.rows.first }
        page = current
    }
    func isCurrent(_ generation:UUID)->Bool {self.generation==generation}
    func fail(_ generation:UUID,message:String = "Could not load this page. Refresh to load it again; drafts are kept.") {guard self.generation==generation else{return};loading=false;error=message}
    func cancel(_ generation:UUID) {guard self.generation==generation else{return};cancel()}
    func cancel(clear:Bool=false) {generation=UUID();loading=false;if clear {page=nil;rows=[];retainedRequest=nil;query=nil;error=nil;needsRefresh=false}}
}

// Opaque record IDs are byte-exact; refreshed arrays must not define row identity.
extension Record {
    var workspaceIdentity: RecordIdentity { RecordIdentity(id) }
}
