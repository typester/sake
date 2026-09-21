import SakeKit
import SwiftUI
import UniformTypeIdentifiers

/// Adding something already in a bottle to the library, so it can be started.
struct AddTitleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var isChoosing = false

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 16) {
            Text("Add a Title")
                .font(.title2.weight(.semibold))

            Text("In \(model.addTitleTarget)")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Choose Program…") { isChoosing = true }
                if let executable = model.addedTitleExecutable {
                    Text(executable.lastPathComponent)
                        .font(.callout.monospaced())
                        .truncationMode(.middle)
                        .lineLimit(1)
                } else {
                    Text("No program chosen")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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
                    The program has to be inside this bottle. What is kept is where it sits \
                    relative to drive_c, so renaming the bottle or moving it leaves the \
                    title pointing at the same game.
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
                Button("Add", action: model.addTitle)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.addedTitleExecutable == nil || model.typedTitleName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .fileImporter(
            isPresented: $isChoosing,
            allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data]
        ) { result in
            if case .success(let url) = result { model.chooseTitleExecutable(url) }
        }
        // Opening in the bottle saves hunting for it; SakeKit refuses anything outside it
        // anyway, so this is a shortcut rather than the guard.
        .fileDialogDefaultDirectory(Bottle(paths: model.paths, name: model.addTitleTarget).driveC)
    }
}
