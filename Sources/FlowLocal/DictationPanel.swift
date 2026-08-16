import AppKit
import SwiftUI
import FlowLocalCore

/// Floating capsule near the bottom of the screen.
///
/// **Must never take focus.** A dictation app that activates its own window
/// steals first responder from the app you were typing in, which breaks
/// insertion entirely. Hence `.nonactivatingPanel`, `becomesKeyOnlyIfNeeded`,
/// and `orderFront` rather than `makeKey`.
@MainActor
final class DictationPanel {
    enum State: Equatable {
        case hidden
        case listening(mode: CleanupMode)
        case processing
        /// Nowhere to type, so the text is shown for the user to copy.
        case result(String)
        case cancelled
        case failed(String)
    }

    private let panel: NSPanel
    private let model = PanelModel()
    private var levelTimer: Timer?
    private var dismissTimer: Timer?

    var levelProvider: (() -> Double)?
    /// X button — discard the dictation in progress.
    var onCancel: (() -> Void)?
    /// Checkmark — stop listening now and process what was captured.
    var onConfirm: (() -> Void)?
    /// Undo — restore text that was just discarded.
    var onUndo: (() -> Void)?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.idle.width, height: Metrics.idle.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        model.onCancel = { [weak self] in self?.onCancel?() }
        model.onConfirm = { [weak self] in self?.onConfirm?() }
        model.onUndo = { [weak self] in
            self?.onUndo?()
            self?.show(.hidden)
        }

        let host = NSHostingView(rootView: PanelView(model: model))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    // MARK: - Metrics

    /// Deliberately small. This floats over the user's work; it should read as a
    /// status indicator, not a window.
    private enum Metrics {
        /// Always on screen, so it must be small enough to ignore.
        static let idle = CGSize(width: 58, height: 15)
        static let listening = CGSize(width: 112, height: 32)
        static let processing = CGSize(width: 112, height: 32)
        static let cancelled = CGSize(width: 232, height: 40)
        static let failed = CGSize(width: 220, height: 32)
        static let bottomInset: CGFloat = 12
    }

    // MARK: - State

    func show(_ state: State) {
        dismissTimer?.invalidate()
        if case .listening = state {} else { levelTimer?.invalidate() }

        switch state {
        case .hidden:
            // Not ordered out: the resting pill stays on screen so the app is
            // always discoverable and its state is never ambiguous.
            model.state = .hidden
            levelTimer?.invalidate()

        case .listening(let mode):
            model.state = .listening(mode: mode)
            model.level = 0
            startLevelPolling()

        case .processing:
            model.state = .processing

        case .result(let text):
            model.state = .result(text)

        case .cancelled:
            model.state = .cancelled
            model.undoProgress = 1
            startUndoCountdown()

        case .failed(let message):
            model.state = .failed(message)
            dismissTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                Task { @MainActor in self.show(.hidden) }
            }
        }

        resize(for: state)
        position()
        panel.orderFront(nil)
    }

    /// Confirms a successful insertion, then gets out of the way quickly.
    func flashInserted() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            Task { @MainActor in self.show(.hidden) }
        }
    }

    // MARK: - Geometry

    private func resize(for state: State) {
        let size: CGSize
        switch state {
        case .hidden:     size = Metrics.idle
        case .listening:  size = Metrics.listening
        case .processing: size = Metrics.processing
        case .cancelled:  size = Metrics.cancelled
        case .failed:     size = Metrics.failed
        case .result(let text):
            let lines = max(1, min(5, text.count / 60 + 1))
            size = CGSize(width: 440, height: 62 + CGFloat(lines - 1) * 17)
        }
        panel.setContentSize(size)
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + Metrics.bottomInset
        ))
    }

    private func startLevelPolling() {
        guard levelTimer == nil || !(levelTimer?.isValid ?? false) else { return }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in
                guard let provider = self.levelProvider else { return }
                self.model.level = provider()
            }
        }
    }

    /// Drives the shrinking bar under "Transcript cancelled".
    private func startUndoCountdown() {
        let total = 4.0
        let start = Date()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in
                let elapsed = Date().timeIntervalSince(start)
                self.model.undoProgress = max(0, 1 - elapsed / total)
                if elapsed >= total {
                    self.dismissTimer?.invalidate()
                    self.show(.hidden)
                }
            }
        }
    }
}

// MARK: - View model

@MainActor
final class PanelModel: ObservableObject {
    @Published var state: DictationPanel.State = .hidden
    @Published var level: Double = 0
    @Published var undoProgress: Double = 1

    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onUndo: (() -> Void)?
}

// MARK: - View

private struct PanelView: View {
    @ObservedObject var model: PanelModel
    @State private var copied = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Group {
                    if model.state == .hidden {
                        Color.clear
                    } else {
                        Capsule(style: .continuous)
                            .fill(Color(red: 0.09, green: 0.09, blue: 0.10))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                            )
                    }
                }
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: model.state)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1.2)
                .padding(2)

        case .listening(let mode):
            HStack(spacing: 5) {
                CircleButton(system: "xmark", background: .white.opacity(0.16),
                             foreground: .white.opacity(0.85)) { model.onCancel?() }
                Waveform(level: model.level,
                         tint: mode == .lightTouch ? .white : Color(red: 0.75, green: 0.6, blue: 1.0))
                    .frame(maxWidth: .infinity)
                CircleButton(system: "checkmark", background: .white,
                             foreground: .black) { model.onConfirm?() }
            }
            .padding(.horizontal, 5)

        case .processing:
            HStack(spacing: 9) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Transcribing")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 14)

        case .cancelled:
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Transcript cancelled")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer(minLength: 4)
                    Button { model.onUndo?() } label: {
                        Text("Undo")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 15)
                .frame(maxHeight: .infinity)

                // Time remaining to undo.
                GeometryReader { geo in
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: geo.size.width * model.undoProgress, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 14)
                .padding(.bottom, 5)
            }

        case .result(let text):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("No text field focused")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(.plain)
                }
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
        }
    }
}

private struct CircleButton: View {
    let system: String
    let background: Color
    let foreground: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(background)
                Image(systemName: system)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(foreground)
            }
            .frame(width: 21, height: 21)
        }
        .buttonStyle(.plain)
    }
}

/// Live input level — real feedback that the microphone is hearing you.
private struct Waveform: View {
    let level: Double
    var tint: Color = .white
    private let bars = 11

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { index in
                Capsule()
                    .fill(tint.opacity(0.9))
                    .frame(width: 2, height: height(for: index))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.07), value: level)
    }

    /// Centre bars react most, so quiet speech still reads as movement.
    private func height(for index: Int) -> CGFloat {
        let centre = Double(bars - 1) / 2
        let distance = abs(Double(index) - centre) / centre
        let falloff = 1.0 - distance * 0.6
        let amplified = min(1.0, level * 10)
        return 2.5 + CGFloat(amplified * falloff * 12)
    }
}
