//
//  ToolResult.swift  (Harness)
//
//  What a tool dispatch yields. `mutatedPaths` drives BuildGuard invalidation
//  and edit-verification (a non-empty list means "this turn changed real
//  state"). `isError` flows into the anti-confabulation error-flag window.
//

import Foundation

public struct ToolResult: Sendable, Equatable {
    public var content: String
    public var isError: Bool
    public var mutatedPaths: [String]

    public init(content: String, isError: Bool = false, mutatedPaths: [String] = []) {
        self.content = content
        self.isError = isError
        self.mutatedPaths = mutatedPaths
    }
}
