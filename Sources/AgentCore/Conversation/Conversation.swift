//
//  Conversation.swift
//
//  Persisted shape of a chat. The original AgentOS stored one JSON file
//  per conversation under Application Support — we keep that format
//  (decode-compatible) so users can migrate without data loss.
//
//  All fields use `decodeIfPresent` + default fallbacks. Adding a new
//  field never wipes existing state.
//

import Foundation


/// Persisted sticky @-context pin (file/folder/symbol). Re-injected each turn.
public struct StickyContextPinRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// "file" | "folder" | "symbol"
    public var kind: String
    public var path: String
    public var displayName: String
    public var symbolName: String?
    public var byteSize: Int?

    public init(id: UUID = UUID(),
                kind: String,
                path: String,
                displayName: String,
                symbolName: String? = nil,
                byteSize: Int? = nil) {
        self.id = id
        self.kind = kind
        self.path = path
        self.displayName = displayName
        self.symbolName = symbolName
        self.byteSize = byteSize
    }
}

public struct Conversation: Codable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]

    /// The model selected at conversation creation. May be changed mid-
    /// conversation; we don't rewrite history when that happens.
    public var modelID: String?

    /// Optional path bound to this conversation. When set, MEMORY.md /
    /// DECISIONS.md auto-inject from this folder. nil means "untethered".
    public var projectRoot: URL?

    /// Worktree branch name when worktree mode is on; nil otherwise.
    public var worktreeBranch: String?

    /// Per-conversation override of the system prompt. nil falls through
    /// to project → global.
    public var systemPromptOverride: String?

    /// Per-conversation override of sampling params. nil falls through
    /// to project → global → catalog-recommended.
    public var samplingOverride: SamplingParams?

    /// Tools unlocked by `tool_search` during this conversation. Persists
    /// so we don't re-search across restarts.
    public var unlockedDeferredTools: [String]

    /// Floats this conversation to the top of the sidebar Recents list,
    /// above non-pinned chats. Pinned-among-pinned order falls back to
    /// `updatedAt` desc. Toggled via the sidebar context menu's "Pin"
    /// / "Unpin" item.
    public var pinned: Bool

    /// Hides this conversation from the sidebar Recents list. Stays on
    /// disk and remains accessible from the Tasks landing page (when
    /// that ships). Toggled via the sidebar context menu's "Archive"
    /// item — there's no UI yet to unarchive (lands with the Tasks
    /// view's All/Archived filters).
    public var archived: Bool

    /// Two-model mode: the orchestrator's execution plan ("brief") for a
    /// turn, keyed by the UUID string of the USER message that triggered
    /// it. Stored alongside the transcript (NOT inside `messages`, so the
    /// agent loop never re-injects it) purely so the UI can show what the
    /// orchestrator handed to the worker — collapsible in the chat. Empty
    /// for single-model conversations.
    public var orchestratorBriefs: [String: String]

    /// User override for artifact rail visibility. `nil` = auto (open on mutating tools).
    public var railUserPreference: Bool?

    /// Legacy attached skill IDs (skills feature removed). Kept so older
    /// conversation JSON still decodes; never injected into prompts.
    public var attachedSkillIds: [UUID]

    /// Sticky @ pins re-injected each turn until dismissed (survive reload).
    public var stickyContextPins: [StickyContextPinRecord]

    /// Absolute paths `read_file` recorded this conversation. Persisted so
    /// read-before-edit survives process restart (SessionReadTracker is
    /// otherwise in-memory only).
    public var sessionReadPaths: Set<String>

    public init(id: UUID = UUID(),
                title: String = "New conversation",
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                messages: [ChatMessage] = [],
                modelID: String? = nil,
                projectRoot: URL? = nil,
                worktreeBranch: String? = nil,
                systemPromptOverride: String? = nil,
                samplingOverride: SamplingParams? = nil,
                unlockedDeferredTools: [String] = [],
                pinned: Bool = false,
                archived: Bool = false,
                orchestratorBriefs: [String: String] = [:],
                railUserPreference: Bool? = nil,
                attachedSkillIds: [UUID] = [],
                stickyContextPins: [StickyContextPinRecord] = [],
                sessionReadPaths: Set<String> = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.modelID = modelID
        self.projectRoot = projectRoot
        self.worktreeBranch = worktreeBranch
        self.systemPromptOverride = systemPromptOverride
        self.samplingOverride = samplingOverride
        self.unlockedDeferredTools = unlockedDeferredTools
        self.pinned = pinned
        self.archived = archived
        self.orchestratorBriefs = orchestratorBriefs
        self.railUserPreference = railUserPreference
        self.attachedSkillIds = attachedSkillIds
        self.stickyContextPins = stickyContextPins
        self.sessionReadPaths = sessionReadPaths
    }

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, messages, modelID, projectRoot,
             worktreeBranch, systemPromptOverride,
             samplingOverride, unlockedDeferredTools,
             pinned, archived, orchestratorBriefs, railUserPreference,
             attachedSkillIds, stickyContextPins, sessionReadPaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? "New conversation"
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        self.modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        self.projectRoot = try c.decodeIfPresent(URL.self, forKey: .projectRoot)
        self.worktreeBranch = try c.decodeIfPresent(String.self, forKey: .worktreeBranch)
        // pinnedSkills was removed in the Notes pivot. Older conversation
        // JSON files on disk may still have the key; we intentionally don't
        // decode it (Codable silently ignores unknown keys), so they load
        // fine and the field is dropped on next save.
        self.systemPromptOverride = try c.decodeIfPresent(String.self, forKey: .systemPromptOverride)
        self.samplingOverride = try c.decodeIfPresent(SamplingParams.self, forKey: .samplingOverride)
        self.unlockedDeferredTools = try c.decodeIfPresent([String].self, forKey: .unlockedDeferredTools) ?? []
        self.pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        self.archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        self.orchestratorBriefs = try c.decodeIfPresent([String: String].self, forKey: .orchestratorBriefs) ?? [:]
        self.railUserPreference = try c.decodeIfPresent(Bool.self, forKey: .railUserPreference)
        self.attachedSkillIds = try c.decodeIfPresent([UUID].self, forKey: .attachedSkillIds) ?? []
        self.stickyContextPins = try c.decodeIfPresent([StickyContextPinRecord].self, forKey: .stickyContextPins) ?? []
        self.sessionReadPaths = try c.decodeIfPresent(Set<String>.self, forKey: .sessionReadPaths) ?? []
    }

    /// The on-disk path of the worktree associated with this conversation,
    /// derived deterministically from `projectRoot` + the suffix of
    /// `worktreeBranch`. Returns `nil` when worktree mode is off or
    /// either piece is missing.
    ///
    /// Convention matches `WorktreeService.createOrReuseWorktree`:
    ///   * branch = "agentcore/<shortid>"
    ///   * path   = "<projectFolder>-agentcore-<shortid>"
    public var worktreeRootURL: URL? {
        guard let project = projectRoot,
              let branch = worktreeBranch,
              !branch.isEmpty else { return nil }
        // Branch may carry an "agentcore/" prefix; strip it to get the
        // shortid. If the prefix is missing we fall back to the whole
        // branch — keeps the helper robust against renamed conventions.
        let shortid: String = {
            if let slash = branch.firstIndex(of: "/") {
                return String(branch[branch.index(after: slash)...])
            }
            return branch
        }()
        let trimmedProject = project.path.hasSuffix("/")
            ? String(project.path.dropLast())
            : project.path
        return URL(fileURLWithPath: "\(trimmedProject)-agentcore-\(shortid)")
    }
}

public struct ChatMessage: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let role: Role
    public var content: String
    /// Optional reasoning / thinking stream persisted for transcript replay.
    public var reasoningContent: String?
    public var toolCalls: [ToolCallInvocation]
    public var toolCallID: String?     // when role == .tool, the call we satisfied
    public var timestamp: Date
    /// Wall-clock seconds the agent spent on this turn (user send → finish).
    /// Set on the final assistant message of a run for "Worked for Ns" UI.
    /// Optional for back-compat with older conversation JSON.
    public var workDurationSeconds: Int?
    /// Wall-clock seconds spent in the thinking/reasoning channel for this
    /// assistant message (first thinking token → message finalize).
    /// Drives accurate "Thought for Ns" in history; optional for back-compat.
    public var thinkingDurationSeconds: Int?
    /// Vision image parts for this message (user turns). Empty for text-only.
    /// Encoded on the wire as OpenAI-style `image_url` content parts.
    public var images: [ChatImagePayload]

    public enum Role: String, Codable, Sendable, Equatable {
        case system, user, assistant, tool
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, reasoningContent, toolCalls, toolCallID, timestamp
        case workDurationSeconds, thinkingDurationSeconds, images
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        if let rawRole = try c.decodeIfPresent(String.self, forKey: .role) {
            role = Role(rawValue: rawRole) ?? .assistant
        } else {
            role = .assistant
        }
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        reasoningContent = try c.decodeIfPresent(String.self, forKey: .reasoningContent)
        toolCalls = try c.decodeIfPresent([ToolCallInvocation].self, forKey: .toolCalls) ?? []
        toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        workDurationSeconds = try c.decodeIfPresent(Int.self, forKey: .workDurationSeconds)
        thinkingDurationSeconds = try c.decodeIfPresent(Int.self, forKey: .thinkingDurationSeconds)
        images = try c.decodeIfPresent([ChatImagePayload].self, forKey: .images) ?? []
    }

    public init(id: UUID = UUID(),
                role: Role,
                content: String,
                reasoningContent: String? = nil,
                toolCalls: [ToolCallInvocation] = [],
                toolCallID: String? = nil,
                timestamp: Date = Date(),
                workDurationSeconds: Int? = nil,
                thinkingDurationSeconds: Int? = nil,
                images: [ChatImagePayload] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.timestamp = timestamp
        self.workDurationSeconds = workDurationSeconds
        self.thinkingDurationSeconds = thinkingDurationSeconds
        self.images = images
    }

    /// User-role BuildGuard / AutoVerify / memory / interjection injections.
    public var isWireOnlySystemReminder: Bool {
        role == .user && SystemReminder.isWireOnly(content)
    }

    /// Whether this message should appear as a chat bubble.
    public var appearsInTranscript: Bool {
        switch role {
        case .system, .tool:
            return false
        case .assistant:
            return true
        case .user:
            return !isWireOnlySystemReminder
        }
    }
}

extension Array where Element == ChatMessage {
    /// Last real user prompt, skipping harness system-reminder rows.
    public func lastVisibleUserIndex() -> Int? {
        lastIndex { $0.role == .user && !$0.isWireOnlySystemReminder }
    }
}

public struct ToolCallInvocation: Codable, Identifiable, Sendable, Equatable {
    public let id: String              // stable across streaming chunks
    public let name: String
    public let arguments: String       // JSON string as the model emitted it
    public init(id: String, name: String, arguments: String) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

public struct SamplingParams: Codable, Sendable, Equatable {
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var repeatPenalty: Double
    public var maxTokens: Int?

    public init(temperature: Double = 0.7,
                topP: Double = 0.95,
                topK: Int = 40,
                repeatPenalty: Double = 1.10,
                maxTokens: Int? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repeatPenalty = repeatPenalty
        self.maxTokens = maxTokens
    }

    /// Defaults tuned for code generation: lower temperature, less
    /// creative top-p. Used by the "Coder" workflow preset.
    public static let coder = SamplingParams(temperature: 0.3, topP: 0.95, topK: 40, repeatPenalty: 1.05)

    // MARK: - Model-class presets

    /// Small models (≤7B). Higher temperature to compensate for lower
    /// capacity; tighter repeat penalty to reduce looping.
    public static let small = SamplingParams(temperature: 0.4, topP: 0.95, topK: 40, repeatPenalty: 1.10)

    /// Mid-size models (8B–20B). Balanced defaults.
    public static let medium = SamplingParams(temperature: 0.3, topP: 0.95, topK: 40, repeatPenalty: 1.05)

    /// Large models (21B+). Lower temperature — big models are precise
    /// enough that extra randomness hurts more than it helps.
    public static let large = SamplingParams(temperature: 0.2, topP: 0.95, topK: 40, repeatPenalty: 1.05)

    /// Pick the right preset for a model given its parameter count.
    /// Falls back to `.medium` when the count is unknown (0).
    public static func preset(forParameterCountB count: Double) -> SamplingParams {
        switch count {
        case ..<8:   return count == 0 ? .medium : .small
        case 8..<21: return .medium
        default:     return .large
        }
    }
}
