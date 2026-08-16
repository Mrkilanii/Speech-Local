import AppKit
import SwiftUI
import SpeechLocalCore

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
    /// Undo — re-transcribe audio that was just discarded.
    var onUndo: (() -> Void)?
    var onDismiss: (() -> Void)?

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
        model.onDismiss = { [weak self] in self?.show(.hidden) }
        model.onCopied = { [weak self] in
            // Hold it a moment so the checkmark is seen, then clear.
            self?.dismissTimer?.invalidate()
            self?.model.resultProgress = 0
            self?.dismissTimer = Timer.scheduledTimer(
                withTimeInterval: 0.6, repeats: false) { _ in
                Task { @MainActor in self?.show(.hidden) }
            }
        }

        let host = NSHostingView(rootView: PanelView(model: model))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    // MARK: - Metrics

    /// Deliberately small. This floats over the user's work; it should read as a
    /// status indicator, not a window.
    private enum Metrics {
        /// Always on screen, so small enough to ignore.
        static let idle = CGSize(width: 48, height: 12)
        static let listening = CGSize(width: 112, height: 32)
        static let processing = CGSize(width: 112, height: 32)
        static let cancelled = CGSize(width: 232, height: 40)
        static let failed = CGSize(width: 220, height: 32)
        static let bottomInset: CGFloat = 12
        /// The result panel is taller, so it is lifted clear of the bottom edge
        /// (and any Dock) rather than running off screen.
        static let resultBottomInset: CGFloat = 96
    }

    /// Whether the result fits on one line beside its controls.
    ///
    /// **The view must branch on this too.** Sizing and layout disagreeing is a
    /// real bug: the capsule was measured for one row while the view drew two.
    static func isCompactResult(_ text: String) -> Bool {
        measuredWidth(text, size: 12) + 62 + 20 <= 420
    }

    /// Hugs the text. A short result should look like the pill it grew out of,
    /// not a dialog — width is only earned when there is text to justify it.
    static func resultSize(for text: String) -> CGSize {
        // Measured, not estimated. A character-count guess under-sized the row,
        // which squeezed the Copy button until its label wrapped to "C…".
        let width = measuredWidth(text, size: 12)

        // Single row: ✕ (18) + icon-only Copy (24) + spacing and padding.
        let controls: CGFloat = 62
        let padding: CGFloat = 20
        let maximumSingleRow: CGFloat = 420

        if isCompactResult(text) {
            return CGSize(
                width: max(132, width + controls + padding),
                height: 34)
        }
        _ = (controls, padding, maximumSingleRow)

        // Too long for one row: wrap beneath the controls.
        let wrapWidth: CGFloat = 380
        let usable = wrapWidth - 24
        let lines = min(4, max(1, Int((width / usable).rounded(.up))))
        return CGSize(width: wrapWidth, height: 42 + CGFloat(lines) * 15)
    }

    /// Rendered width of the string, so the capsule fits its contents exactly.
    private static func measuredWidth(_ text: String, size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return (text as NSString)
            .size(withAttributes: [.font: font])
            .width
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

        case .listening(let mode):
            model.state = .listening(mode: mode)
            model.level = 0
            startLevelPolling()

        case .processing:
            model.state = .processing

        case .result(let text):
            model.state = .result(text)
            model.resultProgress = 1
            // Long enough to read it and reach for Copy, short enough not to
            // linger. The bar makes the deadline visible so the text never
            // vanishes without warning.
            startResultCountdown(seconds: 10)

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
        position(for: state)
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
        case .hidden:           size = Metrics.idle
        case .listening:        size = Metrics.listening
        case .processing:       size = Metrics.processing
        case .cancelled:        size = Metrics.cancelled
        case .failed:           size = Metrics.failed
        case .result(let text): size = Self.resultSize(for: text)
        }
        panel.setContentSize(size)
    }

    private func position(for state: State) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let inset: CGFloat
        if case .result = state { inset = Metrics.resultBottomInset }
        else { inset = Metrics.bottomInset }
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + inset
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

    /// Drains the bar under an offered transcript, then dismisses it.
    private func startResultCountdown(seconds: Double) {
        let start = Date()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in
                let elapsed = Date().timeIntervalSince(start)
                self.model.resultProgress = max(0, 1 - elapsed / seconds)
                if elapsed >= seconds {
                    self.dismissTimer?.invalidate()
                    self.show(.hidden)
                }
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
    @Published var resultProgress: Double = 1

    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onUndo: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// Copying stops the countdown: the user has what they came for.
    var onCopied: (() -> Void)?
}

// MARK: - View

private struct PanelView: View {
    @ObservedObject var model: PanelModel
    @State private var copied = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: model.state)
    }

    @ViewBuilder
    private var background: some View {
        if model.state == .hidden {
            // Resting state: opaque, so the desktop never shows through, with a
            // bright outline so the pill stays findable over any wallpaper.
            Capsule(style: .continuous)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.55), lineWidth: 1.4)
                )
        } else {
            Capsule(style: .continuous)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()

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
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.65)
                Text("Transcribing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 12)

        case .cancelled:
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Transcript cancelled")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer(minLength: 4)
                    Button { model.onUndo?() } label: {
                        Text("Undo")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity)

                GeometryReader { geo in
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: geo.size.width * model.undoProgress, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 13)
                .padding(.bottom, 5)
            }

        case .result(let text):
            if DictationPanel.isCompactResult(text) {
                // Compact: reads as the pill it grew out of, not a dialog.
                HStack(spacing: 6) {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    DismissButton { model.onDismiss?() }
                    CopyButton(text: text, copied: $copied, compact: true) {
                        model.onCopied?()
                    }
                }
                .padding(.horizontal, 9)
                .overlay(alignment: .bottom) {
                    CountdownBar(progress: model.resultProgress)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 3)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Nowhere to type this")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        DismissButton { model.onDismiss?() }
                        CopyButton(text: text, copied: $copied, compact: false) {
                            model.onCopied?()
                        }
                    }
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    CountdownBar(progress: model.resultProgress)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

        case .failed(let message):
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
        }
    }
}

// MARK: - Controls

private struct CountdownBar: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(.white.opacity(0.5))
                .frame(width: geo.size.width * progress, height: 1.5)
        }
        .frame(height: 1.5)
    }
}

private struct DismissButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
    }
}

private struct CopyButton: View {
    let text: String
    @Binding var copied: Bool
    /// Icon only. In a one-line capsule the word "Copy" costs more width than
    /// it earns, and squeezing it is what produced the wrapped "C…" label.
    var compact: Bool
    /// Declared last so trailing-closure syntax binds to it, not to `compact`.
    var onCopy: (() -> Void)? = nil

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            onCopy?()
        } label: {
            Group {
                if compact {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 20)
                } else {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .semibold))
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                }
            }
            .foregroundStyle(.black)
            .background(Capsule().fill(.white))
        }
        .buttonStyle(.plain)
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
