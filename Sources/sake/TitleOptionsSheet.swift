import SakeKit
import SwiftUI

/// What a title is started with, after it has been added.
struct TitleOptionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 16) {
            Text("Options")
                .font(.title2.weight(.semibold))

            if let title = model.editingTitle {
                Text(title.executable)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Name", text: $model.typedTitleName)
            TextField("Arguments", text: $model.typedTitleArguments)
                .font(.callout.monospaced())

            VStack(alignment: .leading, spacing: 4) {
                Text("Environment")
                    .font(.callout)
                TextEditor(text: $model.typedTitleEnvironment)
                    .font(.callout.monospaced())
                    .frame(height: 56)
                    .border(.separator)
                Text("One KEY=VALUE per line, for this title only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let problem = model.addTitleProblem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("""
                    Saved into this bottle. The program itself is not changed here — a \
                    different executable is a different title.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: model.saveEditedTitle)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.typedTitleName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
