import SakeKit
import SwiftUI

enum TitleStatus: Equatable {
    case starting
    case running(line: String)
    case exited(status: Int32)
    case stopped(left: Int)
    case failed(String)
}

/// One title, on its own. The single Play button lives here rather than on every row,
/// which is what keeps a library of ten games from being ten buttons.
struct TitleDetail: View {
    let title: Title
    let status: TitleStatus?
    let isRunning: Bool
    /// Why Play is off, as a sentence. `nil` when it is on.
    let blockedBy: String?
    let play: () -> Void
    let stop: () -> Void
    let options: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.name)
                    .font(.largeTitle.weight(.semibold))
                Text(title.executable)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                if isRunning {
                    Button("Stop", action: stop)
                        .controlSize(.large)
                } else {
                    Button("Play", action: play)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(blockedBy != nil)
                }
                Button("Options…", action: options)
                    .controlSize(.large)
                statusLine
            }

            if !title.arguments.isEmpty {
                block("Started with", Title.argumentsText(title.arguments))
            }

            if !title.environment.isEmpty {
                block("In the environment", Title.environmentText(title.environment))
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func block(_ heading: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.callout.weight(.medium))
            Text(body)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .none:
            Text(blockedBy ?? "ready")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("starting").font(.callout).foregroundStyle(.secondary)
            }
        case .running(let line):
            VStack(alignment: .leading, spacing: 2) {
                Text("running").font(.callout).foregroundStyle(.secondary)
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .exited(let code):
            Text(code == 0 ? "exited" : "exited — status \(code)")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .stopped(let left):
            // Saying what is left rather than claiming success: `wineserver -k` exits 0
            // whether or not it killed anything.
            Text(left == 0 ? "stopped — nothing left running" : "stopped — \(left) still running")
                .font(.callout)
                .foregroundStyle(left == 0 ? Color.secondary : Color.orange)
        case .failed(let reason):
            Text(reason)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
