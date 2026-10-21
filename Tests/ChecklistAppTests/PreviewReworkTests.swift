import XCTest
import SwiftUI
import AVFoundation
import CryptoKit
import ChecklistCore
@testable import ChecklistApp

final class PreviewReworkTests: XCTestCase {
    private func verified(_ name: String) throws -> AuthorizedPreviewFile {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticPreviewRework-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent(name)
        let data: Data
        if name == "sample.wav" {
            // The installed-check fixture's exact two-second mono 16-bit PCM generator.
            var wave = Data()
            func ascii(_ text: String) { wave.append(contentsOf:text.utf8) }
            func little<T: FixedWidthInteger>(_ value:T) { var v = value.littleEndian; withUnsafeBytes(of:&v) {wave.append(contentsOf:$0)} }
            let rate = 22050, samples = rate * 2, byteCount = samples * 2
            ascii("RIFF");little(UInt32(36 + byteCount));ascii("WAVEfmt ");little(UInt32(16));little(UInt16(1));little(UInt16(1));little(UInt32(rate));little(UInt32(rate * 2));little(UInt16(2));little(UInt16(16));ascii("data");little(UInt32(byteCount))
            for sample in 0..<samples { little(Int16(sin(Double(sample) * 2 * .pi * 440 / Double(rate)) * 4000)) }
            data = wave
        } else if name == "sample.mp4" {
            // Synthetic 640×360 H.264, 20 frames / two seconds, retained from check3.
            data = Data(base64Encoded:"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")!
        } else { data = Data("Synthetic unknown preview; never execute.".utf8) }
        try data.write(to:url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try AuthorizedPreviewFile.copy(path: url.path, source: Record(values: ["id":name,"name":name,"project_id":"p","task_id":"t","sha256":sha,"size":data.count,"mode":"managed","availability":"available"]))
    }
    func testPCMAndVideoLoadThroughTheSameVerifiedPlaybackPath() async throws {
        for name in ["sample.wav", "sample.mp4"] {
            let file = try verified(name)
            defer { withExtendedLifetime(file) {} }
            XCTAssertEqual(file.url.pathExtension, URL(fileURLWithPath: name).pathExtension)
            let asset = try await NativePlaybackAsset.load(url: file.url)
            let playable = try await asset.load(.isPlayable), duration = try await asset.load(.duration)
            XCTAssertTrue(playable, name); XCTAssertEqual(duration.seconds, 2, accuracy: 0.05)
        }
    }
    @MainActor func testUnknownFallbackAccessibilityContainsItsReasonAndSettles() throws {
        // An offscreen host exercises the same AX preferences without opening Checklist.
        let watchdog = DispatchWorkItem { fputs("AX QUERY EXCEEDED 10 SECONDS\n", stderr); _exit(124) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        let file = try verified("unsupported.synthetic-unknown")
        let enhanced = NSAccessibility.Attribute(rawValue:"AXEnhancedUserInterface")
        let wasEnhanced = NSApplication.shared.accessibilityAttributeValue(enhanced) ?? false
        NSApplication.shared.accessibilitySetValue(true,forAttribute:enhanced)
        defer { NSApplication.shared.accessibilitySetValue(wasEnhanced,forAttribute:enhanced) }
        let host = NSHostingView(rootView: VStack { Text("Viewing does not approve this candidate."); NativeFilePreview(file:file,kind:.unsupported,presentation:.init(kind:.unsupported)).frame(maxWidth:.infinity,maxHeight:.infinity) })
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:800,height:600),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "Synthetic Checklist preview regression (offscreen)"
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        var labels: [String] = []
        func attribute(_ obj: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return obj.responds(to:selector) ? obj.perform(selector)?.takeUnretainedValue() : nil
        }
        func visit(_ node: Any, depth: Int = 0) {
            guard depth < 30, let obj = node as? NSObject else { return }
            if let label = attribute(obj,"accessibilityLabel") as? String { labels.append(label) }
            if let value = attribute(obj,"accessibilityValue") as? String { labels.append(value) }
            for child in attribute(obj,"accessibilityChildren") as? [Any] ?? [] { visit(child, depth:depth+1) }
        }
        for _ in 0..<3 { for child in host.accessibilityChildren() ?? [] { visit(child) } }
        XCTAssertTrue(labels.joined(separator:" ").contains("no built-in preview"), labels.joined(separator:" | "))
    }
    @MainActor func testVideoPlayerMountsNativeControlsWithoutGenericSuperclassFailure() async throws {
        let file = try verified("sample.mp4")
        defer { withExtendedLifetime(file) {} }
        let host = NSHostingView(rootView: NativePlaybackPreview(url:file.url,audio:false))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:800,height:600),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func players(_ view: NSView) -> [NSView] {
            NSStringFromClass(type(of:view)) == "AVPlayerView" ? [view] : view.subviews.flatMap(players)
        }
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded()
            if let player = players(host).first {
                let playback = player.value(forKey:"player") as? AVPlayer
                XCTAssertNotNil(playback?.currentItem)
                XCTAssertNotEqual((player.value(forKey:"controlsStyle") as? NSNumber)?.intValue, 0)
                XCTAssertEqual(playback?.rate, 0)
                return
            }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        XCTFail("Native playback controls did not mount")
    }
    @MainActor func testMarkdownLoadsTicketAttachmentsOutsideSubmissionRefsAndKeepsDenials() async throws {
        let source = Record(values:["id":"md","name":"preview-sample.md","project_id":"p","task_id":"t"])
        let image = Record(values:["id":"front","name":"front-round2.png","project_id":"p","task_id":"t"])
        var calls = 0
        let resources = try await MarkdownPreviewResources.load(source:source,seed:[source]) { method, params in
            calls += 1
            XCTAssertEqual(method,"attachment_list"); XCTAssertEqual(params["project_id"] as? String,"p"); XCTAssertEqual(params["task_id"] as? String,"t")
            return ["attachments":[source.values,image.values]]
        }
        let rendered = RenderedMarkdownPreview(document:.parse("![front](front-round2.png)"),resources:resources,source:source)
        XCTAssertEqual(calls,1)
        XCTAssertEqual(MarkdownResource.resolve("front-round2.png",image:true,attachments:rendered.resourceMap),.attachment("front"))
        for path in ["../front-round2.png","/front-round2.png","file:///front-round2.png","data:image/png;base64,AAAA","https://example.invalid/front-round2.png"] {
            guard case .unavailable = MarkdownResource.resolve(path,image:true,attachments:rendered.resourceMap) else { XCTFail("Must deny \(path)"); continue }
        }
    }
    @MainActor func testMarkdownResourceReadRefusesPartialSetsAndDoesNotUseStaleSeedOnError() async throws {
        let source = Record(values:["id":"md","project_id":"p","task_id":"t"])
        let seed = [Record(values:["id":"seed","project_id":"p","task_id":"t","name":"front.png"])]
        let incomplete: [[String:Any]] = [[:],["attachments":seed.map(\.values),"has_more":true],["attachments":seed.map(\.values),"next_cursor":"next"],["attachments":Array(repeating:source.values,count:1001)]]
        for reply in incomplete {
            do { _ = try await MarkdownPreviewResources.load(source:source,seed:seed) {_,_ in reply};XCTFail("Partial resource metadata must fail closed") }
            catch { XCTAssertTrue(error is FilePreviewFailure) }
        }
        do { _ = try await MarkdownPreviewResources.load(source:source,seed:seed) {_,_ in throw FilePreviewFailure("Synthetic resource read failure")};XCTFail("Failed reads must not authorize the stale seed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Synthetic")) }
        let files = try await MarkdownPreviewResources.load(source:source,seed:seed) {_,_ in
            ["attachments":[seed[0].values,["id":"foreign","project_id":"other","task_id":"t","name":"front.png"],["id":"unlinked","project_id":"p","task_id":"t","name":"front.png","unlinked":true]]]
        }
        XCTAssertEqual(files.map(\.id),["seed"])
    }

}
