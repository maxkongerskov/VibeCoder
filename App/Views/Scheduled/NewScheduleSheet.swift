//
//  NewScheduleSheet.swift
//  AgentOS — Claude Edition
//
//  Create a scheduled task: name, the prompt to run, how often, at what
//  time of day, and an optional project folder. Mirrors NewProjectSheet's
//  visual language. Validates a non-empty name + prompt before Create so
//  we never persist the old empty "New conversation" ghost task.
//

import SwiftUI
import AppKit
import AgentCore

@MainActor
struct NewScheduleSheet: View {

    @Binding var isPresented: Bool
    /// Called with the assembled task when the user taps Create. The parent
    /// persists it via `ScheduledTasksViewModel.add`.
    var onCreate: (ScheduledTask) -> Void = { _ in }

    @State private var name: String = ""
    @State private var prompt: String = ""
    @State private var frequency: TaskFrequency = .daily
    @State private var timeOfDay: Date = Calendar.current
        .date(from: DateComponents(hour: 2, minute: 0)) ?? Date()
    @State private var projectFolder: URL? = nil

    /// Time-of-day only applies to day-based frequencies.
    private var showsTime: Bool {
        frequency == .daily || frequency == .weekdays || frequency == .weekly
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().foregroundColor(Theme.Palette.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m + 2) {
                    field("Name", required: true) {
                        TextField("e.g. Morning news digest", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }

                    field("Task", required: true) {
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $prompt)
                                .font(.system(size: 12))
                                .frame(minHeight: 90)
                                .padding(Theme.Spacing.xs + 2)
                                .scrollContentBackground(.hidden)
                                .background(Theme.Palette.surface)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                                        .stroke(Theme.Palette.divider, lineWidth: 0.5)
                                )
                            if prompt.isEmpty {
                                Text("What should the agent do each time this runs?")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.Palette.tertiary)
                                    .padding(.horizontal, Theme.Spacing.s + 4)
                                    .padding(.vertical, Theme.Spacing.s + 4)
                                    .allowsHitTesting(false)
                            }
                        }
                    }

                    field("Frequency") {
                        Picker("", selection: $frequency) {
                            ForEach(TaskFrequency.allCases) { freq in
                                Text(freq.label).tag(freq)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    if showsTime {
                        field("Time of day") {
                            DatePicker("", selection: $timeOfDay, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.field)
                                .labelsHidden()
                            Text("Runs at this time. If the Mac is asleep, it runs when it next wakes with \(AppBranding.displayName) open.")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Palette.tertiary)
                        }
                    }

                    field("Project folder (optional)") {
                        Button(action: pickFolder) {
                            HStack(spacing: Theme.Spacing.s) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.Palette.accent)
                                Text(projectFolder?.path ?? "Run in a specific folder…")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.primary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer()
                                if projectFolder != nil {
                                    Button("Clear") { projectFolder = nil }
                                        .font(.system(size: 11))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Theme.Palette.tertiary)
                                }
                            }
                            .padding(Theme.Spacing.s + 2)
                            .background(Theme.Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Theme.Spacing.l - 4)
            }
            Divider().foregroundColor(Theme.Palette.divider)
            footer
        }
        .frame(width: 520, height: 580)
        .background(Theme.Palette.canvas)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Palette.accent)
            Text("New schedule")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.primary)
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.Spacing.ml)
        .padding(.vertical, Theme.Spacing.m)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { isPresented = false }
            Button("Create", action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, Theme.Spacing.ml)
        .padding(.vertical, Theme.Spacing.m)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, required: Bool = false,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 2) {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.secondary)
                if required {
                    Text("*").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.error)
                }
            }
            content()
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true   // show the "New Folder" button
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { projectFolder = url }
    }

    private func create() {
        let mins: Int? = showsTime ? Self.minutesAfterMidnight(timeOfDay) : nil
        let task = ScheduledTask(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            shortPrompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            projectFolder: projectFolder?.path,
            frequency: frequency,
            timeOfDayMinutes: mins,
            setupComplete: true
        )
        onCreate(task)
        isPresented = false
    }

    private static func minutesAfterMidnight(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
