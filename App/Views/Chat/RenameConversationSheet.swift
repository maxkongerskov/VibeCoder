//
//  RenameConversationSheet.swift
//
//  Ported verbatim-ish from DEV PLAN. Simple sheet with title text
//  field + Cancel / Rename buttons.
//

import SwiftUI

struct RenameConversationSheet: View {
    @Binding var draft: String
    let onCancel: () -> Void
    let onCommit: (String) -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.ml) {
            Text("Rename conversation")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.Palette.primary)

            TextField("Conversation title", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .onSubmit { commit() }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(width: 380)
        .background(Theme.Palette.canvas)
        .onAppear { fieldFocused = true }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}

#Preview {
    RenameConversationSheet(
        draft: .constant("Refactor auth middleware"),
        onCancel: {},
        onCommit: { _ in }
    )
}
