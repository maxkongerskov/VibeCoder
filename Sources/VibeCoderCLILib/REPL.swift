//
//  REPL.swift
//  Interactive chat. Shared ConversationStore with the app.
//  SIGINT during a turn cancels AgentLoop (TurnRunner); idle Ctrl+C exits.
//

import Foundation
import AgentCore

public struct REPL {
    public var store: ConversationStore
    public var settings: AppSettings
    public var args: CLIArgs

    public init(store: ConversationStore, settings: AppSettings, args: CLIArgs) {
        self.store = store
        self.settings = settings
        self.args = args
    }

    public func run() async throws {
        var settings = self.settings
        if let backend = args.backend {
            settings.backend = backend
        }
        await ToolRegistry.shared.registerBuiltins()
        let backend = BackendFactory.make(from: settings)
        let model = try await Self.resolveModel(
            backend: backend,
            requestedID: args.modelID,
            fallbackBackend: settings.backend
        )

        var conversation = try await Self.loadOrCreate(
            store: store,
            args: args,
            model: model
        )
        conversation = try await Self.applyWorktree(conversation)
        conversation.modelID = model.id
        try await store.save(conversation)

        let runner = TurnRunner(
            backend: backend,
            model: model,
            settings: settings,
            maxIterations: args.maxIterations
        )

        fputs("vibecoder  model=\(model.id)  project=\(args.project.path)\n", stderr)
        if let branch = conversation.worktreeBranch {
            fputs("worktree \(branch)\n", stderr)
        }
        fputs("Type /help. Ctrl+C cancels the current turn (returns to ›); at the prompt it exits.\n", stderr)

        while true {
            fputs("› ", stdout)
            fflush(stdout)
            guard var line = readLine() else { break }
            while line.hasSuffix("\\") {
                line = String(line.dropLast())
                fputs("… ", stdout)
                fflush(stdout)
                guard let more = readLine() else { break }
                line += more
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed == "/exit" || trimmed == "/quit" {
                try await store.save(conversation)
                break
            }
            if trimmed == "/help" {
                fputs(CLIArgs.usage() + "\n", stdout)
                continue
            }
            if trimmed == "/new" {
                conversation = Conversation(
                    title: "CLI",
                    modelID: model.id,
                    projectRoot: args.project
                )
                conversation = try await Self.applyWorktree(conversation)
                try await store.save(conversation)
                fputs("new conversation \(conversation.id)\n", stderr)
                continue
            }
            await PromptHistoryStore.shared.record(trimmed)
            do {
                conversation = try await runner.runTurn(
                    userMessage: trimmed,
                    conversation: conversation
                )
                try await store.save(conversation)
            } catch is CancellationError {
                // AgentLoop returns a Conversation on cancel; this is the
                // race where the wrapper Task is cancelled before run starts.
                fputs("\n[cancelled]\n", stderr)
                do {
                    try await store.save(conversation)
                } catch {
                    fputs("save failed: \(error.localizedDescription)\n", stderr)
                }
            } catch {
                fputs("turn error: \(error.localizedDescription)\n", stderr)
                do {
                    try await store.save(conversation)
                } catch {
                    fputs("save failed: \(error.localizedDescription)\n", stderr)
                }
            }
        }
    }

    /// Always probes `listModels` before returning a descriptor (F3).
    /// A throwing probe never becomes “no models” via `try?` (F2).
    /// `--model` is applied only after the backend answers.
    static func resolveModel(
        backend: any InferenceBackend,
        requestedID: String?,
        fallbackBackend: BackendIdentifier
    ) async throws -> ModelDescriptor {
        let listed: [ModelDescriptor]
        do {
            listed = try await backend.listModels()
        } catch {
            throw CLIArgsError.badValue(unreachableMessage(backend: backend.identifier, error: error))
        }
        if let requestedID, !requestedID.isEmpty {
            if let match = listed.first(where: { $0.id == requestedID }) {
                return match
            }
            return ModelDescriptor(
                id: requestedID,
                displayName: requestedID,
                backend: fallbackBackend,
                supportsTools: true
            )
        }
        if let first = listed.first { return first }
        throw CLIArgsError.badValue(
            "no models from \(backendLabel(backend.identifier)); pass --model or start the server"
        )
    }

    static func backendLabel(_ id: BackendIdentifier) -> String {
        switch id {
        case .lmStudio: return "LM Studio"
        case .omlx: return "oMLX"
        case .ollama: return "Ollama"
        case .unslothStudio: return "Unsloth Studio"
        case .exo: return "EXO"
        case .custom: return "custom"
        case .xai: return "xAI"
        case .mlx: return "MLX"
        }
    }

    static func unreachableMessage(backend: BackendIdentifier, error: Error) -> String {
        let label = backendLabel(backend)
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "Can't reach \(label). Start the server."
        }
        return "Can't reach \(label) (\(detail)). Start the server."
    }

    static func loadOrCreate(
        store: ConversationStore,
        args: CLIArgs,
        model: ModelDescriptor
    ) async throws -> Conversation {
        if let id = args.resumeID {
            if let loaded = try await store.load(id: id) {
                return loaded
            }
            fputs("resume id not found; starting new conversation\n", stderr)
        }
        let wanted = SafeModeConfig.normalizePath(args.project.path)
        let listed = (try? await store.list()) ?? []
        let match = listed.first { convo in
            guard !convo.archived, let root = convo.projectRoot else { return false }
            return SafeModeConfig.normalizePath(root.path) == wanted
        }
        if var match {
            _ = try WorktreeService.ensureDefaultWorktreeIfNeeded(&match)
            return match
        }
        return Conversation(title: "CLI", modelID: model.id, projectRoot: args.project)
    }

    static func applyWorktree(_ conversation: Conversation) async throws -> Conversation {
        var convo = conversation
        let result = try WorktreeService.bindProjectEnablingWorktree(
            &convo, projectRoot: convo.projectRoot)
        if let reason = result.userVisibleReason {
            fputs("\(reason)\n", stderr)
        }
        return convo
    }
}
