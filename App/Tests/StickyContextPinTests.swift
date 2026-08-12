//
//  StickyContextPinTests.swift
//
//  Product S1 — sticky pin store + compose merge.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class StickyContextPinTests: XCTestCase {

    func testDedupeKeyDistinguishesKinds() {
        let file = StickyContextPin(kind: .file, path: "/a/Foo.swift", displayName: "Foo.swift")
        let sym = StickyContextPin(
            kind: .symbol, path: "/a/Foo.swift", displayName: "bar · Foo.swift", symbolName: "bar")
        XCTAssertNotEqual(file.dedupeKey, sym.dedupeKey)
    }

    func testFileAttachmentsMergesPinsAndPendingWithoutDupPaths() {
        let pins = [
            StickyContextPin(kind: .file, path: "/p/A.swift", displayName: "A.swift"),
            StickyContextPin(kind: .folder, path: "/p/Sources", displayName: "Sources"),
            StickyContextPin(kind: .symbol, path: "/p/B.swift", displayName: "baz · B.swift", symbolName: "baz"),
        ]
        let pending = [
            ContextAttachment(path: "/p/A.swift", displayName: "A.swift"), // dup
            ContextAttachment(path: "/p/C.swift", displayName: "C.swift"),
        ]
        let merged = StickyContextCompose.fileAttachments(pins: pins, pending: pending)
        let paths = merged.map(\.path)
        XCTAssertEqual(paths, ["/p/A.swift", "/p/B.swift", "/p/C.swift"])
        XCTAssertFalse(paths.contains("/p/Sources"), "folders are not file attachments")
    }

    func testPinHeaderIncludesFolderListing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("one.swift"), atomically: true, encoding: .utf8)
        try "y".write(to: dir.appendingPathComponent("two.swift"), atomically: true, encoding: .utf8)

        let pins = [
            StickyContextPin(kind: .folder, path: dir.path, displayName: dir.lastPathComponent),
            StickyContextPin(kind: .symbol, path: "/x/Y.swift", displayName: "foo", symbolName: "foo"),
        ]
        let header = StickyContextCompose.pinHeaderText(pins: pins)
        XCTAssertTrue(header.contains("[Sticky context pins"), header)
        XCTAssertTrue(header.contains("@folder"), header)
        XCTAssertTrue(header.contains("one.swift"), header)
        XCTAssertTrue(header.contains("@symbol foo"), header)
    }

    func testPinHeaderEmptyWhenNoPins() {
        XCTAssertEqual(StickyContextCompose.pinHeaderText(pins: []), "")
    }

    func testRecordRoundTrip() {
        let pin = StickyContextPin(
            kind: .folder, path: "/proj/Sources", displayName: "Sources")
        let again = StickyContextPin(record: pin.asRecord)
        XCTAssertEqual(pin.id, again.id)
        XCTAssertEqual(pin.kind, again.kind)
        XCTAssertEqual(pin.path, again.path)
        XCTAssertEqual(pin.displayName, again.displayName)
    }
}

@MainActor
final class StickyContextPinViewModelTests: XCTestCase {

    func testStickyPinsSurvivePendingClearSemantics() {
        // Pure store behavior: pins list is independent of pendingAttachments.
        let pin = StickyContextPin(kind: .file, path: "/z/Z.swift", displayName: "Z.swift")
        var pins = [pin]
        var pending = [ContextAttachment(path: "/z/Z.swift", displayName: "Z.swift")]
        // Simulate send: clear pending only.
        pending = []
        XCTAssertEqual(pins.count, 1)
        XCTAssertTrue(pending.isEmpty)
        // Re-compose would still see pin via StickyContextCompose.
        let merged = StickyContextCompose.fileAttachments(pins: pins, pending: pending)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].path, "/z/Z.swift")
        pins.removeAll()
        XCTAssertTrue(StickyContextCompose.fileAttachments(pins: pins, pending: pending).isEmpty)
    }
}
