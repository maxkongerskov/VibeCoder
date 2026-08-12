//
//  ResponseNormalizer.swift
//
//  Shared normalize() seam: bucket native tool_call fragments by index,
//  then fall back to InlineToolCallParser when native calls are empty.
//  Used by AgentLoop (production) and Harness StreamAssembler (tests).
//

import Foundation

public enum ResponseNormalizer {

    public struct PartialCall: Sendable {
        public var id: String
        public var name: String
        public var arguments: String

        public init(id: String = "", name: String = "", arguments: String = "") {
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    public struct Result: Sendable {
        public let content: String
        public let toolCalls: [ToolCallInvocation]
        public let usedInlineFallback: Bool

        public init(content: String, toolCalls: [ToolCallInvocation], usedInlineFallback: Bool) {
            self.content = content
            self.toolCalls = toolCalls
            self.usedInlineFallback = usedInlineFallback
        }
    }

    /// Mutable accumulator for streaming ingestion — single implementation
    /// for native tool_call bucketing shared by AgentLoop and StreamAssembler.
    public struct Accumulator: Sendable {
        public var content = ""
        public var buckets: [Int: PartialCall] = [:]
        public var order: [Int] = []

        public init() {}

        public mutating func ingestContentDelta(_ delta: String) {
            content += delta
        }

        public mutating func ingestToolCallDelta(
            index: Int,
            id: String?,
            name: String?,
            argumentsAppend: String?
        ) {
            if buckets[index] == nil {
                buckets[index] = PartialCall()
                order.append(index)
            }
            var current = buckets[index]!
            if let id, !id.isEmpty, current.id.isEmpty { current.id = id }
            if let name, !name.isEmpty {
                if current.name.isEmpty {
                    current.name = name
                } else if name.hasPrefix(current.name) || current.name.hasPrefix(name) {
                    // Fragment overlap or server re-sending the full name each delta.
                    // Keep whichever name is longer — avoids concatenating a shorter
                    // fragment onto an already-complete name (e.g. "read_file" + "re").
                    current.name = name.count > current.name.count ? name : current.name
                } else {
                    current.name += name
                }
            }
            if let argumentsAppend { current.arguments += argumentsAppend }
            buckets[index] = current
        }

        public func finalize() -> Result {
            ResponseNormalizer.finalize(
                content: content,
                buckets: buckets,
                orderedIndices: order)
        }
    }

    /// Finalize accumulated stream state into normalized assistant content
    /// and tool calls. `orderedIndices` preserves fragment arrival order;
    /// when nil, indices are sorted numerically.
    public static func finalize(
        content: String,
        buckets: [Int: PartialCall],
        orderedIndices: [Int]? = nil
    ) -> Result {
        let indices = orderedIndices ?? buckets.keys.sorted()
        var native: [ToolCallInvocation] = []
        for index in indices {
            guard let p = buckets[index] else { continue }
            let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let id = p.id.isEmpty ? "call_\(index)" : p.id
            let args = p.arguments.isEmpty ? "{}" : p.arguments
            native.append(ToolCallInvocation(id: id, name: name, arguments: args))
        }

        if !native.isEmpty {
            return Result(
                content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                toolCalls: native,
                usedInlineFallback: false)
        }

        let parsed = InlineToolCallParser.extract(from: content)
        return Result(
            content: parsed.cleaned,
            toolCalls: parsed.calls,
            usedInlineFallback: !parsed.calls.isEmpty)
    }
}