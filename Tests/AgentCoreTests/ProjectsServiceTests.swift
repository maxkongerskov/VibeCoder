//
//  ProjectsServiceTests.swift
//
//  Covers the registry behaviour added 2026-06-10 so external folders
//  (the user pointing AgentOS at a folder they own) persist and are
//  treated safely — the bug that made "New Project → choose folder"
//  silently write into the managed root instead.
//

import XCTest
@testable import AgentCore

final class ProjectsServiceTests: XCTestCase {

    private var root: URL!          // managed root
    private var elsewhere: URL!     // stands in for the user's Desktop

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentos-projects-tests-\(UUID().uuidString)")
        root = base.appendingPathComponent("ManagedRoot")
        elsewhere = base.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: - Managed projects (existing behaviour still works)

    func testCreateManagedProjectLivesInRoot() async throws {
        let service = ProjectsService(rootURL: root)
        let project = try await service.create(named: "Alpha").get()
        XCTAssertFalse(project.isExternal)
        XCTAssertEqual(project.url.deletingLastPathComponent().standardizedFileURL.path,
                       root.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.url.path))
    }

    // MARK: - External folder registration

    func testRegisterExistingFolderPointsAtItDirectly() async throws {
        let mine = elsewhere.appendingPathComponent("Headless")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)

        let service = ProjectsService(rootURL: root)
        let project = try await service.register(existingFolder: mine).get()

        XCTAssertTrue(project.isExternal)
        XCTAssertEqual(project.url.standardizedFileURL.path, mine.standardizedFileURL.path,
                       "an external project must point AT the chosen folder, not a copy in the root")
    }

    func testRegisterIsIdempotent() async throws {
        let mine = elsewhere.appendingPathComponent("Repo")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        let service = ProjectsService(rootURL: root)

        let first = try await service.register(existingFolder: mine).get()
        let second = try await service.register(existingFolder: mine).get()
        XCTAssertEqual(first.id, second.id)
        let all = await service.projects()
        XCTAssertEqual(all.filter { $0.url.standardizedFileURL.path == mine.standardizedFileURL.path }.count, 1)
    }

    func testRegisterMissingFolderFails() async {
        let service = ProjectsService(rootURL: root)
        let result = await service.register(existingFolder: elsewhere.appendingPathComponent("nope"))
        if case .success = result { XCTFail("registering a missing folder should fail") }
    }

    // MARK: - External folders persist across "relaunch"

    func testExternalProjectSurvivesReload() async throws {
        let mine = elsewhere.appendingPathComponent("Persisted")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)

        // First service registers it and writes the registry.
        let first = ProjectsService(rootURL: root)
        _ = try await first.register(existingFolder: mine).get()

        // A fresh service (simulating relaunch) must still see it — the
        // old scan-only implementation lost external folders here.
        let second = ProjectsService(rootURL: root)
        let names = await second.projects().map(\.url.standardizedFileURL.path)
        XCTAssertTrue(names.contains(mine.standardizedFileURL.path),
                      "external project must persist via the registry")
    }

    // MARK: - Delete safety

    func testDeleteExternalUnregistersButKeepsFolder() async throws {
        let mine = elsewhere.appendingPathComponent("Keepme")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try "important".write(to: mine.appendingPathComponent("data.txt"),
                              atomically: true, encoding: .utf8)
        let service = ProjectsService(rootURL: root)
        let project = try await service.register(existingFolder: mine).get()

        _ = await service.delete(project)

        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path),
                      "deleting an external project must NOT delete the user's folder")
        let remaining = await service.projects()
        XCTAssertFalse(remaining.contains { $0.id == project.id })
    }

    func testDeleteManagedRemovesFolder() async throws {
        let service = ProjectsService(rootURL: root)
        let project = try await service.create(named: "Disposable").get()
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.url.path))

        _ = await service.delete(project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.url.path),
                       "deleting a managed project removes its folder")
    }

    // MARK: - Rename safety

    func testRenameExternalRelabelsWithoutMovingFolder() async throws {
        let mine = elsewhere.appendingPathComponent("Original")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        let service = ProjectsService(rootURL: root)
        let project = try await service.register(existingFolder: mine).get()

        let renamed = try await service.rename(project, to: "Nicer Label").get()
        XCTAssertEqual(renamed.name, "Nicer Label")
        XCTAssertEqual(renamed.url.standardizedFileURL.path, mine.standardizedFileURL.path,
                       "renaming an external project must not move the user's folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path))
    }

    // MARK: - Create-in-location

    func testCreateInExternalLocationIsExternal() async throws {
        let service = ProjectsService(rootURL: root)
        let project = try await service.create(named: "Sub", in: elsewhere).get()
        XCTAssertTrue(project.isExternal)
        XCTAssertEqual(project.url.deletingLastPathComponent().standardizedFileURL.path,
                       elsewhere.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.url.path))
    }

    // MARK: - Seeding (instructions + starter files)

    func testSeedWritesInstructionsFile() async throws {
        let service = ProjectsService(rootURL: root)
        let project = try await service.create(named: "Seeded").get()

        let warnings = await service.seed(at: project.url,
                                          instructions: "Use SwiftUI. Run tests.",
                                          fileURLs: [])
        XCTAssertTrue(warnings.isEmpty)
        let instructionsPath = project.url
            .appendingPathComponent(".agentos/instructions.md").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: instructionsPath))
        let written = try String(contentsOfFile: instructionsPath, encoding: .utf8)
        XCTAssertEqual(written, "Use SwiftUI. Run tests.")
    }

    func testSeedCopiesStarterFiles() async throws {
        // A couple of source files sitting "elsewhere" to seed from.
        let srcA = elsewhere.appendingPathComponent("spec.md")
        let srcB = elsewhere.appendingPathComponent("notes.txt")
        try "spec".write(to: srcA, atomically: true, encoding: .utf8)
        try "notes".write(to: srcB, atomically: true, encoding: .utf8)

        let service = ProjectsService(rootURL: root)
        let project = try await service.create(named: "WithFiles").get()
        let warnings = await service.seed(at: project.url, instructions: "", fileURLs: [srcA, srcB])

        XCTAssertTrue(warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.url.appendingPathComponent("spec.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.url.appendingPathComponent("notes.txt").path))
        // Originals untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcA.path))
    }

    func testSeedSkipsExistingFileWithWarning() async throws {
        let src = elsewhere.appendingPathComponent("dup.txt")
        try "new".write(to: src, atomically: true, encoding: .utf8)

        let service = ProjectsService(rootURL: root)
        let project = try await service.create(named: "DupTest").get()
        // Pre-existing file with the same name in the project.
        try "original".write(to: project.url.appendingPathComponent("dup.txt"),
                             atomically: true, encoding: .utf8)

        let warnings = await service.seed(at: project.url, instructions: "", fileURLs: [src])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("dup.txt"))
        // The existing file was NOT overwritten.
        let content = try String(contentsOfFile: project.url.appendingPathComponent("dup.txt").path,
                                 encoding: .utf8)
        XCTAssertEqual(content, "original")
    }

    func testSeedEmptyInstructionsWritesNoFile() async throws {
        let service = ProjectsService(rootURL: root)
        let project = try await service.create(named: "NoInstructions").get()
        _ = await service.seed(at: project.url, instructions: "   ", fileURLs: [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.url.appendingPathComponent(".agentos/instructions.md").path))
    }

    // MARK: - Migration

    func testPreRegistryManagedFoldersAreMigrated() async throws {
        // A managed folder created on disk BEFORE any registry exists
        // (as the old scan-only service would have left things).
        let legacy = root.appendingPathComponent("LegacyProject")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

        let service = ProjectsService(rootURL: root)
        let all = await service.projects()
        XCTAssertTrue(all.contains { $0.url.standardizedFileURL.path == legacy.standardizedFileURL.path },
                      "pre-registry managed folders must be picked up by migration")
    }
}
