import SakeKit
import SwiftUI

/// One step at a time, with the whole list beside it.
///
/// The list is not decoration: a step here can take tens of minutes and can fail, and a
/// wizard that shows only the current card leaves you with no idea where you were when it
/// does.
struct SetupWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    /// `nil` until the user navigates, so the window opens on whatever is unfinished.
    @State private var showing: SetupStep?

    private var step: SetupStep {
        showing ?? model.setup.current(machineIsReady: model.machineIsReady)
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            pane
        }
        .frame(minWidth: 660, minHeight: 440)
        .task { await model.check() }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SetupStep.allCases) { candidate in
                Button {
                    showing = candidate
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: symbol(for: candidate))
                            .foregroundStyle(candidate == step ? Color.accentColor : tint(for: candidate))
                            .frame(width: 16)
                        Text(Self.copy(candidate).title)
                            .fontWeight(candidate == step ? .semibold : .regular)
                            .foregroundStyle(candidate == step ? Color.primary : Color.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 190, alignment: .leading)
    }

    private func symbol(for candidate: SetupStep) -> String {
        switch model.state(of: candidate) {
        case .done: "checkmark.circle.fill"
        case .blocked: "lock"
        case .ready, .outdated: candidate == step ? "arrowtriangle.right.fill" : "circle"
        }
    }

    private func tint(for candidate: SetupStep) -> Color {
        if case .done = model.state(of: candidate) { .green } else { .secondary }
    }

    private var pane: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.copy(step).title)
                    .font(.title2.weight(.semibold))
                Text(Self.copy(step).explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let why = model.state(of: step).reason {
                Text(why)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                rows.frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            bottomBar
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var rows: some View {
        switch step {
        case .machine: PreflightView(requirements: model.requirements)
        case .sources: SourcesView(statuses: model.sources)
        case .prefix: PrefixView(statuses: model.prefix)
        case .wine: WineView(status: model.wine)
        case .d3dMetal: D3DMetalView(status: model.d3dMetal)
        case .gdkRuntime: GDKRuntimeView(status: model.gdkRuntime)
        case .bottle: BottleView(name: Bottle.defaultName, status: model.bottleStatus[Bottle.defaultName])
        }
    }

    private var bottomBar: some View {
        HStack {
            Button("Back") { showing = neighbour(-1) }
                .disabled(neighbour(-1) == nil)

            Spacer()

            // The one step whose action is worth repeating after it has passed: the answer
            // changes when the user installs what was missing.
            if step == .machine {
                Button("Check Again") { model.start(.machine) }
                    .disabled(model.isChecking)
            }

            primary
        }
    }

    @ViewBuilder
    private var primary: some View {
        if model.isRunning(step) {
            Button("Stop") { model.stop(step) }
        } else if model.state(of: step).isDone {
            if let next = neighbour(1) {
                Button("Next") { showing = next }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { dismissWindow(id: WindowID.setup) }
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            Button(Self.copy(step).verb) { model.start(step) }
                .keyboardShortcut(.defaultAction)
                .disabled(isBlocked)
        }
    }

    private var isBlocked: Bool {
        if case .blocked = model.state(of: step) { true } else { false }
    }

    private func neighbour(_ offset: Int) -> SetupStep? {
        guard let index = SetupStep.allCases.firstIndex(of: step) else { return nil }
        let wanted = index + offset
        guard SetupStep.allCases.indices.contains(wanted) else { return nil }
        return SetupStep.allCases[wanted]
    }

    private struct Copy {
        let title: String
        let explanation: String
        /// What the button does when the step is not finished.
        let verb: String
    }

    private static func copy(_ step: SetupStep) -> Copy {
        switch step {
        case .machine:
            Copy(title: "This Mac",
                 explanation: "What decides whether sake can build anything here.",
                 verb: "Check Again")
        case .sources:
            Copy(title: "Sources",
                 explanation: """
                    Eleven downloads, each checked against a known hash and unpacked. \
                    Nothing is built yet.
                    """,
                 verb: "Download")
        case .prefix:
            Copy(title: "Libraries",
                 explanation: """
                    The tools and libraries Wine is built against. Minutes, not seconds.
                    """,
                 verb: "Build")
        case .wine:
            Copy(title: "Wine",
                 explanation: """
                    CrossOver's Wine, built against those libraries. This is the long one — \
                    tens of minutes.
                    """,
                 verb: "Build")
        case .d3dMetal:
            Copy(title: "D3DMetal",
                 explanation: """
                    Apple's DirectX 12 layer. sake may not ship it or download it for you — \
                    download the Game Porting Toolkit from Apple, open the .dmg, and sake \
                    copies it out.
                    """,
                 verb: "Install")
        case .gdkRuntime:
            Copy(title: "GDK Runtime",
                 explanation: """
                    What games built on Microsoft's GDK load in place of Xbox Gaming Services. \
                    Seconds.
                    """,
                 verb: "Build")
        case .bottle:
            Copy(title: "Bottle",
                 explanation: """
                    The Windows environment games live in. Making one is the first time \
                    anything sake built is actually run.
                    """,
                 verb: "Create")
        }
    }
}
