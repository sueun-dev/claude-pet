import SwiftUI

extension SessionRecord: Identifiable {}

/// What the menu bar label shows. Kept apart from the panel's model so the label only
/// redraws when its icon or count actually changes, not on every progress update.
final class StatusModel: ObservableObject {
    @Published private(set) var headline = SessionState.idle   // most urgent state
    @Published private(set) var count = 0
    @Published var attention = 0                                 // bumped when a session newly needs you

    func update(headline: SessionState, count: Int) {
        if headline != self.headline { self.headline = headline }
        if count != self.count { self.count = count }
    }
}

/// What the dropdown panel shows; only updated while the panel is open.
final class SessionsModel: ObservableObject {
    @Published var sessions: [SessionRecord] = []   // active sessions, most urgent first
    @Published var attention = 0
    var onOpen: (SessionRecord) -> Void = { _ in }
    var onAnswer: (PermissionPrompt, PermissionAnswer) -> Void = { _, _ in }
    var onClearFinished: () -> Void = {}

    var hasFinished: Bool { sessions.contains { $0.state == .ready || $0.state == .blocked } }
}

// MARK: - Menu bar label

/// What sits in the menu bar: a monochrome symbol like the system's own items, tinted
/// only when a session needs you, plus the number of active sessions.
struct StatusLabel: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.headline.menuBarSymbol)
                .foregroundStyle(model.headline.tint ?? Color.primary)
                .symbolEffect(.bounce, value: model.attention)
            if model.count > 0 {
                Text("\(model.count)").monospacedDigit()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 6)
        .fixedSize()
    }
}

// MARK: - Dropdown panel

private let panelWidth: CGFloat = 340
private let maxRows = 5

/// The Liquid Glass panel that drops down from the menu bar item.
struct SessionsPanel: View {
    @ObservedObject var model: SessionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Claude Code").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.hasFinished {
                    Button("Clear", action: model.onClearFinished)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)

            if model.sessions.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            ForEach(model.sessions.prefix(maxRows)) { record in
                SessionRow(record: record, attention: model.attention,
                           open: { model.onOpen(record) },
                           answer: model.onAnswer)
            }
            if model.sessions.count > maxRows {
                Text("\(model.sessions.count - maxRows) more")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
        }
        .padding(6)
        .frame(width: panelWidth)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.sessions)
        .fixedSize()
    }
}

private struct SessionRow: View {
    let record: SessionRecord
    let attention: Int
    let open: () -> Void
    let answer: (PermissionPrompt, PermissionAnswer) -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusIcon(state: record.state, attention: attention)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    StatusDetail(record: record)
                }
                if let message = record.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if let prompt = record.prompt {
                    PromptControls(prompt: prompt) { answer(prompt, $0) }
                        .padding(.top, 6)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.primary.opacity(hover ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
    }
}

/// The command being asked about, and the same three choices Claude's own dialog offers.
/// A request the panel can't show in full gets no buttons: it has to be answered in Claude.
private struct PromptControls: View {
    let prompt: PermissionPrompt
    let answer: (PermissionAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !prompt.detail.isEmpty {
                Text(prompt.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(prompt.answerable ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            if prompt.answerable { buttons } else {
                Text("Review this request in Claude")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button("Deny") { answer(.deny) }
                .buttonStyle(.glass)
            Spacer(minLength: 0)
            if prompt.canAlwaysAllow {
                Button("Always Allow") { answer(.allowAlways) }
                    .buttonStyle(.glass)
            }
            Button("Allow Once") { answer(.allowOnce) }
                .buttonStyle(.glassProminent)
        }
        .controlSize(.small)
    }
}

/// SF Symbol per state; running uses the system spinner.
private struct StatusIcon: View {
    let state: SessionState
    let attention: Int

    var body: some View {
        if state == .running {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: state.rowSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(state.tint ?? Color.secondary)
                .symbolEffect(.bounce, value: attention)
        }
    }
}

/// Elapsed time while running, otherwise the state name.
private struct StatusDetail: View {
    let record: SessionRecord

    var body: some View {
        Group {
            if record.state == .running, let start = record.runStart {
                TimelineView(.periodic(from: .now, by: 1)) { tl in
                    Text(elapsed(tl.date.timeIntervalSince1970 - start)).monospacedDigit()
                }
            } else {
                Text(record.state.label)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func elapsed(_ seconds: Double) -> String {
        let n = max(0, Int(seconds))
        return n < 3600 ? String(format: "%d:%02d", n / 60, n % 60)
                        : String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
    }
}

// MARK: - State styling

private extension SessionState {
    var tint: Color? {
        switch self {
        case .needsInput: return .orange
        case .ready: return .green
        case .blocked: return .red
        case .running, .idle: return nil
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .needsInput: return "exclamationmark.circle.fill"
        case .ready: return "checkmark.circle.fill"
        case .blocked: return "xmark.circle.fill"
        case .running, .idle: return "sparkle"
        }
    }

    var rowSymbol: String { self == .idle ? "circle" : menuBarSymbol }
}
