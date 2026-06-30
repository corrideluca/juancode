// Settings → Sessions pane: auto-close idle sessions. Kill (but keep, resumable)
// any running session with no output for the chosen duration, so unused agents stop
// holding a live pty. The duration is editable; the toggle off (0 min) disables it
// entirely. Backed by `AppModel.autoCloseIdleMinutes`; the work runs on the health
// loop (see `autoCloseIdleSessions`). Surfaced via the standard ⌘, window.

import SwiftUI

struct SessionSettingsView: View {
    @Environment(AppModel.self) private var model

    /// Draft minutes the stepper edits, kept separate from the model so toggling the
    /// feature off (which sets the model to 0) doesn't lose the chosen duration.
    @State private var minutes = 60

    private var enabled: Bool { model.autoCloseIdleMinutes > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sessions").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Automatically close idle sessions", isOn: Binding(
                    get: { enabled },
                    set: { model.autoCloseIdleMinutes = $0 ? minutes : 0 }))

                HStack(spacing: 8) {
                    Text("Close after")
                    Stepper(value: $minutes, in: 5...1440, step: 5) {
                        Text("\(minutes) min").monospacedDigit()
                    }
                    .fixedSize()
                    .onChange(of: minutes) { _, m in
                        if enabled { model.autoCloseIdleMinutes = m }
                    }
                    Text("of inactivity")
                }
                .disabled(!enabled)
                .foregroundStyle(enabled ? .primary : .secondary)
            }
            .padding(16)

            Spacer()

            Divider()
            Text("Stops the agent and frees its pty so an unused session isn't held "
                + "open. The session stays in the list and can be resumed later. "
                + "“No output” for the chosen time counts as inactive — a session "
                + "that's actively working is never closed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 520, height: 420)
        .onAppear { if enabled { minutes = model.autoCloseIdleMinutes } }
    }
}
