//
//  DirectoryListingTests.swift
//
//  Drives DirectoryListing.parse against real list_directory output shape
//  (and ListDirectoryTool.execute against a temp dir).
//

import XCTest
@testable import AgentCore

final class DirectoryListingTests: XCTestCase {

    func testParseVCListProducesNameSizeModified() {
        let epoch = 1_720_000_000
        let raw = """
        VC_LIST\t/Users/me/proj
        dir\t0\tSources\t\(epoch)
        file\t4096\tREADME.md\t\(epoch)
        file\t128\tPackage.swift\t\(epoch)
        """
        let listing = DirectoryListing.parse(raw)
        XCTAssertNotNil(listing)
        XCTAssertEqual(listing?.path, "/Users/me/proj")
        XCTAssertEqual(listing?.entries.count, 3)
        XCTAssertEqual(listing?.directories.count, 1)
        XCTAssertEqual(listing?.files.count, 2)

        let readme = listing?.files.first { $0.name == "README.md" }
        XCTAssertEqual(readme?.size, 4096)
        XCTAssertNotNil(readme?.modified)
        XCTAssertEqual(Int(readme!.modified!.timeIntervalSince1970), epoch)

        let pkg = listing?.files.first { $0.name == "Package.swift" }
        XCTAssertEqual(pkg?.size, 128)
        XCTAssertFalse(pkg?.isDirectory ?? true)
    }

    func testParseLegacyDfLines() {
        let raw = """
        d  Sources
        f  README.md
        f  Package.swift
        """
        let listing = DirectoryListing.parse(raw)
        XCTAssertNotNil(listing)
        XCTAssertEqual(listing?.directories.map(\.name), ["Sources"])
        XCTAssertEqual(listing?.files.map(\.name).sorted(), ["Package.swift", "README.md"])
    }

    func testFormatByteSize() {
        XCTAssertEqual(DirectoryListing.formatByteSize(500), "500 B")
        XCTAssertTrue(DirectoryListing.formatByteSize(2048).contains("KB"))
    }

    func testListDirectoryToolEmitsVCListWithSizeAndMtime() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("agentos-listdir-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let file = dir.appendingPathComponent("hello.txt")
        try "hello-world".write(to: file, atomically: true, encoding: .utf8)
        let sub = dir.appendingPathComponent("subdir", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)

        await ToolRegistry.shared.registerBuiltins()
        let ctx = ToolContext(
            projectRoot: dir,
            conversationID: UUID()
        )
        let result = try await ToolRegistry.shared.execute(
            name: "list_directory",
            arguments: ToolArguments(dictionary: ["path": "."]),
            context: ctx
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.hasPrefix("VC_LIST\t"), result.content)

        let listing = DirectoryListing.parse(result.content)
        XCTAssertNotNil(listing, result.content)
        XCTAssertTrue(listing!.files.contains { $0.name == "hello.txt" && $0.size > 0 },
                      "Expected hello.txt with size; got \(listing!.entries)")
        XCTAssertTrue(listing!.directories.contains { $0.name == "subdir" })
        XCTAssertNotNil(listing!.files.first { $0.name == "hello.txt" }?.modified)
    }
}
