import XCTest
@testable import AgentCore

/// Proves shipped settings decode migrates the removed llama.cpp product
/// off `.llamaCpp` onto a remaining backend (Ollama).
final class BackendMigrationTests: XCTestCase {

    func testMigratingFromRawLlamaCppYieldsOllama() {
        XCTAssertEqual(BackendIdentifier.migrating(fromRaw: "llamaCpp"), .ollama)
        XCTAssertEqual(BackendIdentifier.migrating(fromRaw: BackendIdentifier.legacyLlamaCppRawValue), .ollama)
    }

    func testDecodeBackendIdentifierLegacyLlamaCpp() throws {
        let data = Data("\"llamaCpp\"".utf8)
        let decoded = try JSONDecoder().decode(BackendIdentifier.self, from: data)
        XCTAssertEqual(decoded, .ollama)
        XCTAssertNotEqual(decoded.rawValue, "llamaCpp")
    }

    func testDecodeAppSettingsJSONWithLegacyLlamaCppBackend() throws {
        // Minimal JSON blob shaped like a persisted AppSettings slice.
        let json = """
        {
          "backend": "llamaCpp",
          "lmStudioHost": "127.0.0.1",
          "lmStudioPort": 1234,
          "lmStudioAPIKey": "",
          "lmStudioAutoConnect": true,
          "exoHost": "127.0.0.1",
          "exoPort": 52415,
          "exoModelID": "",
          "exoAutoConnect": false,
          "omlxHost": "127.0.0.1",
          "omlxPort": 8080,
          "omlxAPIKey": "",
          "ollamaHost": "127.0.0.1",
          "ollamaPort": 11434,
          "ollamaAutoConnect": false,
          "customEndpoint": "http://127.0.0.1:1234/v1",
          "customAPIKey": "",
          "defaultSampling": {
            "temperature": 0.3,
            "topP": 0.95,
            "topK": 40,
            "repeatPenalty": 1.05
          },
          "systemPrompt": "test",
          "maxAgentIterations": 30,
          "headlessMaxIterations": 100,
          "verifyEdits": true,
          "stallWindow": 3,
          "maxContextWindowTokens": 0,
          "autoCompactThresholdPercent": 70,
          "rawMode": false,
          "toolEnabled": {},
          "safeModeAllowedPaths": [],
          "safeModeAllowedShellPrefixes": [],
          "localAPIEnabled": false,
          "localAPIPort": 11435,
          "xcodeMCPEnabled": false,
          "hasCompletedOnboarding": true,
          "crashReportingEnabled": false,
          "colorScheme": "system",
          "chatFontScale": 1.0,
          "playfulWaitingLabels": false,
          "orchestratorEnabled": false,
          "orchestratorBackend": "ollama",
          "orchestratorModelID": "",
          "workerBackend": "ollama",
          "workerModelID": "",
          "orchestratorBackendSet": false,
          "workerBackendSet": false,
          "mcpServers": []
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.backend, .ollama,
                       "Persisted backend llamaCpp must migrate to ollama on decode")
        // Remaining backends still construct via factory.
        let backend = BackendFactory.make(from: settings)
        XCTAssertEqual(backend.identifier, .ollama)
    }

    func testFactoryDoesNotExposeLlamaCppCase() {
        for raw in ["ollama", "omlx", "lmStudio", "exo", "custom", "xai"] {
            let id = BackendIdentifier.migrating(fromRaw: raw)
            var s = AppSettings()
            s.backend = id
            let b = BackendFactory.make(from: s)
            XCTAssertEqual(b.identifier, id)
        }
    }
}
