//
//  DirectoryListingTableView.swift
//
//  ZCode-style File | Size | Modified table for list_directory results.
//

import SwiftUI
import AgentCore

struct DirectoryListingTableView: View {
    let listing: DirectoryListing

    private static let modFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !listing.path.isEmpty, listing.path != "." {
                Text(listing.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !listing.files.isEmpty {
                Text("Regular files")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.secondary)
                fileTable(listing.files)
            }

            if !listing.directories.isEmpty {
                Text("Directories")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.secondary)
                    .padding(.top, listing.files.isEmpty ? 0 : 4)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(listing.directories) { dir in
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Palette.tertiary)
                            Text(dir.name + "/")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.Palette.primary)
                        }
                    }
                }
            }

            if listing.entries.isEmpty {
                Text("Empty folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.secondary)
            }

            Text("Total: \(listing.entries.count) entries")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Palette.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.Palette.muted.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fileTable(_ files: [DirectoryListing.Entry]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("File")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Size")
                    .frame(width: 72, alignment: .trailing)
                Text("Modified")
                    .frame(width: 96, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Palette.tertiary)
            .padding(.vertical, 4)

            Divider().opacity(0.4)

            ForEach(files) { file in
                HStack(alignment: .firstTextBaseline) {
                    Text(file.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.Palette.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(file.size > 0 ? DirectoryListing.formatByteSize(file.size) : "—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.Palette.secondary)
                        .frame(width: 72, alignment: .trailing)
                    Text(file.modified.map { Self.modFormatter.string(from: $0) } ?? "—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.Palette.secondary)
                        .frame(width: 96, alignment: .trailing)
                }
                .padding(.vertical, 3)
            }
        }
    }
}
