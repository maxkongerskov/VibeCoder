//
//  ScheduledLandingView.swift
//  AgentOS — Claude Edition
//
//  The "Scheduled" sidebar pane. Lists the user's schedules with their
//  cadence, when they last ran (linked straight to the conversation that
//  run produced), and Run-now / Delete actions. The "+" opens
//  NewScheduleSheet. The boot-time SchedulerService is what actually
//  fires these; this is the control surface.
//

import SwiftUI
import AgentCore

@MainActor
struct ScheduledLandingView: View {

    @EnvironmentObject private var app: AppViewModel
    @StateObject private var vm: ScheduledTasksViewModel

    @State private var showNewSheet = false
    @State private var deleteTarget: ScheduledTask? = nil

    init(viewModel: ScheduledTasksViewModel? = nil) {
        _vm = StateObject(wrappedValue: viewModel ?? ScheduledTasksViewModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if vm.tasks.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Theme.Palette.canvas)
        .task { await vm.refresh() }
        .sheet(isPresented: $showNewSheet) {
            NewScheduleSheet(isPresented: $showNewSheet) { task in
                Task { await vm.add(task) }
            }
        }
        .alert("Delete this schedule?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), presenting: deleteTarget) { task in
            Button("Delete", role: .destructive) {
                Task { await vm.delete(task) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { task in
            Text("\"\(task.name)\" will stop running. Conversations it already produced are kept.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 18))
                .foregroundStyle(Theme.Palette.accent)
            Text("Scheduled")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.Palette.primary)
            Spacer()
            Button { showNewSheet = true } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    Text("New schedule").font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, Theme.Spacing.s + 2)
                .padding(.vertical, Theme.Spacing.xs + 2)
                .foregroundStyle(Theme.Palette.primary)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.button + 1, style: .continuous)
                        .stroke(Theme.Palette.divider, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.ml + 2)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(Theme.Palette.accent.opacity(0.08)).frame(width: 140, height: 140)
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.Palette.accent)
            }
            .padding(.bottom, Theme.Spacing.l - 4)
            Text("No schedules yet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Palette.primary)
            Text("Create a schedule to run the agent hourly, daily, or on weekdays while VibeCoder is open. This is in-app scheduling — not a system LaunchAgent or background daemon. Each run opens a headless chat; notifications appear when headless mode is on.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .padding(.top, Theme.Spacing.xs + 2)
            Button { showNewSheet = true } label: {
                HStack(spacing: Theme.Spacing.xs + 2) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    Text("New schedule").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Theme.Palette.accent)
                .padding(.horizontal, Theme.Spacing.ml - 2)
                .padding(.vertical, Theme.Spacing.s)
                .background(Theme.Palette.accent.opacity(0.10))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.Palette.accent.opacity(0.35), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Spacing.ml + 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.s) {
                ForEach(vm.tasks) { task in
                    row(task)
                }
            }
            .padding(Theme.Spacing.l)
        }
    }

    private func row(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Palette.primary)
                    Text(task.scheduleDescription)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.accent)
                }
                Spacer()
                Menu {
                    Button("Run now") { runNow(task) }
                    if lastRunConversationExists(task) {
                        Button("View last run") { openLastRun(task) }
                    }
                    Divider()
                    Button(role: .destructive) { deleteTarget = task } label: { Text("Delete") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if !task.shortPrompt.isEmpty {
                Text(task.shortPrompt)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: Theme.Spacing.s) {
                Text(lastRunLabel(task))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.tertiary)
                if lastRunConversationExists(task) {
                    Button("View →") { openLastRun(task) }
                        .font(.system(size: 10, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Palette.accent)
                }
                Spacer()
                Button("Run now") { runNow(task) }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.accent)
            }
        }
        .padding(Theme.Spacing.m + 2)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card + 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card + 2, style: .continuous)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
    }

    // MARK: Helpers

    private func lastRunLabel(_ task: ScheduledTask) -> String {
        guard let last = task.lastFiredAt else { return "Never run" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return "Last run \(f.localizedString(for: last, relativeTo: Date()))"
    }

    private func lastRunConversationExists(_ task: ScheduledTask) -> Bool {
        guard let id = task.lastRunConversationID else { return false }
        return app.conversations.contains(where: { $0.id == id })
    }

    private func openLastRun(_ task: ScheduledTask) {
        guard let id = task.lastRunConversationID else { return }
        NotificationCenter.default.post(name: .openConversationRequested, object: id)
    }

    private func runNow(_ task: ScheduledTask) {
        Task {
            if let id = await app.runScheduledTask(task) {
                NotificationCenter.default.post(name: .openConversationRequested, object: id)
            }
        }
    }
}
