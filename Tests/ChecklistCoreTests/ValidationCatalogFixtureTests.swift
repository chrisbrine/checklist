import Foundation
import XCTest
import ChecklistTestSupport
@testable import ChecklistCore

final class ValidationCatalogFixtureTests: XCTestCase {
    private func withRouter(_ body: (CommandRouter) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("validation-catalog-" + UUID().uuidString)
        // Seed cheaply, then reopen through the unconfigured product initializer.
        let seed = try TestStore.router(root:root)
        try seed.closeStore()
        let router = try CommandRouter(root:root)
        defer {
            try? router.closeStore()
            _ = try? FileManager.default.trashItem(at:root,resultingItemURL:nil)
        }
        try body(router)
    }

    private func outcome(_ router: CommandRouter, _ method: String, _ params: JSON, _ caller: Caller) -> String {
        do { try router.validateInput(method,params,caller); return "accepted" }
        catch let error as CoreError { return error.code + ":" + error.message }
        catch { return String(describing:error) }
    }

    func testProductionDefaultKeepsUncachedValidation() throws {
        try withRouter { router in
            XCTAssertNil(router.fixtureValidationCatalog)
            let worker = Caller(role:"worker",installation:"validation-default",projectIDs:[])
            XCTAssertEqual(outcome(router,"service_info",[:],worker),"accepted")
            XCTAssertTrue(outcome(router,"service_info",["unknown":true],worker).hasPrefix("INVALID_INPUT:"))
            XCTAssertNil(router.fixtureValidationCatalog)
        }
    }

    func testWorkerValidationMatchesRealCatalogForValidAndInvalidInputs() throws {
        try withRouter { router in
            let worker = Caller(role:"worker",installation:"validation-worker",projectIDs:["p"],sessionID:"s",workspace:"/fixture")
            let command = UUID().uuidString
            let cases: [(String, JSON, String)] = [
                ("service_info",[:],"accepted"),
                ("service_info",["unknown":true],"INVALID_INPUT"),
                ("task_get",["project_id":"p","task_id":"t"],"accepted"),
                ("task_get",[:],"INVALID_INPUT"),
                ("task_get",["project_id":12,"task_id":"t"],"INVALID_INPUT"),
                ("task_get",["project_id":"p","task_id":"t","include_completion_eligibility":true],"HUMAN_CHANNEL_REQUIRED"),
                ("task_context",["project_id":"p","task_id":"t","detail_level":"ui"],"HUMAN_CHANNEL_REQUIRED"),
                ("task_create",["project_id":"p","command_id":command,"title":"Fixture"],"accepted"),
                ("task_create",["project_id":"p","command_id":command,"title":"Fixture","epic_id":NSNull()],"accepted"),
                ("task_create",["project_id":"p","command_id":command],"INVALID_INPUT"),
                ("task_create",["project_id":"p","command_id":command,"title":String(repeating:"x",count:4001)],"INVALID_INPUT"),
                ("batch_claim",["project_id":"p","command_id":command,"policy_revision":1],"accepted"),
                ("batch_claim",["project_id":"p","command_id":command],"INVALID_INPUT"),
                ("batch_claim",["project_id":"p","command_id":command,"policy_revision":true],"INVALID_INPUT"),
                ("batch_claim",["project_id":"p","command_id":command,"policy_revision":1.5],"INVALID_INPUT"),
                ("task_edit",["project_id":"p","command_id":command,"patch":["title":"New"]],"accepted"),
                ("task_edit",["project_id":"p","command_id":command,"patch":["unsupported":true]],"INVALID_INPUT"),
                ("task_list",["project_id":"p","fields":Array(repeating:"title",count:201)],"INVALID_INPUT"),
                ("codex_hook_pickup",[:],"accepted"),
                ("codex_hook_confirm",["command_id":command,"delivery_ids":["delivery"]],"accepted"),
                ("codex_hook_confirm",["command_id":command],"INVALID_INPUT"),
                ("media_type_list",["project_id":"p"],"accepted"),
                ("media_type_list",["project_id":"p","unknown":true],"INVALID_INPUT"),
                ("fixture_unknown",[:],"FORBIDDEN"),
            ]
            let baseline = cases.map { outcome(router,$0.0,$0.1,worker) }
            ValidationCatalogFixture.configure(router)
            for (index, item) in cases.enumerated() {
                let actual = outcome(router,item.0,item.1,worker)
                XCTAssertEqual(actual,baseline[index],item.0)
                XCTAssertEqual(actual.components(separatedBy:":").first,item.2,item.0)
            }
        }
    }

    func testWorkerCacheMatchesBothRealCatalogsAcrossCallerIdentities() throws {
        try withRouter { router in
            ValidationCatalogFixture.configure(router)
            let provider = try XCTUnwrap(router.fixtureValidationCatalog)
            for worker in [
                Caller(role:"worker",installation:"one",projectIDs:[],sessionID:nil),
                Caller(role:"worker",installation:"two",projectIDs:["other"],sessionID:"other",workspace:"/other",assistantGrants:["other":["read":true]]),
            ] {
                for hookOnly in [false,true] {
                    XCTAssertEqual(try jsonString(provider(worker,hookOnly)),try jsonString(router.toolCatalog(worker,includingHookOnly:hookOnly)))
                    let names = provider(worker,hookOnly).compactMap { $0["name"] as? String }
                    XCTAssertEqual(names.contains("codex_hook_pickup"),hookOnly)
                    XCTAssertEqual(names.contains("codex_hook_confirm"),hookOnly)
                }
            }
        }
    }

    func testAssistantAndPublicCatalogNeverUseFixtureProvider() throws {
        try withRouter { router in
            var lookups = 0
            router.fixtureValidationCatalog = { _,_ in lookups += 1; return [] }
            var assistant = Caller(role:"assistant",installation:"assistant",projectIDs:["p"])
            XCTAssertEqual(outcome(router,"service_info",[:],assistant),"accepted")
            XCTAssertTrue(outcome(router,"task_get",["project_id":"p","task_id":"t"],assistant).hasPrefix("FORBIDDEN:"))
            assistant.assistantGrants = ["p":["read":true]]
            XCTAssertEqual(outcome(router,"task_get",["project_id":"p","task_id":"t"],assistant),"accepted")
            assistant.projectIDs = []
            XCTAssertTrue(outcome(router,"task_get",["project_id":"p","task_id":"t"],assistant).hasPrefix("FORBIDDEN:"))
            let worker = Caller(role:"worker",installation:"public-catalog",projectIDs:[])
            let reply = try router.handle(method:"tool_catalog",params:[:],caller:worker)["data"] as! JSON
            XCTAssertEqual(try jsonString(reply["tools"]!),try jsonString(router.toolCatalog(worker)))
            XCTAssertEqual(lookups,0)
            XCTAssertTrue(outcome(router,"service_info",[:],worker).hasPrefix("FORBIDDEN:"))
            XCTAssertEqual(lookups,1,"Only ordinary worker validation consults the fixture provider")
        }
    }
}
