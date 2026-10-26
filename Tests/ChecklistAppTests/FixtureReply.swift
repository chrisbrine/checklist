import Foundation

/// A held reply must not send a dictionary still retained by its mutable fixture.
/// The JSON wire round trip gives the continuation an independently owned graph.
func fixtureReply(_ reply: [String: Any]) -> sending [String: Any] {
    let wire = try! JSONSerialization.data(withJSONObject: reply)
    return try! JSONSerialization.jsonObject(with: wire) as! [String: Any]
}
