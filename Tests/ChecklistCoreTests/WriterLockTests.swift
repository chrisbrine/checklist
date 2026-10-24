import XCTest
@testable import ChecklistCore

/// CL-71: a large source submission blocks other clients' commands only briefly, and git
/// calls are bounded. CHECKLIST_CL71_SOURCE_MB sets the synthetic source size (default 32).
extension EvidenceAuthorityTests {
    func testLargeSubmitBlocksOtherCommandsOnlyBriefly() throws {
        try QualificationSuite.requireEnabled()
        let megabytes = Int(ProcessInfo.processInfo.environment["CHECKLIST_CL71_SOURCE_MB"] ?? "") ?? 32
        let chunk = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        for index in 0..<megabytes { try (chunk + Data("\(index)".utf8)).write(to: workspace.appendingPathComponent("asset-\(index).bin")) }
        try git(["init"])
        let p = try project(), t = try ready(p), a = try claim(p, t), other = try ready(p)
        let finished = DispatchSemaphore(value: 0), lock = NSLock()
        var submitError: Error?, submitSeconds = 0.0
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            do { _ = try self.submitSource(p, a) } catch { submitError = error }
            lock.lock(); submitSeconds = Date().timeIntervalSince(start); lock.unlock()
            finished.signal()
        }
        var writes: [Double] = [], reads: [Double] = []
        while finished.wait(timeout: .now() + 0.02) == .timedOut {
            var start = Date()
            _ = try call("message_send", ["project_id": p["id"]!, "task_id": other["id"]!, "body": "Latency probe"])
            writes.append(Date().timeIntervalSince(start))
            start = Date()
            _ = try call("task_list", ["project_id": p["id"]!])
            reads.append(Date().timeIntervalSince(start))
        }
        XCTAssertNil(submitError)
        lock.lock(); let total = submitSeconds; lock.unlock()
        let report: JSON = ["source_mb": megabytes, "submit_seconds": total, "probes": writes.count, "max_write_seconds": writes.max() ?? 0, "max_read_seconds": reads.max() ?? 0,
                            "median_write_seconds": try XCTUnwrap(writes.sorted().dropFirst(writes.count / 2).first), "median_read_seconds": try XCTUnwrap(reads.sorted().dropFirst(reads.count / 2).first)]
        let text = try jsonString(report)
        print("CL-71 measurement: " + text)
        try? Data(text.utf8).write(to: directory.appendingPathComponent("cl71-measurement-\(megabytes)mb.json"))
        XCTAssertGreaterThanOrEqual(writes.count, 3, "the probe ran while the submission was in progress")
        XCTAssertLessThan(writes.max() ?? .infinity, max(0.5, total * 0.25), "a write waited for the submission's file work")
        XCTAssertLessThan(reads.max() ?? .infinity, max(0.5, total * 0.25), "a read waited for the submission's file work")
    }

    /// Runs `command` on another thread while this thread times small writes and reads.
    func probeDuring(_ command: @escaping () throws -> Void, project p: JSON, ticket: JSON) throws -> (seconds: Double, maxWrite: Double, maxRead: Double, probes: Int) {
        let finished = DispatchSemaphore(value: 0), lock = NSLock()
        var failure: Error?, seconds = 0.0
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            do { try command() } catch { failure = error }
            lock.lock(); seconds = Date().timeIntervalSince(start); lock.unlock(); finished.signal()
        }
        var writes: [Double] = [], reads: [Double] = []
        while finished.wait(timeout: .now() + 0.005) == .timedOut {
            var start = Date(); _ = try call("message_send", ["project_id": p["id"]!, "task_id": ticket["id"]!, "body": "Latency probe"]); writes.append(Date().timeIntervalSince(start))
            start = Date(); _ = try call("task_list", ["project_id": p["id"]!]); reads.append(Date().timeIntervalSince(start))
        }
        if let failure { throw failure }
        lock.lock(); defer { lock.unlock() }
        return (seconds, writes.max() ?? 0, reads.max() ?? 0, writes.count)
    }

    /// Finding d21e29c2: a reference-mode import reads and hashes its file before the writer.
    func testLargeReferenceImportBlocksOtherCommandsOnlyBriefly() throws {
        try QualificationSuite.requireEnabled()
        let p = try project(), t = try ready(p), other = try ready(p)
        let file = workspace.appendingPathComponent("large-reference.bin")
        let chunk = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file); for _ in 0..<256 { try handle.write(contentsOf: chunk) }; try handle.close()
        var attached: JSON = [:]
        let measured = try probeDuring({ attached = try self.call("attachment_add", ["project_id": p["id"]!, "task_id": t["id"]!, "path": file.path, "mode": "reference"]) }, project: p, ticket: other)
        print("CL-71 reference import: \(measured)")
        XCTAssertEqual(attached["size"] as? Int, 256 << 20)
        XCTAssertGreaterThanOrEqual(measured.probes, 2, "the probe ran while the import was in progress")
        XCTAssertLessThan(measured.maxWrite, measured.seconds * 0.5, "a write waited for the import's file work")
    }

    /// Finding d21e29c2: a review claim validates the captured target before the writer.
    func testReviewClaimValidatesTheCapturedTargetBeforeTheWriter() throws {
        try QualificationSuite.requireEnabled()
        let chunk = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        for index in 0..<128 { try (chunk + Data("\(index)".utf8)).write(to: workspace.appendingPathComponent("captured-\(index).bin")) }
        try git(["init"])
        let p = try project(), t = try ready(p), a = try claim(p, t), other = try ready(p)
        let submitted = try submitSource(p, a)
        let reviewer = try native(p, "claim-reviewer", domain: "codex:4242:1:1")
        var review: JSON = [:]
        let measured = try probeDuring({ review = try self.reviewClaim(p, submitted, reviewer) }, project: p, ticket: other)
        print("CL-71 review claim: \(measured)")
        XCTAssertEqual(review["state"] as? String, "active")
        XCTAssertGreaterThanOrEqual(measured.probes, 2)
        XCTAssertLessThan(measured.maxWrite, measured.seconds * 0.5, "a write waited for the claim's capture validation")
    }

    /// Findings bcbee370 and b906f027: inside the writer, a prepared capture is decided from its
    /// content observation alone. A content change is stale without a hash; a permission-only
    /// change is accepted without a read.
    func testPreparedCaptureObservationRejectsChangesBeforeTheWriter() throws {
        try sourceFixture()
        let p = try project()
        for mutation in ["none", "modify", "add", "remove", "chmod", "write-permission", "unreadable", "same-bytes", "changed-before", "folder-unreadable-before"] {
            let task = try ready(p), author = try claim(p, task), submission = try submitSource(p, author)
            let reviewer = try native(p, "observation-" + mutation, domain: "observation-" + mutation)
            let target = submission["task"] as! JSON
            let input: JSON = ["command_id": UUID().uuidString, "project_id": p["id"]!, "task_id": target["id"]!, "expected_revision": target["revision"]!, "phase": "review", "review_request_id": (submission["review_request_ids"] as! [String])[0], "target_manifest_id": submission["manifest_id"]!, "gate": "review"]
            let manifest = try router.dbQueue.read { try router.record($0, submission["manifest_id"] as! String, type: "manifest") }
            let capture = (manifest["evidence"] as! JSON)["source_capture"] as! JSON, id = capture["id"] as! String
            let snapshot = try router.managedURL(capture["snapshot_path"] as! String, family: "source-captures"), tracked = snapshot.appendingPathComponent("tracked.txt")
            let original = try Data(contentsOf: tracked), mode = (try FileManager.default.attributesOfItem(atPath: tracked.path)[.posixPermissions] as! NSNumber).intValue
            if mutation == "changed-before" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tracked.path); try Data("dirtx".utf8).write(to: tracked) }
            // Finding 4485fafb: a capture that preparation could not read fails in the writer although it is readable again.
            let folderMode = (try FileManager.default.attributesOfItem(atPath: snapshot.path)[.posixPermissions] as! NSNumber).intValue
            if mutation == "folder-unreadable-before" { try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: snapshot.path) }
            let preparation = try router.prepareCommandFiles(method: "work_claim", params: input, caller: reviewer)
            if mutation == "folder-unreadable-before" { try FileManager.default.setAttributes([.posixPermissions: folderMode], ofItemAtPath: snapshot.path) }
            if mutation.hasSuffix("-before") { XCTAssertTrue(preparation.failedCaptures.contains(id), mutation); XCTAssertNil(preparation.validatedCaptures[id]) }
            else { XCTAssertNotNil(preparation.validatedCaptures[id], mutation) }
            switch mutation {
            case "modify": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tracked.path); try Data("dirtx".utf8).write(to: tracked)
            case "add": try Data("unexpected member".utf8).write(to: snapshot.appendingPathComponent("extra.txt"))
            case "remove": try FileManager.default.removeItem(at: tracked)
            case "chmod": try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tracked.path)
            case "write-permission": try FileManager.default.setAttributes([.posixPermissions: mode ^ 0o200], ofItemAtPath: tracked.path)
            // A read inside the writer would fail; only the observation can accept this file.
            case "unreadable": try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tracked.path)
            // The same bytes with a new modification time: a hash would accept them, the observation does not.
            case "same-bytes": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tracked.path); try original.write(to: tracked)
            default: break
            }
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tracked.path) }
            var outcome: Result<String?, Error> = .success(nil)
            do {
                try ArchiveStorageGate.withExclusive(root: storeRoot) { _ in
                    try router.dbQueue.writeWithoutTransaction { db in
                        router.commandPreparation = preparation
                        defer { router.commandPreparation = CommandPreparation() }
                        try router.withValidatedDomainTransaction(db) {
                            outcome = .success(try router.work(db, input, reviewer, "work_claim")["state"] as? String)
                            return .rollback
                        }
                    }
                }
            } catch { outcome = .failure(error) }
            switch (mutation, outcome) {
            case ("none", .success(let state)), ("write-permission", .success(let state)), ("unreadable", .success(let state)): XCTAssertEqual(state, "active", "an unchanged capture is accepted from its observation: \(mutation)")
            case ("chmod", .failure(let error)): XCTAssertEqual((error as? CoreError)?.code, "EVIDENCE_STALE", "a changed executable bit is stale")
            case (_, .failure(let error)): XCTAssertEqual((error as? CoreError)?.code, "EVIDENCE_STALE", mutation)
            default: XCTFail("a changed capture became an active review claim: \(mutation)")
            }
        }
    }

    /// Finding b906f027: a prefetched object whose identity changed fails without a second hash.
    func testPreparedObjectWithChangedIdentityFailsWithoutHashing() throws {
        let managed = router.root.appendingPathComponent("objects/prefetch-fixture")
        try FileManager.default.createDirectory(at:managed,withIntermediateDirectories:true)
        let file = managed.appendingPathComponent("object.bin"), other = managed.appendingPathComponent("other.bin"), bytes = Data("object bytes".utf8)
        try bytes.write(to: file); try bytes.write(to: other)
        let sha = ChecklistCore.hash(bytes)
        var preparation = CommandPreparation()
        router.prefetchVerifiedObject(file.path, sha256: sha, into: &preparation)
        router.prefetchVerifiedObject(other.path, sha256: String(repeating: "0", count: 64), into: &preparation)
        XCTAssertNotNil(preparation.verifiedObjects[file.path]); XCTAssertTrue(preparation.failedObjects.contains(other.path))
        router.commandPreparation = preparation
        defer { router.commandPreparation = CommandPreparation() }
        XCTAssertTrue(router.objectBytesMatch(file.path, sha256: sha))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertTrue(router.objectBytesMatch(file.path, sha256: sha), "a permission change keeps the content identity")
        XCTAssertFalse(router.objectBytesMatch(other.path, sha256: String(repeating: "0", count: 64)), "a failed prefetch fails at once")
        Thread.sleep(forTimeInterval: 0.01); try bytes.write(to: file)
        XCTAssertFalse(router.objectBytesMatch(file.path, sha256: sha), "the same bytes with a new identity are not hashed again inside the writer")
        router.commandPreparation = CommandPreparation()
        XCTAssertTrue(router.objectBytesMatch(file.path, sha256: sha), "an object that the command did not prepare is hashed")

        // Finding 4485fafb: a read error during the prefetch is recorded; the restored file is not read in the writer.
        let unreadable = managed.appendingPathComponent("unreadable.bin"), missing = managed.appendingPathComponent("missing.bin").path
        try bytes.write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        var failed = CommandPreparation()
        router.prefetchVerifiedObject(unreadable.path, sha256: sha, into: &failed)
        router.prefetchVerifiedObject(missing, sha256: sha, into: &failed)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
        XCTAssertEqual(failed.failedObjects, [unreadable.path, missing])
        router.commandPreparation = failed
        XCTAssertFalse(router.objectBytesMatch(unreadable.path, sha256: sha), "a failed prefetch read fails at once")
    }

    /// Finding 4485fafb: a live inventory whose prefetch failed reports its error without git inside the writer.
    func testFailedInventoryPrefetchFailsWithoutRunningGitAgain() throws {
        var preparation = CommandPreparation()
        let key = router.inventoryKey(workspace.path, [])
        preparation.failedInventories[key] = CoreError("SOURCE_CAPTURE_INCOMPLETE", "synthetic prefetch failure")
        router.commandPreparation = preparation
        defer { router.commandPreparation = CommandPreparation() }
        XCTAssertThrowsError(try router.sourceInventory(workspace.path)) { XCTAssertEqual(($0 as? CoreError)?.message, "synthetic prefetch failure") }
    }

    func testGitCallsAreBoundedAndReadBothPipes() throws {
        let scripts = directory.appendingPathComponent("fake-git"); try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        // A child that writes 1 MiB to stderr before stdout would block a parent that reads stdout first.
        let noisy = scripts.appendingPathComponent("noisy"), hanging = scripts.appendingPathComponent("hanging")
        try "#!/bin/sh\ni=0; while [ $i -lt 20000 ]; do echo 012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789 >&2; i=$((i+1)); done\necho done\n".write(to: noisy, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nwhile :; do :; done\n".write(to: hanging, atomically: true, encoding: .utf8)
        for file in [noisy, hanging] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        let output = try SourceGit.run(workspace.path, ["status"], protectedRoots: [NSTemporaryDirectory() + "checklist-fixture-protected"], executable: noisy.path, timeout: 10)
        XCTAssertEqual(String(data: output, encoding: .utf8), "done\n")
        let start = Date()
        XCTAssertThrowsError(try SourceGit.run(workspace.path, ["status"], protectedRoots: [NSTemporaryDirectory() + "checklist-fixture-protected"], executable: hanging.path, timeout: 1)) {
            XCTAssertEqual(($0 as? CoreError)?.code, "SOURCE_CAPTURE_INCOMPLETE")
            XCTAssertEqual(($0 as? CoreError)?.details["reason"] as? String, "git_timeout")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }
}
