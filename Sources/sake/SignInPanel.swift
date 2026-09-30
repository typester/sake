import AppKit
import SakeKit
import SwiftUI

enum SignInPrompt: Equatable {
    case code(MicrosoftSignIn.DeviceCode, title: String)
    case failed(reason: String, title: String?)
}

/// The code a person types at microsoft.com/link while their game waits.
///
/// An AppKit panel rather than a SwiftUI scene: the request comes from a game, often while
/// no sake window is open, and SwiftUI opens a window only from a view that is on screen.
@MainActor
final class SignInPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var closedByPerson: (() -> Void)?

    func show(_ model: AppModel) {
        if panel == nil {
            let hosting = NSHostingController(rootView: SignInView().environment(model))
            hosting.sizingOptions = [.preferredContentSize]
            let panel = NSPanel(contentViewController: hosting)
            panel.styleMask = [.titled, .closable]
            panel.title = "Sign In to Xbox"
            panel.isFloatingPanel = true
            // The browser the code is typed into is the active app while it is typed.
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.center()
            self.panel = panel
        }
        closedByPerson = { [weak model] in model?.cancelSignIn() }
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        closedByPerson?()
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.signInPrompt {
            case .code(let code, let title):
                Text("\(title) is signing in to Xbox")
                    .font(.title3.weight(.semibold))
                Text("Enter this code at \(page(code)), in the browser sake opened:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline) {
                    Text(code.userCode)
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: 20)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.userCode, forType: .string)
                    }
                }
                Text("The code runs out at \(code.expiresAt.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelSignIn() }
                        .keyboardShortcut(.cancelAction)
                    Button("Open the Page Again") { NSWorkspace.shared.open(code.verificationURL) }
                        .keyboardShortcut(.defaultAction)
                }
            case .failed(let reason, let title):
                Text(title.map { "\($0) could not sign in to Xbox" } ?? "A game could not sign in to Xbox")
                    .font(.title3.weight(.semibold))
                Text(reason)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Close") { model.dismissSignIn() }
                        .keyboardShortcut(.defaultAction)
                }
            case nil:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func page(_ code: MicrosoftSignIn.DeviceCode) -> String {
        let url = code.verificationURL.absoluteString
        return url.hasPrefix("https://") ? String(url.dropFirst("https://".count)) : url
    }
}
