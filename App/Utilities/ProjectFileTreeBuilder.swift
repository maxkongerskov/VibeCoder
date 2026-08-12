//
//  ProjectFileTreeBuilder.swift
//
//  Builds a hierarchical tree from ProjectFileIndex flat listings.
//

import Foundation
import AgentCore

struct FileTreeNode: Identifiable, Equatable {
    let id: String
    let name: String
    var children: [FileTreeNode]
    let isDirectory: Bool
    let relativePath: String?

    static func build(from candidates: [ProjectFileCandidate]) -> [FileTreeNode] {
        var rootChildren: [String: FileTreeNode] = [:]

        for candidate in candidates {
            let parts = candidate.relativePath.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            insert(parts: parts, candidate: candidate, prefix: "", into: &rootChildren)
        }

        return sortNodes(Array(rootChildren.values))
    }

    private static func insert(
        parts: [String],
        candidate: ProjectFileCandidate,
        prefix: String,
        into siblings: inout [String: FileTreeNode]
    ) {
        let head = parts[0]
        let path = prefix.isEmpty ? head : "\(prefix)/\(head)"

        if parts.count == 1 {
            siblings[head] = FileTreeNode(
                id: path,
                name: head,
                children: [],
                isDirectory: false,
                relativePath: candidate.relativePath
            )
            return
        }

        if siblings[head] == nil {
            siblings[head] = FileTreeNode(
                id: path,
                name: head,
                children: [],
                isDirectory: true,
                relativePath: nil
            )
        }
        var childMap = dictionary(from: siblings[head]!.children)
        insert(parts: Array(parts.dropFirst()), candidate: candidate, prefix: path, into: &childMap)
        siblings[head]!.children = sortNodes(Array(childMap.values))
    }

    private static func dictionary(from nodes: [FileTreeNode]) -> [String: FileTreeNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.name, $0) })
    }

    private static func sortNodes(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}