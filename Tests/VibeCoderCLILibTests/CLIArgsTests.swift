//
//  CLIArgsTests.swift
//  C1 flag parse. No AgentLoop.
//

import XCTest
import AgentCore
@testable import VibeCoderCLILib

final class CLIArgsTests: XCTestCase {
    func testCwdIsDefaultProject() throws {
        let args = try CLIArgs.parse([])
        XCTAssertEqual(
            args.project.standardizedFileURL.path,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .standardizedFileURL.path
        )
        XCTAssertNil(args.backend)
        XCTAssertNil(args.modelID)
        XCTAssertNil(args.resumeID)
    }

    func testProjectAndBackendAndModel() throws {
        let args = try CLIArgs.parse([
            "chat", "--project", "/tmp/cli-proj", "--backend", "ollama", "--model", "qwen",
        ])
        XCTAssertEqual(args.project.path, "/tmp/cli-proj")
        XCTAssertEqual(args.backend, .ollama)
        XCTAssertEqual(args.modelID, "qwen")
    }

    func testResumeUUID() throws {
        let id = UUID()
        let args = try CLIArgs.parse(["--resume", id.uuidString])
        XCTAssertEqual(args.resumeID, id)
    }

    func testUnknownFlagThrows() {
        XCTAssertThrowsError(try CLIArgs.parse(["--nope"])) { err in
            guard case CLIArgsError.unknownFlag("--nope") = err else {
                return XCTFail("expected unknownFlag, got \(err)")
            }
        }
    }

    func testBackendAliases() throws {
        XCTAssertEqual(try CLIArgs.parse(["--backend", "lmstudio"]).backend, .lmStudio)
        XCTAssertEqual(try CLIArgs.parse(["--backend", "unsloth"]).backend, .unslothStudio)
        XCTAssertEqual(try CLIArgs.parse(["--backend", "omlx"]).backend, .omlx)
        XCTAssertEqual(try CLIArgs.parse(["--backend", "exo"]).backend, .exo)
        XCTAssertEqual(try CLIArgs.parse(["--backend", "custom"]).backend, .custom)
    }

    func testMaxIterations() throws {
        let args = try CLIArgs.parse(["--max-iterations", "12"])
        XCTAssertEqual(args.maxIterations, 12)
    }

    func testMLXBackendIsRefused() {
        XCTAssertThrowsError(try CLIArgs.parse(["--backend", "mlx"])) { err in
            guard case CLIArgsError.badValue(let message) = err else {
                return XCTFail("expected badValue, got \(err)")
            }
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("mlx"),
                "refuse must name mlx: \(message)"
            )
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("stub")
                    || message.localizedCaseInsensitiveContains("not shipped"),
                "refuse must be honest that in-process MLX is a stub: \(message)"
            )
        }
        XCTAssertThrowsError(try CLIArgs.parse(["--backend", "MLX"]))
    }
}
