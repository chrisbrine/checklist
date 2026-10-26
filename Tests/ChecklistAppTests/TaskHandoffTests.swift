import XCTest
import ChecklistIPC
import ChecklistProviders
@testable import ChecklistApp

@MainActor final class TaskHandoffTests: XCTestCase {
    let task = Record(values: ["id": "ticket-id", "key": "CL-4", "project_id": "project-id"])
    let codex = HandoffProvider(id: "codex")
    let app = URL(fileURLWithPath: "/synthetic/Codex.app")
    let instruction = "Scoped ticket prompt; user must Send before this thread connects."

    func response(provider: String = "codex") -> [String: Any] {
        var result: [String: Any] = ["instruction": instruction, "limitation": "Press Send to start."]
        if provider == "codex" {
            var parts = URLComponents(); parts.scheme = "codex"; parts.host = "threads"; parts.path = "/new"
            parts.queryItems = [URLQueryItem(name: "prompt", value: instruction), URLQueryItem(name: "path", value: FileManager.default.temporaryDirectory.path)]
            result["compose_url"] = parts.url!.absoluteString
        }
        return result
    }
    func prepared() async -> TaskHandoffModel {
        let model = TaskHandoffModel()
        await model.prepare(task: task, provider: codex) { _, _ in self.response() }
        return model
    }
    struct OpenFailure: LocalizedError {
        var errorDescription: String? { "Synthetic host refused this URL (OSStatus -10814)." }
    }

    func testPreparationIsOnlyAScopedReadAndPreservesThePrompt() async throws {
        let model = TaskHandoffModel()
        var calls: [String] = []
        await model.prepare(task: task, provider: codex) { method, params in
            calls.append(method)
            XCTAssertEqual(params["task_id"] as? String, "ticket-id")
            XCTAssertEqual(params["project_id"] as? String, "project-id")
            XCTAssertEqual(params["provider"] as? String, "codex")
            XCTAssertEqual(Set(params.keys), ["task_id", "project_id", "provider", "command_id"])
            return self.response()
        }
        XCTAssertEqual(calls, ["task_handoff_prepare"])
        XCTAssertEqual(model.instruction, instruction)
        let url = try XCTUnwrap(model.composeURL)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "prompt" }?.value, instruction)
        XCTAssertFalse(model.loading); XCTAssertFalse(model.opening); XCTAssertFalse(model.openedComposer)
        XCTAssertTrue(model.preparationFailure.isEmpty)
    }

    func testPreparationFailureRetriesTheSameRequestWithoutAConnectionCommand() async {
        let model = TaskHandoffModel()
        var commands: [String] = []
        await model.prepare(task: task, provider: codex) { method, params in
            XCTAssertEqual(method, "task_handoff_prepare"); commands.append(params["command_id"] as! String)
            throw OpenFailure()
        }
        XCTAssertEqual(model.preparationFailure, OpenFailure().localizedDescription)
        XCTAssertNil(model.composeURL); XCTAssertTrue(model.instruction.isEmpty); XCTAssertFalse(model.openedComposer)
        await model.prepare(task: task, provider: codex) { method, params in
            XCTAssertEqual(method, "task_handoff_prepare"); commands.append(params["command_id"] as! String)
            return self.response()
        }
        XCTAssertEqual(commands.count, 2); XCTAssertEqual(commands[0], commands[1])
        XCTAssertTrue(model.preparationFailure.isEmpty); XCTAssertNotNil(model.composeURL)
    }

    func testMissingInstructionRefusesTheLinkWithoutOpeningAnything() async {
        let model = TaskHandoffModel()
        await model.prepare(task: task, provider: codex) { _, _ in ["compose_url": self.response()["compose_url"]!] }
        XCTAssertTrue(model.preparationFailure.contains("did not return a ticket instruction"))
        XCTAssertNil(model.composeURL); XCTAssertFalse(model.openedComposer)
    }

    func testInvalidComposeLinkKeepsTheCopyFallbackAndDoesNotOpenIt() async {
        let model = TaskHandoffModel()
        await model.prepare(task: task, provider: codex) { _, _ in ["instruction": self.instruction, "compose_url": "https://example.invalid/send"] }
        XCTAssertEqual(model.instruction, instruction); XCTAssertNil(model.composeURL)
        XCTAssertTrue(model.preparationFailure.contains("unsupported compose link"))
        await model.openPreparedChat(task: task, provider: codex, applicationURL: app) { _, _ in XCTFail("Rejected link must never open") }
        XCTAssertFalse(model.openedComposer)
    }

    func testClaudeNeverUsesACodexComposerEvenIfReturnedByTheService() async {
        let model = TaskHandoffModel()
        await model.prepare(task: task, provider: HandoffProvider(id: "claude")) { _, params in
            XCTAssertEqual(params["provider"] as? String, "claude"); return self.response()
        }
        XCTAssertNil(model.composeURL); XCTAssertEqual(model.instruction, instruction)
        XCTAssertTrue(model.preparationFailure.contains("unsupported compose link")); XCTAssertFalse(model.openedComposer)
    }

    func testMissingCodexApplicationPreservesThePreparedInstruction() async {
        let model = await prepared()
        await model.openPreparedChat(task: task, provider: codex, applicationURL: nil) { _, _ in XCTFail("Missing provider cannot open") }
        XCTAssertTrue(model.openingFailure.contains("could not be located")); XCTAssertEqual(model.instruction, instruction)
        XCTAssertNotNil(model.composeURL); XCTAssertFalse(model.openedComposer); XCTAssertFalse(model.opening)
    }

    func testOpeningFailureKeepsCopyAndRetryThenReportsOnlyAnOpenedComposer() async throws {
        let model = await prepared()
        let original = model.composeURL
        await model.openPreparedChat(task: task, provider: codex, applicationURL: app) { url, app in
            XCTAssertEqual(url, original); XCTAssertEqual(app, self.app); throw OpenFailure()
        }
        XCTAssertEqual(model.openingFailure, OpenFailure().localizedDescription)
        XCTAssertTrue(model.preparationFailure.isEmpty); XCTAssertEqual(model.instruction, instruction)
        XCTAssertEqual(model.composeURL, original); XCTAssertFalse(model.openedComposer); XCTAssertFalse(model.opening)
        await model.openPreparedChat(task: task, provider: codex, applicationURL: app) { url, _ in XCTAssertEqual(url, original) }
        XCTAssertTrue(model.openedComposer); XCTAssertTrue(model.openingFailure.isEmpty); XCTAssertFalse(model.opening)
        // A later refusal must not leave the previous "opened" success visible.
        await model.openPreparedChat(task: task, provider: codex, applicationURL: app) { _, _ in throw OpenFailure() }
        XCTAssertFalse(model.openedComposer)
    }

    func testAnInFlightOpenCannotOpenASecondComposer() async {
        let model = await prepared()
        await model.openPreparedChat(task: task, provider: codex, applicationURL: app) { _, _ in
            XCTAssertTrue(model.opening); XCTAssertFalse(model.openedComposer)
            await model.openPreparedChat(task: task, provider: codex, applicationURL: self.app) { _, _ in XCTFail("Duplicate open") }
        }
        XCTAssertTrue(model.openedComposer); XCTAssertFalse(model.opening)
    }

    func testRefreshingPreparationClearsEarlierOpenReceiptsAndOldPrompt() async {
        let model = await prepared()
        await model.openPreparedChat(task: task, provider: codex, applicationURL: app) { _, _ in }
        XCTAssertTrue(model.openedComposer)
        await model.prepare(task: task, provider: codex) { _, _ in throw OpenFailure() }
        XCTAssertFalse(model.openedComposer); XCTAssertNil(model.composeURL)
        XCTAssertTrue(model.instruction.isEmpty); XCTAssertTrue(model.openingFailure.isEmpty)
    }

    func testClaudeFallbackRetainsInstructionAfterAnApplicationLaunchFailure() async {
        let model = TaskHandoffModel()
        await model.prepare(task: task, provider: HandoffProvider(id: "claude")) { _, _ in self.response(provider: "claude") }
        XCTAssertTrue(model.preparationFailure.isEmpty); XCTAssertNil(model.composeURL)
        await model.openApplication(app) { _ in throw OpenFailure() }
        XCTAssertEqual(model.openingFailure, OpenFailure().localizedDescription)
        XCTAssertEqual(model.instruction, instruction); XCTAssertFalse(model.openedComposer)
        await model.openApplication(app) { _ in }
        XCTAssertTrue(model.openingFailure.isEmpty); XCTAssertFalse(model.openedComposer)
    }

    @MainActor private final class PendingPreparation {
        let started = XCTestExpectation(description: "Preparation transport suspended")
        var continuation: CheckedContinuation<[String: Any], Error>?

        func response() async throws -> [String: Any] {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }
    }

    func testSupersededCodexCannotOverwriteNewerClaudeOrReachItsOpener() async {
        let model = TaskHandoffModel(), pending = PendingPreparation()
        let old = Task { await model.prepare(task: task, provider: codex) { _, _ in try await pending.response() } }
        await fulfillment(of: [pending.started], timeout: 2)
        let other = Record(values: ["id": "ticket-b", "project_id": "project-id"])
        let claude = HandoffProvider(id: "claude")
        await model.prepare(task: other, provider: claude) { _, _ in
            ["instruction": "Claude ticket B", "limitation": "Copy into Claude."]
        }
        pending.continuation?.resume(returning: fixtureReply(response()))
        await old.value
        XCTAssertEqual(model.instruction, "Claude ticket B")
        XCTAssertEqual(model.limitation, "Copy into Claude.")
        XCTAssertNil(model.composeURL); XCTAssertFalse(model.loading)
        XCTAssertTrue(model.preparationFailure.isEmpty)
        await model.openPreparedChat(task: other, provider: claude, applicationURL: URL(fileURLWithPath: "/synthetic/Claude.app")) { _, _ in
            XCTFail("A stale Codex URL must never reach the Claude opener")
        }
        XCTAssertFalse(model.openedComposer)
    }

    func testCanceledPreparationDropsLateSuccessAndFailure() async {
        for fails in [false, true] {
            let model = TaskHandoffModel(), pending = PendingPreparation()
            let preparation = Task { await model.prepare(task: task, provider: codex) { _, _ in try await pending.response() } }
            await fulfillment(of: [pending.started], timeout: 2)
            preparation.cancel()
            if fails { pending.continuation?.resume(throwing: OpenFailure()) }
            else { pending.continuation?.resume(returning: fixtureReply(response())) }
            await preparation.value
            XCTAssertTrue(model.instruction.isEmpty); XCTAssertTrue(model.limitation.isEmpty)
            XCTAssertTrue(model.preparationFailure.isEmpty); XCTAssertNil(model.composeURL)
            XCTAssertFalse(model.loading); XCTAssertFalse(model.openedComposer)
            await model.openPreparedChat(task: task, provider: codex, applicationURL: app) { _, _ in XCTFail("Canceled draft must never open") }
        }
    }

    func testCanceledCodexReplyDoesNotReplaceCompletedClaudePreparation() async {
        let model = TaskHandoffModel(), pending = PendingPreparation()
        let old = Task { await model.prepare(task: task, provider: codex) { _, _ in try await pending.response() } }
        await fulfillment(of: [pending.started], timeout: 2)
        old.cancel()
        let claude = HandoffProvider(id: "claude")
        await model.prepare(task: task, provider: claude) { _, _ in ["instruction": "Current Claude instruction"] }
        pending.continuation?.resume(returning: fixtureReply(response()))
        await old.value
        XCTAssertEqual(model.instruction, "Current Claude instruction"); XCTAssertNil(model.composeURL)
        XCTAssertFalse(model.loading); XCTAssertTrue(model.preparationFailure.isEmpty)
        await model.openPreparedChat(task: task, provider: claude, applicationURL: URL(fileURLWithPath: "/synthetic/Claude.app")) { _, _ in XCTFail("Stale provider URL") }
    }

    func testSameScopeNewGenerationWinsOverLateSuccess() async {
        let model = TaskHandoffModel(), pending = PendingPreparation()
        let old = Task { await model.prepare(task: task, provider: codex) { _, _ in try await pending.response() } }
        await fulfillment(of: [pending.started], timeout: 2)
        await model.prepare(task: task, provider: codex) { _, _ in ["instruction": "New generation"] }
        pending.continuation?.resume(returning: fixtureReply(response()))
        await old.value
        XCTAssertEqual(model.instruction, "New generation"); XCTAssertNil(model.composeURL)
        XCTAssertFalse(model.loading); XCTAssertTrue(model.preparationFailure.isEmpty)
    }

    func testStaleFailureCannotEndNewerLoadingOrPublishAnError() async {
        let model = TaskHandoffModel(), first = PendingPreparation(), second = PendingPreparation()
        let old = Task { await model.prepare(task: task, provider: codex) { _, _ in try await first.response() } }
        await fulfillment(of: [first.started], timeout: 2)
        let current = Task { await model.prepare(task: task, provider: codex) { _, _ in try await second.response() } }
        await fulfillment(of: [second.started], timeout: 2)
        first.continuation?.resume(throwing: OpenFailure())
        await old.value
        XCTAssertTrue(model.loading); XCTAssertTrue(model.preparationFailure.isEmpty)
        second.continuation?.resume(returning: fixtureReply(response()))
        await current.value
        XCTAssertFalse(model.loading); XCTAssertEqual(model.instruction, instruction)
        XCTAssertNotNil(model.composeURL); XCTAssertTrue(model.preparationFailure.isEmpty)
    }

    func testOpenerRefusesAnotherTaskProjectOrProvider() async {
        let model = await prepared()
        let otherTask = Record(values: ["id": "different-ticket", "project_id": "project-id"])
        let otherProject = Record(values: ["id": "ticket-id", "project_id": "different-project"])
        for (target, provider) in [(otherTask, codex), (otherProject, codex), (task, HandoffProvider(id: "claude"))] {
            XCTAssertNil(model.validatedComposeURL(task: target, provider: provider))
            await model.openPreparedChat(task: target, provider: provider, applicationURL: app) { _, _ in XCTFail("Mismatched preparation must not open") }
            XCTAssertFalse(model.openedComposer); XCTAssertTrue(model.openingFailure.contains("does not match"))
        }
        XCTAssertEqual(model.instruction, instruction)
        await model.openPreparedChat(task: task, provider: codex, applicationURL: app) { _, _ in }
        XCTAssertTrue(model.openedComposer)
    }

    func testOpenerRevalidatesCurrentProviderCapability() async throws {
        let model = await prepared()
        let registry = try ProviderPluginRegistry(ProviderPluginRegistry.bundled.registrations.map {
            .init(plugin: $0.plugin, enabled: $0.enabled, qualifiedCapabilities: $0.qualifiedCapabilities.subtracting([.composer]))
        })
        let workOnly = HandoffProvider(id: "codex", registry: registry)
        XCTAssertTrue(workOnly.isAvailable)
        XCTAssertNil(model.validatedComposeURL(task: task, provider: workOnly))
        await model.openPreparedChat(task: task, provider: workOnly, applicationURL: app) { _, _ in XCTFail("Unavailable composer capability must not open") }
        XCTAssertFalse(model.openedComposer); XCTAssertTrue(model.openingFailure.contains("does not match"))
    }

    func testComposeValidatorRejectsSendingArbitraryActionsAndAmbiguousPrompts() {
        for url in ["codex://threads/new?prompt=one&send=true", "codex://threads/new?prompt=one&prompt=two", "codex://threads/new?prompt=", "codex://threads/send?prompt=one", "codex://user@threads/new?prompt=one", "codex://threads:99/new?prompt=one", "codex://threads/new?prompt=one#send", "codex://threads/new?prompt=one&path=relative", "codex://threads/new?prompt=one&path=/missing-checklist-handoff-\(UUID().uuidString)", "claude://threads/new?prompt=one"] {
            XCTAssertNil(CodexComposeLink.validated(url), url)
        }
    }

    func testComposeLinkRoundTripsScopedInstructionAndUnusualWorkspaceBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Checklist handoff ' & # ü " + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = try ChecklistHandoff.instruction(key: "CL-4", title: "Question? & # ü", root: directory.path, projectID: "scoped-project", taskID: "scoped-ticket", cliCommand: "/Applications/Checklist.app/Contents/MacOS/checklist")
        var parts = URLComponents(); parts.scheme = "codex"; parts.host = "threads"; parts.path = "/new"
        parts.queryItems = [URLQueryItem(name: "prompt", value: text), URLQueryItem(name: "path", value: directory.path)]
        let url = try XCTUnwrap(CodexComposeLink.validated(parts.url!.absoluteString))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "prompt" }?.value, text)
        XCTAssertEqual(items.first { $0.name == "path" }?.value, directory.path)
        XCTAssertTrue(text.contains("connect --task scoped-ticket")); XCTAssertTrue(text.contains("\"project_id\":\"scoped-project\""))
    }
}
