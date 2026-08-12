//
//  PendingAssistantBubble.swift
//
//  Ported from DEV PLAN (UI Iteration 2 Batch 5).
//
//  The single best UX moment in DEV PLAN: instead of a generic spinner,
//  the bubble sits in the same avatar+text position as the eventual
//  reply and crossfades through 100 shuffled phrases every ~4.2s with
//  a 0.45s ease curve. When the first stream token arrives, the
//  phrase fades out and streamed text fades in — seamless continuity.
//
//  Adapted for NEW DAY: takes a simple binding/bool instead of
//  ChatViewModel, fonts via Theme.swift, no SettingsViewModel coupling.
//

import SwiftUI
import AgentCore

// MARK: - Engine load bar (legacy slot)

/// Was a linear gradient strip under the chat header. Now intentionally
/// empty — the "thinking" indicator was moved INTO the
/// PendingAssistantBubble next to the phrase line, where it belongs
/// (you don't want a separate progress strip floating off above the
/// actual response). Kept as a 0-pt placeholder so call sites in
/// ChatView/MockChatView don't have to change.
struct EngineLoadBar: View {
    let isLoading: Bool
    var body: some View { Color.clear.frame(height: 0) }
}

// MARK: - Pending assistant bubble

struct PendingAssistantBubble: View {
    /// Buffer of streaming text. When non-empty, displays the text and
    /// suppresses the phrase cycling. When empty, cycles phrases.
    let streamBuffer: String
    let reasoningBuffer: String
    let reasoningStartedAt: Date?
    let activityLabel: String?
    let hasProcess: Bool
    let playfulLabels: Bool

    /// Font size for streamed answer body (matches persisted assistant bubbles).
    let fontSize: CGFloat

    /// Structured activity line for BuildCode-style "Verb · Status" display.
    let activityLine: ActivityLine?

    /// Live tool states for the in-flight turn (ZCode activity stack).
    var liveToolStates: [ToolCallUIState] = []

    /// Optional quiet role strip when two-model orchestration is active
    /// (e.g. "Gemma → Ornith"). Thinking phrases, Working header, and
    /// reasoning stream stay identical to single-model agent mode —
    /// this is additive chrome only, not a separate "planning mode" UI.
    var orchestrationCaption: String? = nil

    /// When true (default), strip channel/think chrome from stream for display.
    var cleanModelChrome: Bool = true

    /// Prior path→content map so rewrite/delete cards can show red − lines.
    var priorFileContents: [String: String] = [:]

    var onKillJob: ((UUID) -> Void)? = nil
    var backgroundJobs: [BackgroundJobSnapshot] = []
    var rolledBackHunkIDs: Set<UUID> = []
    var onUndoEdit: ((FileCodeEdit) -> Void)? = nil

    @State private var phrases: [String] = []
    @State private var phraseIdx: Int = 0
    @State private var phraseVisible: Bool = true

    private let phraseInterval: TimeInterval = 4.2

    /// Prefer dedicated reasoning_content; fall back to chrome / think tags in stream.
    private var effectiveReasoning: String {
        if !reasoningBuffer.isEmpty { return reasoningBuffer }
        return ModelChrome.present(streamBuffer, enabled: cleanModelChrome).thinking ?? ""
    }

    private var effectiveAnswer: String {
        if !reasoningBuffer.isEmpty {
            return ModelChrome.displayBody(streamBuffer, enabled: cleanModelChrome)
        }
        return ModelChrome.present(streamBuffer, enabled: cleanModelChrome).body
    }

    private var thinkTagsOpen: Bool {
        reasoningBuffer.isEmpty
            && ModelChrome.present(streamBuffer, enabled: cleanModelChrome).isThinkingOpen
    }

    private var showingStream: Bool { !effectiveAnswer.isEmpty }
    private var showingReasoning: Bool { !effectiveReasoning.isEmpty || thinkTagsOpen }
    private var showingTools: Bool { !liveToolStates.isEmpty }
    private var showingWorking: Bool {
        !showingStream && !showingReasoning && !showingTools
    }

    /// ZCode idle copy — no model names in the transcript.
    private var currentPhrase: String {
        if playfulLabels, !phrases.isEmpty {
            return phrases[phraseIdx % phrases.count]
        }
        return "Thinking…"
    }

    init(streamBuffer: String = "",
         reasoningBuffer: String = "",
         reasoningStartedAt: Date? = nil,
         activityLabel: String? = nil,
         hasProcess: Bool = false,
         playfulLabels: Bool = false,
         cleanModelChrome: Bool = true,
         fontSize: CGFloat = Theme.ChatLayout.bodyFontSize,
         activityLine: ActivityLine? = nil,
         liveToolStates: [ToolCallUIState] = [],
         orchestrationCaption: String? = nil,
         priorFileContents: [String: String] = [:],
         onKillJob: ((UUID) -> Void)? = nil,
         backgroundJobs: [BackgroundJobSnapshot] = [],
         elapsedSeconds: Int = 0,
         rolledBackHunkIDs: Set<UUID> = [],
         onUndoEdit: ((FileCodeEdit) -> Void)? = nil) {
        self.streamBuffer = streamBuffer
        self.reasoningBuffer = reasoningBuffer
        self.reasoningStartedAt = reasoningStartedAt
        self.activityLabel = activityLabel
        self.hasProcess = hasProcess
        self.playfulLabels = playfulLabels
        self.cleanModelChrome = cleanModelChrome
        self.fontSize = fontSize
        self.activityLine = activityLine
        self.liveToolStates = liveToolStates
        self.orchestrationCaption = orchestrationCaption
        self.priorFileContents = priorFileContents
        self.onKillJob = onKillJob
        self.backgroundJobs = backgroundJobs
        self.elapsedSeconds = elapsedSeconds
        self.rolledBackHunkIDs = rolledBackHunkIDs
        self.onUndoEdit = onUndoEdit
    }

    /// Live elapsed seconds for the "Working for Ns" header (from ChatView).
    var elapsedSeconds: Int = 0

    // Order: working header → optional orchestration → thinking → activity → answer.
    // Option A: no LLM speech bubbles; tool activity keeps its own chrome.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Live duration + hairline (ZCode / BuildCode work section).
            WorkingHeader(seconds: elapsedSeconds, isLive: true)

            // Two-model only: quiet "orchestrator → worker" strip.
            if let caption = orchestrationCaption, !caption.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.accent)
                    Text(caption)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Palette.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }

            // Step markers intentionally omitted — "Step 1" / iteration
            // chrome adds noise without helping the user.

            // 1) Live reasoning — expand as tokens arrive so the user can
            // read the model’s thinking before / alongside the answer.
            if showingReasoning {
                ReasoningBlockView(
                    text: effectiveReasoning,
                    // Shimmer while still in the think channel / open think tags.
                    isStreaming: (!showingStream && !showingTools) || thinkTagsOpen,
                    startedAt: reasoningStartedAt,
                    // Collapse when tools/answer take over (user can still expand).
                    preferCollapsed: (showingStream || showingTools) && !thinkTagsOpen,
                    fontSize: fontSize
                )
                .transition(.opacity)
            }

            // 2) Activity stack + inline edit cards (same partition as history)
            if showingTools {
                let parts = ChatToolPartition.split(
                    liveToolStates,
                    seedContents: priorFileContents
                )
                if !parts.activity.isEmpty {
                    ZCodeActivityStack(
                        states: parts.activity,
                        isStreaming: true,
                        onKillJob: onKillJob,
                        backgroundJobs: backgroundJobs
                    )
                    .transition(.opacity)
                }
                ForEach(parts.edits) { edit in
                    InlineEditCardView(
                        edit: edit,
                        preferExpanded: true,
                        isUndone: !edit.hunkIDs.isEmpty
                            && edit.hunkIDs.allSatisfy { rolledBackHunkIDs.contains($0) },
                        onUndo: edit.canUndo ? { onUndoEdit?(edit) } : nil
                    )
                    .transition(.opacity)
                }
            } else if let line = activityLine {
                HStack(spacing: 6) {
                    Image(systemName: line.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.Palette.activityVerb)
                    Text(line.verb)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Palette.activityVerb)
                    Text("·")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Theme.Palette.activityDivider)
                    Text(line.status)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.Palette.activityStatus)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ProgressView().controlSize(.mini)
                }
            }

            // 3) Streaming answer OR idle "Thinking…"
            if showingStream {
                MarkdownTextView(text: effectiveAnswer,
                                 isStreaming: true,
                                 fontSize: fontSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else if showingWorking {
                thinkingIdleLine
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: showingStream)
        .animation(.easeOut(duration: 0.2), value: liveToolStates.count)
        // No horizontal inset — history MessageBubbleViewV2 is full fluid
        // column; ±16 here made live thinking/tools jump wider on commit.
    }

    /// Idle state: shimmer phrase only (no terminal `>_` mark).
    /// No model names — identity lives in the header / two-model strip only.
    @ViewBuilder private var thinkingIdleLine: some View {
        HStack(spacing: 8) {
            ShimmerText(currentPhrase, font: Theme.Typography.uiMedium)
            Spacer(minLength: 0)
        }
        .opacity(phraseVisible ? 1 : 0)
        .task(id: playfulLabels ? "pending-phrases" : "thinking-idle") {
            guard playfulLabels else { return }
            phrases = ThinkingPhrases.all.shuffled()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(phraseInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        phraseVisible = false
                    }
                }
                try? await Task.sleep(nanoseconds: 380_000_000)
                if Task.isCancelled { break }
                await MainActor.run {
                    phraseIdx += 1
                    withAnimation(.easeInOut(duration: 0.45)) {
                        phraseVisible = true
                    }
                }
            }
        }
    }

}

// MARK: - Thinking phrases (100 of them)
//
// Ported verbatim from DEV PLAN's ChatView.swift.

enum ThinkingPhrases {
    static let all: [String] = [
        // Starting up
        "Thinking...",
        "Warming up...",
        "Booting up the brain...",
        "Gathering thoughts...",
        "Loading neurons...",
        "Putting on my thinking cap...",
        "Powering on...",
        "Spinning up...",
        "Stretching the synapses...",
        "Calibrating focus...",

        // Working
        "Still thinking...",
        "Working on it...",
        "Crunching the numbers...",
        "Stitching ideas together...",
        "Connecting the dots...",
        "Reading between the lines...",
        "Consulting the archives...",
        "Cross-checking my logic...",
        "Mixing the ingredients...",
        "Sketching the outline...",
        "Drafting the answer...",
        "Picking the right words...",
        "Mapping the terrain...",
        "Charting the course...",
        "Following the thread...",

        // Personality
        "I'm cracking this...",
        "Hmm, interesting...",
        "Cooking something good...",
        "Brewing something good...",
        "Following a hunch...",
        "Asking the rubber duck...",
        "Negotiating with the muse...",
        "Hunting down the answer...",
        "Spelunking through ideas...",
        "Caffeinating my circuits...",
        "Threading the needle...",
        "Untangling the knot...",
        "Sharpening the pencil...",
        "Polishing the response...",
        "Adding the magic touch...",
        "Adjusting the lens...",
        "Lighting the path...",
        "Reading the room...",

        // Coder-themed
        "Compiling thoughts...",
        "Parsing your request...",
        "Refactoring my approach...",
        "Running through the logic...",
        "Type-checking my answer...",
        "Tracing the path...",
        "Debugging my brain...",
        "Resolving dependencies...",
        "Checking out the codebase...",
        "Merging branches of thought...",
        "Pushing the latest...",
        "Running the tests...",
        "All green so far...",
        "Linting my reasoning...",
        "Tracing the call stack...",
        "Reading the docs...",
        "Building the answer...",
        "Loading the response...",

        // Encouragement / patience
        "Almost there...",
        "Just need a sec...",
        "Don't worry, I'm on it...",
        "Just a moment more...",
        "Trust me on this one...",
        "Good answers take time...",
        "Worth the wait, promise...",
        "Going the extra mile...",
        "Doing it right, not just fast...",
        "Sharpening the focus...",
        "Last mile...",
        "Coming right up...",
        "Almost done baking...",
        "Pulling it together...",
        "Wrapping it up...",
        "Tying the loose ends...",
        "Adding finishing touches...",
        "Triple-checking...",
        "Reviewing one more time...",
        "Just one more pass...",

        // Tough-one acknowledgments
        "This one's a brain-teaser...",
        "Tough one — working it out...",
        "Cracking the puzzle...",
        "Picking apart the problem...",
        "Finding the right angle...",
        "Untying the knots...",
        "Smoothing the edges...",
        "Tuning the response...",
        "Calibrating the answer...",

        // Whimsy
        "Counting to three...",
        "Picking up steam...",
        "Hitting my stride...",
        "Pulling at a string...",
        "Spotting the pattern...",
        "Sniffing out the answer...",
        "On the trail...",
        "Closing in...",
        "Crossing the t's...",
        "Dotting the i's...",
        "Catching my breath...",
        "Catching the wave...",
        "Finding my footing...",
        "Drawing the lines...",
        "Filling in the details...",
        "Sealing the envelope...",
    ]
}
