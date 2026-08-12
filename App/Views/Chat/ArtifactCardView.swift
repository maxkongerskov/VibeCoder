//
//  ArtifactCardView.swift
//

import SwiftUI

struct ArtifactCardView: View {
    let card: ArtifactCard
    var isSelected: Bool
    let onSelect: () -> Void

    @State private var expanded: Bool = true
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Palette.primary)
                            .lineLimit(2)
                        if let sub = card.subtitle {
                            Text(sub)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Palette.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Palette.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Theme.Palette.accent.opacity(0.10) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                cardBody
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            Divider().opacity(0.35)
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(Theme.Palette.accent)
                    .frame(width: 2)
                    .padding(.vertical, 4)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(isSelected ? Theme.Palette.accent.opacity(0.04) : Color.clear)
        )
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : 10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { appeared = true }
        }
        .animation(.easeOut(duration: 0.2), value: isSelected)
    }

    @ViewBuilder
    private var cardBody: some View {
        switch card.kind {
        case .filePreview(let path):
            ArtifactFilePreviewView(content: card.body, path: path)
        case .diff(let path):
            ArtifactDiffView(diffText: card.body, maxHeight: 320, languageHint: path)
        case .terminal:
            ArtifactDiffView(diffText: card.body, maxHeight: 280)
        case .searchResults, .webResult, .toolOutput:
            ScrollView {
                Text(card.body.isEmpty ? card.input : card.body)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch card.status {
        case .pending:
            Circle()
                .stroke(Theme.Palette.tertiary, lineWidth: 1.5)
                .frame(width: 10, height: 10)
        case .running:
            ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.success)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.error)
        }
    }
}