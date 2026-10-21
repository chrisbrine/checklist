import Foundation

/// One retained event page; its cursor belongs to one store observation.
struct SelectedEventHistory {
    struct Request {fileprivate let token: UUID;fileprivate let store: RecordIdentity;let cursor: String?}
    private(set) var records: [Record]?
    private(set) var nextCursor: String?
    private(set) var hasMore = false
    private(set) var loading = false
    private(set) var error: String?
    private var store: RecordIdentity?
    private var token: UUID?
    func records(in incarnation: String) -> [Record]? {store == RecordIdentity(incarnation) ? records : nil}
    mutating func observe(store incarnation: String) {
        let incoming = RecordIdentity(incarnation)
        guard store != incoming else {return}
        self = Self();store = incoming
    }
    mutating func begin(store incarnation: String,fresh: Bool = false) -> Request {
        observe(store:incarnation)
        if fresh {records = nil;nextCursor = nil;hasMore = false}
        let id = UUID();token = id;loading = true;error = nil
        return Request(token:id,store:RecordIdentity(incarnation),cursor:nextCursor)
    }
    @discardableResult mutating func receive(_ result: [String:Any],for request: Request,currentStore: String) throws -> Bool {
        guard token == request.token,store == request.store,request.store == RecordIdentity(currentStore) else {return false}
        guard let rows = result["events"] as? [[String:Any]],rows.count <= 50,rows.allSatisfy({($0["id"] as? String)?.isEmpty == false}),
              let more = result["has_more"] as? Bool,let cursor = result["next_cursor"] as? String,!cursor.isEmpty else {throw TicketPageError.invalid("selected_history")}
        records = rows.map(Record.init);hasMore = more;nextCursor = cursor;loading = false;token = nil;error = nil
        return true
    }
    mutating func fail(_ request: Request,resetCursor: Bool) {
        guard token == request.token,store == request.store else {return}
        loading = false;token = nil
        if resetCursor {
            records = nil;nextCursor = nil;hasMore = false
            error = "This history page is out of date. Restart the ticket history to read it again."
        } else {error = "Could not load this event page. Retry or restart ticket history."}
    }
    mutating func cancel() {token = nil;loading = false}
}
