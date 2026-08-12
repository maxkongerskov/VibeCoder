import XCTest
import AgentCore
@testable import VibeCoderApp

final class ProjectFileTreeBuilderTests: XCTestCase {
    func testBuildsNestedDirectoriesAndFiles() {
        let candidates = [
            ProjectFileCandidate(path: "/p/App/Foo.swift", relativePath: "App/Foo.swift", displayName: "Foo.swift"),
            ProjectFileCandidate(path: "/p/App/Views/Bar.swift", relativePath: "App/Views/Bar.swift", displayName: "Bar.swift"),
        ]
        let tree = FileTreeNode.build(from: candidates)
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "App")
        XCTAssertTrue(tree[0].isDirectory)
        let views = tree[0].children.first { $0.name == "Views" }
        XCTAssertNotNil(views)
        XCTAssertEqual(views?.children.first?.relativePath, "App/Views/Bar.swift")
    }
}