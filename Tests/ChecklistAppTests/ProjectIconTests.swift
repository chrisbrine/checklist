import XCTest
import SwiftUI
import AppKit
@testable import ChecklistApp

final class ProjectIconTests: XCTestCase {
    // Toolbar/menu, sidebar (including archived rows), project settings.
    private let sizes: [CGFloat] = [18, 20, 52]

    @MainActor func testLargeIconAtEveryDisplaySizePreservesItsPixels() throws {
        try checkImage(width: 256, height: 256)
    }

    @MainActor func testSmallIconAtEveryDisplaySize() throws {
        try checkImage(width: 32, height: 32)
    }

    @MainActor func testWideIconAtEveryDisplaySizeKeepsItsAspectRatio() throws {
        try checkImage(width: 256, height: 128)
    }

    @MainActor func testTallIconAtEveryDisplaySizeKeepsItsAspectRatio() throws {
        try checkImage(width: 128, height: 256)
    }

    @MainActor func testSymbolAtEveryDisplaySizeKeepsItsAppearance() throws {
        let project = Record(values: ["id": UUID().uuidString, "name": "Symbol", "icon": "tram", "accent": "purple"])
        for size in sizes {
            let icon = ProjectIcon(project: project, size: size)
            XCTAssertNil(icon.normalizedIcon)
            let rendered = try render(icon)
            let original = try render(Image(systemName: "tram").font(.system(size: size * 0.8))
                .foregroundStyle(Color.named("purple")).frame(width: size, height: size))
            XCTAssertEqual(rendered.pixelsWide, Int(size * 2))
            XCTAssertEqual(rendered.pixelsHigh, Int(size * 2))
            XCTAssertEqual(rendered.representation(using: .png, properties: [:]),
                           original.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(try XCTUnwrap(rendered.colorAt(x: rendered.pixelsWide / 2, y: rendered.pixelsHigh / 2)).alphaComponent, 0)
        }
        XCTAssertNil(ProjectIcon(project: Record(values: ["id": "missing", "icon_path": "/missing/icon.png"]), size: 18).normalizedIcon)
    }

    @MainActor func testMenuLabelSizeDoesNotFollowImagePixels() throws {
        let large = try fixture(width: 256, height: 256)
        let small = try fixture(width: 32, height: 32)
        defer { try? FileManager.default.removeItem(at: large.url); try? FileManager.default.removeItem(at: small.url) }
        func menuSize(_ project: Record) -> NSSize {
            NSHostingView(rootView: Menu { Button("Action") {} } label: {
                HStack { ProjectIcon(project: project, size: 18); Text("Project") }
            }).fittingSize
        }
        let largeSize = menuSize(large.project), smallSize = menuSize(small.project)
        XCTAssertEqual(largeSize.width, smallSize.width, accuracy: 1)
        XCTAssertEqual(largeSize.height, smallSize.height, accuracy: 1)
        XCTAssertLessThan(largeSize.height, 40)
    }

    @MainActor private func checkImage(width: Int, height: Int) throws {
        let fixture = try fixture(width: width, height: height)
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let source = try XCTUnwrap(ProjectIconImageCache.shared.image(projectID: fixture.project.id,
            path: fixture.url.path, assetID: fixture.project.id, checksum: "fixture"))
        let sourceSize = source.size
        for size in sizes {
            let icon = ProjectIcon(project: fixture.project, size: size)
            let image = try XCTUnwrap(icon.normalizedIcon)
            let expected = NSSize(width: size * CGFloat(width) / CGFloat(max(width, height)),
                                  height: size * CGFloat(height) / CGFloat(max(width, height)))
            XCTAssertEqual(image.size, expected, "Native menu image uses fitted points, not pixels")
            XCTAssertFalse(image === source)
            XCTAssertEqual(source.size, sourceSize, "Different display sizes cannot resize the cached source")
            let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
            XCTAssertEqual(bitmap.pixelsWide, width, "Display sizing must not downsample the managed bitmap")
            XCTAssertEqual(bitmap.pixelsHigh, height)
            let rendered = try render(icon)
            XCTAssertEqual(rendered.pixelsWide, Int(size * 2))
            XCTAssertEqual(rendered.pixelsHigh, Int(size * 2))
            // Actual rendered alpha bounds prove aspect fit, centering and rounded corners.
            let opaque = (0..<rendered.pixelsHigh).flatMap { y in
                (0..<rendered.pixelsWide).compactMap { x -> NSPoint? in
                    (rendered.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 ? NSPoint(x: x, y: y) : nil
                }
            }
            let minX = try XCTUnwrap(opaque.map(\.x).min()), maxX = try XCTUnwrap(opaque.map(\.x).max())
            let minY = try XCTUnwrap(opaque.map(\.y).min()), maxY = try XCTUnwrap(opaque.map(\.y).max())
            XCTAssertEqual(maxX - minX + 1, expected.width * 2, accuracy: 1)
            XCTAssertEqual(maxY - minY + 1, expected.height * 2, accuracy: 1)
            XCTAssertEqual(minX + maxX + 1, size * 2, accuracy: 1)
            XCTAssertEqual(minY + maxY + 1, size * 2, accuracy: 1)
            XCTAssertLessThan(try XCTUnwrap(rendered.colorAt(x: Int(minX), y: Int(minY))).alphaComponent, 0.5,
                              "The fitted image has rounded corners")
        }
    }

    @MainActor private func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        // The convenience cgImage path can vary by one premultiplied sample even
        // for identical views. Fix the bitmap precision and color space so the
        // appearance comparison stays exact, including antialiased edges.
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var image: CGImage?
        renderer.render(rasterizationScale: 2) { size, draw in
            let width = Int(size.width * 2), height = Int(size.height * 2)
            guard let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.scaleBy(x: 2, y: 2)
            draw(context)
            image = context.makeImage()
        }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(image))
    }

    private func fixture(width: Int, height: Int) throws -> (url: URL, project: Record) {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 255, count: bitmap.bytesPerRow * height)
        let id = UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("project-icon-\(id).png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return (url, Record(values: ["id": id, "name": "Fixture", "icon_path": url.path,
            "icon_asset": ["id": id, "sha256": "fixture"]]))
    }
}
