//
//  CLIModelProbeTests.swift
//  F2/F3: listModels is always probed. A down server never presents ›
//  (resolveModel throws before the REPL loop). --model is not a skip.
//

import XCTest
import AgentCore
@testable import VibeCoderCLILib

private struct ProbeFailure: Error, LocalizedError {
    var errorDescription: String? { "connection refused" }
}

private final class ProbeBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier
    private(set) var listCalls = 0
    private let result: Result<[ModelDescriptor], Error>

    init(identifier: BackendIdentifier, result: Result<[ModelDescriptor], Error>) {
        self.identifier = identifier
        self.result = result
    }

    func listModels() async throws -> [ModelDescriptor] {
        listCalls += 1
        return try result.get()
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancel(streamID: UUID) async {}
}

final class CLIModelProbeTests: XCTestCase {

    func testDownServerThrowsBeforePromptEvenWithModelFlag() async {
        let backend = ProbeBackend(identifier: .ollama, result: .failure(ProbeFailure()))
        do {
            _ = try await REPL.resolveModel(
                backend: backend,
                requestedID: "qwen",
                fallbackBackend: .ollama
            )
            XCTFail("F3: --model must not skip listModels when the server is down")
        } catch let err as CLIArgsError {
            guard case .badValue(let message) = err else {
                return XCTFail("expected badValue, got \(err)")
            }
            XCTAssertEqual(backend.listCalls, 1)
            XCTAssertTrue(message.contains("Ollama"), "must name the backend: \(message)")
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("start the server"),
                "must tell the user to start the server: \(message)"
            )
            XCTAssertFalse(
                message.lowercased().hasPrefix("no models"),
                "F2 honesty: a down server must not look like an empty catalog: \(message)"
            )
        } catch {
            XCTFail("expected CLIArgsError, got \(error)")
        }
    }

    func testDownServerWithoutModelDoesNotLookLikeEmptyCatalog() async {
        let backend = ProbeBackend(identifier: .lmStudio, result: .failure(ProbeFailure()))
        do {
            _ = try await REPL.resolveModel(
                backend: backend,
                requestedID: nil,
                fallbackBackend: .lmStudio
            )
            XCTFail("F2: down server must throw before ›")
        } catch let err as CLIArgsError {
            guard case .badValue(let message) = err else {
                return XCTFail("expected badValue, got \(err)")
            }
            XCTAssertEqual(backend.listCalls, 1)
            XCTAssertTrue(message.contains("LM Studio"), "must name the backend: \(message)")
            XCTAssertTrue(message.localizedCaseInsensitiveContains("start the server"))
            XCTAssertFalse(message.lowercased().hasPrefix("no models"))
        } catch {
            XCTFail("expected CLIArgsError, got \(error)")
        }
    }

    func testEmptyCatalogWithoutModelSuggestsModelFlag() async {
        let backend = ProbeBackend(identifier: .omlx, result: .success([]))
        do {
            _ = try await REPL.resolveModel(
                backend: backend,
                requestedID: nil,
                fallbackBackend: .omlx
            )
            XCTFail("empty catalog with no --model must throw")
        } catch let err as CLIArgsError {
            guard case .badValue(let message) = err else {
                return XCTFail("expected badValue, got \(err)")
            }
            XCTAssertEqual(backend.listCalls, 1)
            XCTAssertTrue(message.contains("oMLX"), "must name the backend: \(message)")
            XCTAssertTrue(message.contains("--model"))
            XCTAssertTrue(message.localizedCaseInsensitiveContains("start the server"))
        } catch {
            XCTFail("expected CLIArgsError, got \(error)")
        }
    }

    func testModelFlagUsedOnlyAfterSuccessfulProbe() async throws {
        let listed = ModelDescriptor(
            id: "listed-one",
            displayName: "Listed",
            backend: .ollama,
            supportsTools: true
        )
        let backend = ProbeBackend(identifier: .ollama, result: .success([listed]))
        let resolved = try await REPL.resolveModel(
            backend: backend,
            requestedID: "user-picked",
            fallbackBackend: .ollama
        )
        XCTAssertEqual(backend.listCalls, 1)
        XCTAssertEqual(resolved.id, "user-picked")
        XCTAssertEqual(resolved.backend, .ollama)
    }

    func testModelFlagPrefersListedMatchAfterProbe() async throws {
        let listed = ModelDescriptor(
            id: "qwen",
            displayName: "Qwen Coder",
            backend: .ollama,
            supportsTools: true
        )
        let backend = ProbeBackend(identifier: .ollama, result: .success([listed]))
        let resolved = try await REPL.resolveModel(
            backend: backend,
            requestedID: "qwen",
            fallbackBackend: .ollama
        )
        XCTAssertEqual(backend.listCalls, 1)
        XCTAssertEqual(resolved.displayName, "Qwen Coder")
    }

    func testNoModelUsesFirstListedAfterProbe() async throws {
        let first = ModelDescriptor(id: "a", displayName: "A", backend: .exo)
        let second = ModelDescriptor(id: "b", displayName: "B", backend: .exo)
        let backend = ProbeBackend(identifier: .exo, result: .success([first, second]))
        let resolved = try await REPL.resolveModel(
            backend: backend,
            requestedID: nil,
            fallbackBackend: .exo
        )
        XCTAssertEqual(backend.listCalls, 1)
        XCTAssertEqual(resolved.id, "a")
    }
}
