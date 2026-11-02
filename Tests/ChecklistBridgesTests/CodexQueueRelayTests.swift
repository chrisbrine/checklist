import XCTest
@testable import ChecklistBridges

final class CodexQueueRelayTests: XCTestCase {
    private final class Effects: CodexQueueTransportEffects {
        var calls = 0
        var content: String?
        var thread: String?
        var timeout: TimeInterval?
        var failure: Error?
        func queue(content: String, registration: NativeLifecycleRegistration, timeout: TimeInterval) throws -> CodexQueueReceipt {
            calls += 1; self.content = content; thread = registration.sessionID; self.timeout = timeout
            if let failure { throw failure }
            return .init(exitStatus:0,byteCount:content.utf8.count)
        }
    }

    private func registration(_ provider: String = "codex") throws -> NativeLifecycleRegistration {
        try XCTUnwrap(NativeLifecycleRegistration(provider:provider,sessionID:"00000000-0000-4000-8000-000000000410",
            executionDomain:"\(provider):24680:5:0",registryPath:nil))
    }

    func testSwitchOffRefusesAnAppThreadWithZeroQueueCalls() throws {
        let effects = Effects()
        XCTAssertTrue(CodexQueueRelay.enabled,"CL-413 turned the production route on.")
        XCTAssertThrowsError(try CodexQueueRelay.send(content:"Synthetic",registration:registration(),observation:.init(host:.nativeApp,reason:.sourceVscode),
            enabled:false,timeout:5,effects:effects)) {
            XCTAssertEqual(($0 as? CodexQueueRefusal)?.observation.reason,.routeDisabled)
        }
        XCTAssertEqual(effects.calls,0)
    }

    func testEnabledDoubleWithMissingFixtureRefusesWithoutQueueIO() throws {
        let registration = try registration(), effects = Effects()
        XCTAssertThrowsError(try CodexQueueRelay.send(content:"Synthetic",registration:registration,observation:.init(reason:.threadMissing),enabled:true,timeout:5,effects:effects)) {
            XCTAssertEqual(($0 as? CodexQueueRefusal)?.observation.reason,.threadMissing)
        }
        XCTAssertEqual(effects.calls,0)
    }

    func testExecOwnerIsRefusedEvenWhenSourceGateWouldBeEnabled() throws {
        let effects = Effects()
        XCTAssertThrowsError(try CodexQueueRelay.send(content:"Synthetic",registration:registration(),observation:.init(host:.exec,reason:.sourceExec),
            enabled:true,timeout:5,effects:effects)) {
            XCTAssertEqual(($0 as? CodexQueueRefusal)?.observation.reason,.sourceExec)
        }
        XCTAssertEqual(effects.calls,0)
    }

    func testUnprovenOwnerAndDisabledAppOwnerNeverQueue() throws {
        let effects = Effects(), registration = try registration()
        for (host,enabled) in [(CodexQueueHost.unproven,true),(.nativeApp,false)] {
            XCTAssertThrowsError(try CodexQueueRelay.send(content:"Synthetic",registration:registration,observation:.init(host:host,reason:host == .nativeApp ? .sourceVscode : .sourceUnknown),
                enabled:enabled,timeout:5,effects:effects))
        }
        XCTAssertEqual(effects.calls,0)
    }

    func testSyntheticAppProofPassesExactThreadContentAndBoundsToQueueEffect() throws {
        let effects = Effects(), registration = try registration()
        let note = "Synthetic; $(no shell)\nquoted \"message\""
        let receipt = try CodexQueueRelay.send(content:note,registration:registration,observation:.init(host:.nativeApp,reason:.sourceVscode),
            enabled:true,timeout:200,effects:effects)
        XCTAssertEqual(effects.calls,1)
        XCTAssertEqual(effects.thread,registration.sessionID)
        XCTAssertEqual(effects.content,note)
        XCTAssertEqual(effects.timeout,5)
        XCTAssertEqual(receipt.exitStatus,0)
        XCTAssertEqual(receipt.byteCount,note.utf8.count)
        // This synthetic exit receipt contains no acknowledgment or native-turn claim.
    }

    func testInvalidContentProviderAndDeadlineRefuseBeforeQueueEffect() throws {
        let effects = Effects(), registration = try registration()
        for note in ["", "Synthetic\u{0}tail",String(repeating:"x",count:128*1024+1)] {
            XCTAssertThrowsError(try CodexQueueRelay.send(content:note,registration:registration,observation:.init(host:.nativeApp,reason:.sourceVscode),
                enabled:true,timeout:5,effects:effects))
        }
        XCTAssertThrowsError(try CodexQueueRelay.send(content:"Synthetic",registration:self.registration("claude"),observation:.init(host:.nativeApp,reason:.sourceVscode),
            enabled:true,timeout:5,effects:effects))
        XCTAssertThrowsError(try CodexQueueRelay.send(content:"Synthetic",registration:registration,observation:.init(host:.nativeApp,reason:.sourceVscode),
            enabled:true,timeout:.infinity,effects:effects))
        XCTAssertEqual(effects.calls,0)
    }

    func testUncertainEffectIsNotRetriedOrConvertedToAcknowledgment() throws {
        let effects = Effects()
        effects.failure = NativeBridgeError.outcomeUnknown("Synthetic timeout after launch")
        XCTAssertThrowsError(try CodexQueueRelay.send(content:"Synthetic",registration:registration(),observation:.init(host:.nativeApp,reason:.sourceVscode),
            enabled:true,timeout:5,effects:effects)) {
            XCTAssertTrue(($0 as? NativeBridgeError)?.deliveryMayHaveOccurred == true)
        }
        XCTAssertEqual(effects.calls,1)
    }
}
