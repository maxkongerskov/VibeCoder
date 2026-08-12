//
//  ContextAttachment.swift
//
//  A project file attached via @-mention or the composer picker.
//

import Foundation

public struct ContextAttachment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var displayName: String
    public var byteSize: Int?

    public init(id: UUID = UUID(),
                path: String,
                displayName: String,
                byteSize: Int? = nil) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.byteSize = byteSize
    }
}