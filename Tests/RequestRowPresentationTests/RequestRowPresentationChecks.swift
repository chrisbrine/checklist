import Foundation

@main struct RequestRowPresentationChecks {
    static var checks = 0
    static func expect(_ result: @autoclosure () -> Bool,_ message: String) throws {
        checks += 1
        if !result() { throw NSError(domain:"RequestRowPresentationChecks",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    static func request(_ id: String,_ created: String,_ blocking: Bool = false,_ extra: [String:Any] = [:]) -> Record {
        var value: [String:Any] = ["id":id,"project_id":"p","task_id":"t","created_at":created,"blocking":blocking]
        for (key,item) in extra { value[key] = item }
        return Record(values:value)
    }
    static func main() throws {
        let oldest = request("n-old","2026-10-01T12:00:00Z"), newest = request("b-new","2026-10-17T12:00:00Z",true)
        let olderBlocking = request("b-old","2026-10-16T12:00:00Z",true), unknownBlocking = request("b-unknown","invalid",true)
        let rows = [newest,oldest,unknownBlocking,olderBlocking]
        try expect(RequestRowPresentation.ordered(rows).map(\.id) == ["b-old","b-new","b-unknown","n-old"],"Blocking-first then oldest-first order is wrong")
        try expect(rows.map(\.id) == ["b-new","n-old","b-unknown","b-old"],"Presentation sorting mutated the source list")
        let ties = [request("z","2026-10-17T12:00:00+00:00"),request("a","2026-10-17T05:00:00-07:00")]
        try expect(RequestRowPresentation.ordered(ties).map(\.id) == ["a","z"],"Equal instants lack a stable tie-break")
        let fractional = [request("later","2026-10-17T12:00:00.900Z"),request("earlier","2026-10-17T12:00:00.100Z")]
        try expect(RequestRowPresentation.ordered(fractional).map(\.id) == ["earlier","later"],"Fractional creation times were ignored")
        try expect(RequestRowPresentation.ordered([request("bad",""),oldest]).map(\.id) == ["n-old","bad"],"Unknown age displaced a known older request")

        let now = ISO8601DateFormatter().date(from:"2026-10-17T12:00:00Z")!
        try expect(RequestRowPresentation.age(request("r","2026-10-17T11:59:31.500Z"),now:now) == "Age: <1m","Young age should be readable")
        try expect(RequestRowPresentation.age(request("r","2026-10-17T11:49:00Z"),now:now) == "Age: 11m","Minute age is incorrect")
        try expect(RequestRowPresentation.age(request("r","2026-10-17T09:15:00Z"),now:now) == "Age: 2h","Hour age is incorrect")
        try expect(RequestRowPresentation.age(request("r","2026-10-15T10:15:00Z"),now:now) == "Age: 2d","Day age is incorrect")
        try expect(RequestRowPresentation.age(request("r","2026-10-18T12:00:00Z"),now:now) == "Age: <1m","Clock skew produced a negative age")
        try expect(RequestRowPresentation.age(request("r","not a timestamp"),now:now) == "Age unavailable","An unknown creation time was invented")

        let mixed = request("mixed","",true,["questions":[["type":"choice"],["type":"text"],["type":"check"],["type":"choice"],["type":"approval"]],"file_requests":[["kind":"directory"]]])
        try expect(RequestRowPresentation.capabilities(mixed).map(\.rawValue) == ["Choice","Text","File","Check","Approval"],"Mixed capabilities are missing or duplicated")
        let custom = request("custom","",false,["questions":[["type":"choice","allow_custom":true]]])
        try expect(RequestRowPresentation.capabilities(custom).map(\.rawValue) == ["Choice","Text"],"Custom-text choice capability is missing")
        let defaultText = request("text","",false,["questions":[["id":"q","prompt":"What changed?"]]])
        try expect(RequestRowPresentation.capabilities(defaultText) == [.text],"Default text question lost its capability")
        let fileOnly = request("file","",false,["file_requests":[["id":"f","kind":"either"]],"target_attachment_id":"candidate"])
        try expect(RequestRowPresentation.capabilities(fileOnly) == [.file],"A requested file was confused with an approval target")
        let topCommand = request("top-command","",false,["questions":[["type":"text"]],"command":["text":"Inspect the synthetic build"]])
        try expect(RequestRowPresentation.capabilities(topCommand) == [.text,.check],"A request-level manual check is hidden")
        let nestedCommand = request("nested-command","",false,["questions":[["type":"choice","command":["text":"Inspect this result"]]]])
        try expect(RequestRowPresentation.capabilities(nestedCommand) == [.choice,.check],"A question-level manual check is hidden")
        try expect(RequestRowPresentation.capabilities(request("empty-command","",false,["command":["text":"   "]])).isEmpty,"An empty command fabricated a check")
        try expect(RequestRowPresentation.capabilities(request("unknown","",false,["questions":[["type":"future_unknown"]]])).isEmpty,"Unknown schema invented answer capabilities")
        let legacyChoice = request("legacy","",false,["questions":[["type":"single_choice"],["type":"multiple_choice"]]])
        try expect(RequestRowPresentation.capabilities(legacyChoice) == [.choice],"Already-supported legacy choices lost their capability")

        let task = Record(values:["id":"t","project_id":"p","key":"KEY-9"])
        try expect(RequestRowPresentation.ticketLabel(mixed,task:task) == "Blocks: KEY-9","Blocking request does not identify its ticket")
        try expect(RequestRowPresentation.ticketLabel(custom,task:task) == "Related: KEY-9","A nonblocking request falsely claims to block the ticket")
        try expect(RequestRowPresentation.ticketLabel(mixed,task:nil) == "Blocks: ticket unavailable","A missing ticket key was invented")
        try expect(RequestRowPresentation.ticketLabel(mixed,task:Record(values:["id":"t","project_id":"other","key":"KEY-9"])) == "Blocks: ticket unavailable","A duplicate key in another project leaked into the row")
        try expect(RequestRowPresentation.ticketLabel(mixed,task:Record(values:["id":"other","project_id":"p","key":"KEY-9"])) == "Blocks: ticket unavailable","The row used a different ticket with the same key")
        print("Request row checks passed: \(checks). Presentation only; no service or UI mutation.")
    }
}
