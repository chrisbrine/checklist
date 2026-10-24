import XCTest
@testable import ChecklistApp

final class ConversationAccessTests: XCTestCase {
    func session(_ extra: [String:Any] = [:]) -> Record {
        Record(values:["id":"session-123456","project_id":"project","role":"worker","provider":"codex","state":"connected","installation":"auto-codex/generation","revision":7,"native_conversation_title":"Synthetic conversation"].merging(extra) { _,new in new })
    }
    func testActionsFollowOwnerRevocationAndPendingNativeReconnect() {
        XCTAssertEqual(ConversationAccessAction.available(for:session()),.disconnect)
        XCTAssertEqual(ConversationAccessAction.available(for:session(["state":"revoked","owner_revoked":true])),.allowAgain)
        XCTAssertEqual(ConversationAccessAction.available(for:session(["state":"ended","owner_revoked":true])),.allowAgain)
        XCTAssertEqual(ConversationAccessAction.available(for:session(["state":"revoked","owner_reconnect_allowed":true])),.disconnect)
        for value in [session(["state":"ended"]),session(["role":"assistant"]),session(["installation":""]),session(["provider":"manual"])] {
            XCTAssertNil(ConversationAccessAction.available(for:value))
        }
    }
    func testDisconnectConfirmationNamesExactConversationAndClaimsWithSafeDefault() {
        var sent = false
        let confirmation = ConversationAccessAction.disconnect.confirmation(session()) { sent = true }
        XCTAssertTrue(confirmation.title.contains("Synthetic conversation")); XCTAssertTrue(confirmation.title.contains("session-"))
        XCTAssertTrue(confirmation.effect.contains("Queued")); XCTAssertTrue(confirmation.effect.contains("reservations"))
        XCTAssertTrue(confirmation.effect.contains("Allow again")); XCTAssertTrue(confirmation.cancelIsDefault)
        XCTAssertEqual(confirmation.confirmLabel,"Disconnect"); XCTAssertFalse(sent)
        let untitled = ConversationAccessAction.disconnect.confirmation(session(["native_conversation_title":"","label":"Codex thread actual"])) {}
        XCTAssertTrue(untitled.title.contains("Codex thread actual"),"Empty projected native titles must fall back to the actual conversation label")
        confirmation.respond(confirmed:false); XCTAssertFalse(sent)
        confirmation.respond(confirmed:true); XCTAssertTrue(sent)
    }
    func testAllowAgainExplainsFreshAccessWithoutClaimOrMessageRevival() {
        let action = ConversationAccessAction.allowAgain
        let confirmation = action.confirmation(session(["owner_revoked":true])) {}
        XCTAssertEqual(confirmation.confirmLabel,"Allow again"); XCTAssertTrue(confirmation.cancelIsDefault)
        XCTAssertTrue(confirmation.effect.contains("claim work again")); XCTAssertTrue(confirmation.effect.contains("queued messages stay fenced"))
        XCTAssertEqual(action.method,"connection_allow")
        XCTAssertEqual(ConversationAccessAction.disconnect.method,"connection_revoke")
    }
    func testOwnerCommandTargetsTheCapturedSessionGenerationAndRevision() {
        let params = ConversationAccessAction.disconnect.parameters(session(),task:Record(values:["id":"ticket","project_id":"project"]))
        XCTAssertEqual(params["task_id"] as? String,"ticket")
        XCTAssertEqual(params["session_id"] as? String,"session-123456")
        XCTAssertEqual(params["project_id"] as? String,"project")
        XCTAssertEqual(params["installation"] as? String,"auto-codex/generation")
        XCTAssertEqual(params["expected_revision"] as? Int,7)
    }
}
