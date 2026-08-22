//
//  EvalRunner — minimal headless CLI for Evals/eval.sh
//
//  Thin wrapper around AgentCore.AgentLoop. Replaces the removed `agentos`
//  product so the eval harness can drive a real tool loop against any
//  OpenAI-compatible backend (llama-server, LM Studio, mock_openai_server).
//
//  CLI surface (kept compatible with Evals/eval.sh):
//
//    eval-runner run "<prompt>" \
//      --backend llama|lmstudio|exo|ollama|custom \
//      --project <path> \
//      --max-iterations <n> \
//      [--model <id>] [--port <n>] [--base-url <url>] \
//      [--xcode-mcp] \
//      [--json-events] \
//      [--resume <conversation.json>] \
//      [--save-conversation <path>]
//

import Foundation
import AgentCore
import EvalRunnerLib

@main
struct EvalRunnerMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else {
            Self.printUsage(to: FileHandle.standardError)
            exit(2)
        }
        switch cmd {
        case "run":
            do {
                let code = try await Self.run(Array(args.dropFirst()))
                exit(Int32(code))
            } catch let e as RunnerError {
                fputs("eval-runner error: \(e)\n", stderr)
                switch e {
                case .badArg: exit(2)
                case .agentFailed: exit(1)
                }
            } catch let e as EvalRunnerLibError {
                fputs("eval-runner error: \(e)\n", stderr)
                exit(1)
            } catch {
                fputs("eval-runner error: \(error)\n", stderr)
                exit(1)
            }
        case "-h", "--help", "help":
            Self.printUsage(to: FileHandle.standardOutput)
            exit(0)
        default:
            fputs("unknown command: \(cmd)\n", stderr)
            Self.printUsage(to: FileHandle.standardError)
            exit(2)
        }
    }

    // MARK: - run

    /// Returns process exit code: 0 ok, 1 agent error, 2 bad args (thrown).
    @discardableResult
    private static func run(_ args: [String]) async throws -> Int {
        var prompt: String?
        var backendName = "llama"
        var projectPath: String?
        var maxIterations = 40
        var modelID: String?
        var port: Int?
        var baseURLRaw: String?
        var xcodeMCP = false
        var jsonEvents = false
        var resumePath: String?
        var saveConversationPath: String?
        // Eval CI default: short request timeout so dead backends fail fast
        // instead of hanging ~10 min (URLSession 600s × retries).
        var requestTimeout: TimeInterval = 30
        // Accepted for eval.sh compatibility; orchestrator path is not
        // implemented in this thin runner (single-model only).
        var _orchBackend: String?
        var _orchModel: String?
        var _orchPort: Int?

        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("-") {
                switch a {
                case "--backend":
                    backendName = try Self.requireValue(args, &i, flag: a)
                case "--project":
                    projectPath = try Self.requireValue(args, &i, flag: a)
                case "--max-iterations", "--max-iter":
                    let v = try Self.requireValue(args, &i, flag: a)
                    guard let n = Int(v), n > 0 else {
                        throw RunnerError.badArg("\(a) expects a positive integer")
                    }
                    maxIterations = n
                case "--model":
                    modelID = try Self.requireValue(args, &i, flag: a)
                case "--port":
                    let v = try Self.requireValue(args, &i, flag: a)
                    guard let n = Int(v) else {
                        throw RunnerError.badArg("--port expects an integer")
                    }
                    port = n
                case "--base-url":
                    baseURLRaw = try Self.requireValue(args, &i, flag: a)
                case "--request-timeout":
                    let v = try Self.requireValue(args, &i, flag: a)
                    guard let n = Double(v), n > 0 else {
                        throw RunnerError.badArg("--request-timeout expects a positive number of seconds")
                    }
                    requestTimeout = n
                case "--orchestrator-backend":
                    _orchBackend = try Self.requireValue(args, &i, flag: a)
                case "--orchestrator-model":
                    _orchModel = try Self.requireValue(args, &i, flag: a)
                case "--orchestrator-port":
                    let v = try Self.requireValue(args, &i, flag: a)
                    _orchPort = Int(v)
                case "--xcode-mcp":
                    xcodeMCP = true
                case "--json-events":
                    jsonEvents = true
                case "--resume":
                    resumePath = try Self.requireValue(args, &i, flag: a)
                case "--save-conversation":
                    saveConversationPath = try Self.requireValue(args, &i, flag: a)
                default:
                    throw RunnerError.badArg("unknown flag: \(a)")
                }
                i += 1
            } else if prompt == nil {
                prompt = a
                i += 1
            } else {
                throw RunnerError.badArg("unexpected positional: \(a)")
            }
        }

        guard let prompt, !prompt.isEmpty else {
            throw RunnerError.badArg("missing prompt (usage: eval-runner run \"…\" …)")
        }
        guard let projectPath, !projectPath.isEmpty else {
            throw RunnerError.badArg("missing --project <path>")
        }

        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw RunnerError.badArg("--project is not a directory: \(projectPath)")
        }

        if _orchBackend != nil || _orchModel != nil || _orchPort != nil {
            fputs("[eval-runner] note: orchestrator flags accepted but ignored (single-model runner)\n", stderr)
        }

        let backend = try Self.makeBackend(
            name: backendName,
            port: port,
            baseURLRaw: baseURLRaw,
            requestTimeout: requestTimeout
        )

        let model = try await Self.resolveModel(
            backend: backend,
            requestedID: modelID,
            backendName: backendName
        )

        await ToolRegistry.shared.registerBuiltins()

        let disabledTools = ToolOffer.disabledNames(explicit: [:])
        let offered = await ToolRegistry.shared.schemas().filter { !disabledTools.contains($0.name) }
        let schemaJSON = offered.map(\.name).sorted().joined(separator: ",")
        let schemaBlob = (try? JSONEncoder().encode(offered)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let schemaTokenEstimate = TokenEstimator.estimate(schemaBlob)
        fputs(
            "[eval-runner] tools_on_wire=\(offered.count) schema_token_est=\(schemaTokenEstimate) names=\(schemaJSON)\n",
            stderr)

        let config = AgentLoop.Configuration(
            maxIterations: maxIterations,
            stallWindow: 3,
            verifyEdits: true,
            safeMode: nil,
            disabledToolNames: disabledTools,
            headlessMode: true,
            rawMode: false,
            xcodeMCPEnabled: xcodeMCP
        )

        let loop = AgentLoop(backend: backend, model: model, config: config)

        var conversation: Conversation
        if let resumePath {
            let loaded = try ConversationIO.load(fromPath: resumePath)
            conversation = ConversationIO.rebindProjectRoot(loaded, projectRoot: projectURL)
            if conversation.modelID == nil {
                conversation.modelID = model.id
            }
            // Sync load cannot await; seed the process-global tracker here.
            await ConversationIO.hydrateSessionReads(conversation)
            fputs("[eval-runner] resumed conversation id=\(conversation.id) messages=\(conversation.messages.count) reads=\(conversation.sessionReadPaths.count) from \(resumePath)\n", stderr)
        } else {
            conversation = Conversation(
                title: "eval",
                modelID: model.id,
                projectRoot: projectURL
            )
        }

        fputs("[eval-runner] backend=\(backendName) model=\(model.id) project=\(projectURL.path) max_iter=\(maxIterations) json_events=\(jsonEvents)\n", stderr)
        fputs("[eval-runner] prompt: \(prompt.prefix(200))\(prompt.count > 200 ? "…" : "")\n", stderr)

        let counter = ToolCallCounter()
        let runState = RunState()
        let emitJSONEvents = jsonEvents

        do {
            let result = try await loop.run(
                userMessage: prompt,
                conversation: conversation
            ) { event in
                Self.handleEvent(
                    event,
                    counter: counter,
                    runState: runState,
                    jsonEvents: emitJSONEvents
                )
            }
            conversation = result
        } catch {
            runState.markError(String(describing: error))
            if jsonEvents {
                Self.emitJSON(.error(String(describing: error)))
            }
            fputs("\n[eval-runner] agent error: \(error)\n", stderr)
            // Still try to save partial conversation if requested.
            if let saveConversationPath {
                _ = try? await ConversationIO.save(conversation, toPath: saveConversationPath)
            }
            throw RunnerError.agentFailed(String(describing: error))
        }

        if let saveConversationPath {
            try await ConversationIO.save(conversation, toPath: saveConversationPath)
            fputs("[eval-runner] saved conversation → \(saveConversationPath)\n", stderr)
        }

        let ok = !runState.hadError
        if jsonEvents {
            Self.emitJSON(.done(
                reason: runState.finishReason,
                toolCalls: counter.value,
                messages: conversation.messages.count,
                ok: ok
            ))
        } else {
            // Final assistant content (last non-tool message with prose).
            if let last = conversation.messages.last(where: {
                $0.role == ChatMessage.Role.assistant && !$0.content.isEmpty
            }) {
                print("--- assistant ---")
                print(last.content)
            }
        }
        fputs("[eval-runner] done tool_calls=\(counter.value) messages=\(conversation.messages.count) ok=\(ok)\n", stderr)

        if !ok {
            throw RunnerError.agentFailed(runState.lastError ?? "agent reported error")
        }
        return 0
    }

    // MARK: - Events → log lines / JSONL

    /// Format tool completions for Evals/eval.sh:
    ///   `grep -c '^\[[✓✗] '`
    /// When `--json-events`, machine events go to stdout; legacy markers go
    /// to stderr so JSONL stays parseable.
    private static func handleEvent(
        _ event: LoopEvent,
        counter: ToolCallCounter,
        runState: RunState,
        jsonEvents: Bool
    ) {
        if jsonEvents {
            for je in EvalJSONEvent.from(loopEvent: event) {
                Self.emitJSON(je)
            }
        }

        switch event {
        case .toolStarted(_, let name, let label):
            fputs("[eval-runner] tool start: \(name) (\(label))\n", stderr)
        case .toolCompleted(_, let name, _, let isError):
            counter.increment()
            let mark = isError ? "✗" : "✓"
            // stdout (legacy) unless JSON owns stdout
            if jsonEvents {
                fputs("[\(mark) \(name)]\n", stderr)
            } else {
                print("[\(mark) \(name)]")
                fflush(stdout)
            }
        case .toolResult(let inv, let result):
            let mark = result.isError ? "✗" : "✓"
            fputs("[eval-runner] \(mark) \(inv.name): \(result.content.prefix(120))\n", stderr)
        case .contentDelta(let s):
            if !jsonEvents, !s.isEmpty { fputs(s, stderr) }
        case .finished(let reason):
            runState.setFinishReason(reason)
            fputs("\n[eval-runner] finished: \(reason)\n", stderr)
        case .error(let description):
            runState.markError(description)
            fputs("\n[eval-runner] error: \(description)\n", stderr)
        case .stalled(let sig):
            runState.setFinishReason("stalled")
            fputs("\n[eval-runner] stalled: \(sig)\n", stderr)
        case .iterationCapHit(let cap):
            runState.setFinishReason("iteration cap \(cap)")
            fputs("\n[eval-runner] iteration cap \(cap)\n", stderr)
        case .info(let msg):
            fputs("[eval-runner] info: \(msg)\n", stderr)
        default:
            break
        }
    }

    private static func emitJSON(_ event: EvalJSONEvent) {
        do {
            let line = try event.jsonLine()
            if let data = line.data(using: .utf8) {
                FileHandle.standardOutput.write(data)
            }
            fflush(stdout)
        } catch {
            fputs("[eval-runner] json emit failed: \(error)\n", stderr)
        }
    }

    // MARK: - Backend

    private static func makeBackend(
        name: String,
        port: Int?,
        baseURLRaw: String?,
        requestTimeout: TimeInterval
    ) throws -> any InferenceBackend {
        let key = name.lowercased()
        if let baseURLRaw, !baseURLRaw.isEmpty {
            guard let url = BackendFactory.normalizeCustomEndpoint(baseURLRaw) else {
                throw RunnerError.badArg("invalid --base-url: \(baseURLRaw)")
            }
            return OpenAICompatibleBackend(
                baseURL: url, requestTimeout: requestTimeout)
        }

        switch key {
        case "llama", "llamacpp", "llama.cpp", "llama-server":
            // Historical eval default: llama-server on :8765.
            let p = port ?? 8765
            let url = URL(string: "http://127.0.0.1:\(p)/v1")!
            return OpenAICompatibleBackend(
                baseURL: url, requestTimeout: requestTimeout)
        case "lmstudio", "lm-studio", "lm_studio":
            return LMStudioBackend(
                host: "127.0.0.1",
                port: port ?? 1234,
                requestTimeout: requestTimeout)
        case "exo":
            return EXOBackend(
                host: "127.0.0.1",
                port: port ?? 52415,
                pinnedModelID: nil,
                requestTimeout: requestTimeout)
        case "ollama":
            return OllamaBackend(
                host: "127.0.0.1",
                port: port ?? 11434,
                requestTimeout: requestTimeout)
        case "unsloth", "unsloth-studio", "unsloth_studio":
            return UnslothStudioBackend(
                host: "127.0.0.1",
                port: port ?? 8888,
                requestTimeout: requestTimeout)
        case "custom", "openai", "openai-compat", "mock":
            let p = port ?? 1234
            let url = URL(string: "http://127.0.0.1:\(p)/v1")!
            return OpenAICompatibleBackend(
                baseURL: url, requestTimeout: requestTimeout)
        default:
            throw RunnerError.badArg(
                "unknown --backend \(name) (use llama|lmstudio|exo|ollama|unsloth|custom|mock)")
        }
    }

    private static func resolveModel(
        backend: any InferenceBackend,
        requestedID: String?,
        backendName: String
    ) async throws -> ModelDescriptor {
        if let requestedID, !requestedID.isEmpty {
            return ModelDescriptor(
                id: requestedID,
                displayName: requestedID,
                backend: Self.identifier(for: backendName),
                supportsTools: true
            )
        }
        if let models = try? await backend.listModels(), let first = models.first {
            return first
        }
        // Mock / empty servers: still construct a descriptor so the loop can run.
        let fallback = "default"
        fputs("[eval-runner] no models listed; using id=\(fallback)\n", stderr)
        return ModelDescriptor(
            id: fallback,
            displayName: fallback,
            backend: Self.identifier(for: backendName),
            supportsTools: true
        )
    }

    private static func identifier(for backendName: String) -> BackendIdentifier {
        switch backendName.lowercased() {
        case "lmstudio", "lm-studio", "lm_studio": return .lmStudio
        case "exo": return .exo
        case "ollama": return .ollama
        case "unsloth", "unsloth-studio", "unsloth_studio": return .unslothStudio
        default: return .custom
        }
    }

    // MARK: - Utils

    private static func requireValue(_ args: [String], _ i: inout Int, flag: String) throws -> String {
        let next = i + 1
        guard next < args.count else {
            throw RunnerError.badArg("\(flag) requires a value")
        }
        i = next
        return args[next]
    }

    private static func printUsage(to handle: FileHandle) {
        let text = """
        usage:
          eval-runner run "<prompt>" --project <dir> [options]

        options:
          --backend llama|lmstudio|exo|ollama|unsloth|custom|mock   (default: llama → :8765)
          --model <id>
          --max-iterations <n>     (default 40)
          --port <n>               override backend port
          --base-url <url>         OpenAI-compat base (implies custom)
          --request-timeout <sec>  HTTP timeout for OpenAI-compat backends (default 30)
          --xcode-mcp              enable Xcode MCP flag on the loop
          --json-events            emit JSONL on stdout: tool_call | text | done | error
          --resume <path.json>     load Conversation JSON and continue (rebounds project)
          --save-conversation <p>  write final Conversation JSON after the run
          --orchestrator-*         accepted, ignored (single-model runner)

        exit codes:
          0  agent finished without error event
          1  agent/backend error (also non-zero if .error LoopEvent)
          2  bad invocation / unknown flags

        examples:
          swift build -c release --product eval-runner
          ./.build/release/eval-runner run "hello" --backend mock --port 1234 --project /tmp/w --max-iterations 5

          # JSONL event stream (stdout is machine-only; markers go to stderr):
          ./.build/release/eval-runner run "hello" --backend mock --port 1234 --project /tmp/w \\
            --json-events --save-conversation /tmp/convo.json

          # Resume a prior conversation:
          ./.build/release/eval-runner run "continue" --backend mock --port 1234 --project /tmp/w \\
            --resume /tmp/convo.json --json-events

          # with mock server:
          python3 Evals/support/mock_openai_server.py --port 1234 --model-id mock-worker &
          ./Evals/eval.sh --backend mock --model mock-worker --filter 001

        """
        handle.write(Data(text.utf8))
    }
}

private enum RunnerError: Error, CustomStringConvertible {
    case badArg(String)
    case agentFailed(String)
    var description: String {
        switch self {
        case .badArg(let s): return s
        case .agentFailed(let s): return s
        }
    }
}

/// Thread-safe tool-call counter for the async Sendable event callback.
private final class ToolCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return n
    }
    func increment() {
        lock.lock(); n += 1; lock.unlock()
    }
}

/// Tracks finish reason + whether the loop emitted a fatal `.error` event.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var _hadError = false
    private var _lastError: String?
    private var _finishReason = "completed"
    var hadError: Bool {
        lock.lock(); defer { lock.unlock() }
        return _hadError
    }
    var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastError
    }
    var finishReason: String {
        lock.lock(); defer { lock.unlock() }
        return _finishReason
    }
    func setFinishReason(_ reason: String) {
        lock.lock()
        _finishReason = reason
        lock.unlock()
    }
    func markError(_ message: String? = nil) {
        lock.lock()
        _hadError = true
        if let message { _lastError = message }
        lock.unlock()
    }
}
