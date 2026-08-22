import SwiftUI
import SpeechLocalCore

/// The meeting window's contents: past meetings down the side, the live one in
/// the middle.
///
/// Two panes while recording, because the point of the thing is that both
/// happen at once — you type what matters, it hears everything else.
struct NotesView: View {
    @ObservedObject var model: NotesModel

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
            detail.frame(minWidth: 520)
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    // MARK: Past meetings

    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.past) { meeting in
                    Button { model.select(meeting) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.displayTitle)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(meeting.startedAt, style: .date)
                                if meeting.filedAt != nil {
                                    Image(systemName: "tray.and.arrow.down.fill")
                                        .help("Filed in the vault")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(model.selected?.id == meeting.id
                                       ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            Task { await model.delete(meeting) }
                        }
                    }
                }
            }
            .overlay {
                if model.past.isEmpty {
                    Text("No meetings yet").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: The meeting

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.isRecording || model.phase == .finishing {
                live
            } else {
                finished
            }
            if let status = model.status {
                Divider()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.toggleRecording() }
            } label: {
                Label(model.isRecording ? "Stop" : "Record",
                      systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .disabled(model.phase == .finishing || model.phase == .summarising)

            TextField("Untitled meeting", text: $model.title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))

            Spacer()

            if model.isRecording {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text(Self.clock(model.elapsed)).monospacedDigit()
                    if !model.capturingSystemAudio {
                        Image(systemName: "mic")
                            .help("Microphone only — system audio unavailable")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            } else if let progress = model.progress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress.total > 1
                         ? "\(progress.stage) \(progress.done)/\(progress.total)"
                         : progress.stage)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    /// While it runs: notes on the left, what it is hearing on the right.
    private var live: some View {
        HSplitView {
            pane("Your notes") {
                TextEditor(text: $model.notes)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
            }
            pane("Heard so far") {
                ScrollView {
                    Text(model.transcript.isEmpty ? "Listening…" : model.transcript)
                        .font(.system(size: 12))
                        .foregroundStyle(model.transcript.isEmpty ? .tertiary : .secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
            }
        }
    }

    /// Afterwards: the note, with the transcript underneath it.
    private var finished: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !model.summary.isEmpty {
                    section("Note") {
                        Text(model.summary)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("Copy note") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.summary, forType: .string)
                        }
                        Button("File in second brain") {
                            Task { await model.fileToVault() }
                        }
                        Spacer()
                    }
                }
                if !model.notes.isEmpty {
                    section("Your notes") {
                        Text(model.notes).font(.system(size: 12))
                    }
                }
                if !model.transcript.isEmpty {
                    section("Transcript") {
                        Text(model.transcript)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if model.summary.isEmpty && model.transcript.isEmpty {
                    Text("Press Record and start talking. Type notes while it runs — "
                         + "the summary is built from what you wrote, with the "
                         + "transcript filling in the rest.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: 420, alignment: .leading)
                        .padding(.top, 30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private func pane<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
