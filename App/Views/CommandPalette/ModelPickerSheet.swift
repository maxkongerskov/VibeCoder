//
//  ModelPickerSheet.swift
//
//  Sheet presented from the command palette "Choose Model" action.
//

import SwiftUI
import AgentCore

struct ModelPickerSheet: View {
    @Binding var selectedModelID: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Choose Model")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            ModelPickerButton(selectedModelID: $selectedModelID)
                .environmentObject(app)

            if app.availableModels.isEmpty {
                Text("No models from the active backend. Open Settings → Connection to load models.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.tertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 200)
        .background(Theme.Palette.canvas)
    }
}