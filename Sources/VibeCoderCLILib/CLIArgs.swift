//
//  CLIArgs.swift
//  Interactive `vibecoder` CLI (C1). Flag parse only — no I/O.
//

import Foundation
import AgentCore

public enum CLIArgsError: Error, Equatable, CustomStringConvertible {
    case unknownFlag(String)
    case missingValue(String)
    case badValue(String)

    public var description: String {
        switch self {
        case .unknownFlag(let f): return "unknown flag: \(f)"
        case .missingValue(let f): return "\(f) requires a value"
        case .badValue(let m): return m
        }
    }
}

public struct CLIArgs: Equatable, Sendable {
    public var project: URL
    public var backend: BackendIdentifier?
    public var modelID: String?
    public var resumeID: UUID?
    public var maxIterations: Int?

    public init(
        project: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        backend: BackendIdentifier? = nil,
        modelID: String? = nil,
        resumeID: UUID? = nil,
        maxIterations: Int? = nil
    ) {
        self.project = project
        self.backend = backend
        self.modelID = modelID
        self.resumeID = resumeID
        self.maxIterations = maxIterations
    }

    public static func parse(_ argv: [String]) throws -> CLIArgs {
        var args = CLIArgs()
        var i = 0
        if i < argv.count, argv[i] == "chat" { i += 1 }
        while i < argv.count {
            let a = argv[i]
            if a == "-h" || a == "--help" || a == "help" {
                throw CLIArgsError.badValue("help")
            }
            guard a.hasPrefix("-") else {
                throw CLIArgsError.badValue("unexpected argument: \(a)")
            }
            switch a {
            case "--project":
                args.project = URL(fileURLWithPath: try requireValue(argv, &i, flag: a), isDirectory: true)
            case "--backend":
                args.backend = try parseBackend(try requireValue(argv, &i, flag: a))
            case "--model":
                args.modelID = try requireValue(argv, &i, flag: a)
            case "--resume":
                let raw = try requireValue(argv, &i, flag: a)
                guard let id = UUID(uuidString: raw) else {
                    throw CLIArgsError.badValue("--resume expects a UUID")
                }
                args.resumeID = id
            case "--max-iterations", "--max-iter":
                let raw = try requireValue(argv, &i, flag: a)
                guard let n = Int(raw), n > 0 else {
                    throw CLIArgsError.badValue("\(a) expects a positive integer")
                }
                args.maxIterations = n
            default:
                throw CLIArgsError.unknownFlag(a)
            }
            i += 1
        }
        return args
    }

    public static func usage() -> String {
        """
        usage: vibecoder [chat] [--project PATH] [--backend NAME] [--model ID] [--resume UUID]
        backends: lmstudio | omlx | ollama | unsloth | exo | custom
        commands: /help /exit /quit /new
        Ctrl+C cancels the current turn (returns to ›); at the prompt it exits.
        """
    }

    private static func requireValue(_ argv: [String], _ i: inout Int, flag: String) throws -> String {
        let next = i + 1
        guard next < argv.count else { throw CLIArgsError.missingValue(flag) }
        i = next
        return argv[next]
    }

    private static func parseBackend(_ raw: String) throws -> BackendIdentifier {
        switch raw.lowercased() {
        case "lmstudio", "lm-studio", "lm_studio": return .lmStudio
        case "omlx": return .omlx
        case "ollama": return .ollama
        case "unsloth", "unsloth-studio", "unsloth_studio": return .unslothStudio
        case "exo": return .exo
        case "custom", "openai", "openai-compat": return .custom
        case "mlx": return .mlx
        default:
            throw CLIArgsError.badValue("unknown --backend \(raw) (use lmstudio|omlx|ollama|unsloth|exo|custom)")
        }
    }
}
