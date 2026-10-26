import XCTest
import Combine
import Observation
@testable import ChecklistApp

final class WorkspaceObservationTests: XCTestCase {
    @MainActor func testTypingDoesNotPublishTheGlobalStoreOrUnrelatedCatalog() throws {
        let parent = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first!.appendingPathComponent("ChecklistSyntheticTests")
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let root = parent.appendingPathComponent("observation-"+UUID().uuidString)
        let preferences = isolatedDefaults("Observation").preferences
        defer {try? FileManager.default.removeItem(at:root)}
        preferences.set(Page.needsYou.rawValue,forKey:"lastPage")
        let journal = LocalDraftJournal(directory:root)
        let alerts = ObservationDesktopAlertSink()
        let store = ChecklistStore(draftJournal:journal,preferences:preferences,restorePendingCommand:false,desktopAlerts:DesktopAlertCoordinator(sink:alerts))
        var global = 0
        let unrelated = ObservationCounter(),search = ObservationCounter(),note = ObservationCounter()
        let token = store.objectWillChange.sink {global += 1};defer {token.cancel()}
        withObservationTracking({_ = store.projects;_ = store.needsCount},onChange:{unrelated.increment()})
        withObservationTracking({_ = store.search},onChange:{search.increment()})
        withObservationTracking({_ = store.noteDrafts["ticket"]},onChange:{note.increment()})
        store.search = "local query"
        store.saveNote("ticket",text:"durable local edit")
        XCTAssertEqual(alerts.calls,0,"Local typing must not invoke a system notification boundary")
        XCTAssertEqual(global,0,"Typing must not broadcast objectWillChange to every Store consumer")
        XCTAssertEqual(unrelated.value,0,"Unchanged project/sidebar data must not observe filter/draft writes")
        XCTAssertEqual(search.value,1);XCTAssertEqual(note.value,1)
        XCTAssertEqual(preferences.dictionary(forKey:"taskFilters:overview")?["search"] as? String,"local query")
        let recovered = try journal.recover(StoredNoteDraft.self,kind:"note")
        XCTAssertEqual(recovered.values["ticket"]?.text,"durable local edit")
    }
    func testRenderedRowEqualityKeepsIdentityAndVisibleChanges() {
        var raw: [String:Any] = ["id":"é","title":"Title","key":"T-1","kind":"work","status_category":"queued","updated_at":"2026-01-01T00:00:00Z","revision":1]
        func value(_ row: [String:Any],selected: Bool = false,project: String? = "Project",age: String = "now") -> TaskRowPresentation {
            TaskRowPresentation(task:Record(values:row),selected:selected,projectName:project,age:age)
        }
        let baseline = value(raw)
        raw["revision"] = 2;raw["unrelated_history"] = ["new event"]
        XCTAssertEqual(value(raw),baseline,"Hidden history changes do not invalidate a visual label")
        raw["id"] = "e\u{301}";XCTAssertNotEqual(value(raw),baseline,"Opaque row identity is byte-exact")
        raw["id"] = "é";raw["title"] = "Changed";XCTAssertNotEqual(value(raw),baseline)
        raw["title"] = "Title"
        XCTAssertNotEqual(value(raw,selected:true),baseline);XCTAssertNotEqual(value(raw,project:"Other"),baseline)
        XCTAssertNotEqual(value(raw,age:"a minute ago"),baseline)
    }
}

@MainActor private final class ObservationDesktopAlertSink: DesktopAlertSink {
    private(set) var calls = 0
    func authorization() async -> DesktopAlertAuthorization { calls += 1;return .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { calls += 1;return false }
    func send(_ alert: DesktopAlert) async throws { calls += 1;throw NSError(domain:"UnexpectedTestNotification",code:1) }
    func remove(_ identifiers: [String]) { calls += 1 }
}

private final class ObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock();defer {lock.unlock()};count += 1 }
    var value: Int { lock.lock();defer {lock.unlock()};return count }
}
