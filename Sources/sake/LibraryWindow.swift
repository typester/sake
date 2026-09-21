import SakeKit
import SwiftUI

/// What the sidebar can be on: a bottle itself, or one of the titles in it.
///
/// A bottle has to be selectable in its own right or a new one — which has nothing in it —
/// would be a heading with no way to reach what it can do.
enum LibrarySelection: Hashable {
    case bottle(String)
    case title(bottle: String, id: String)
}

/// The window for using sake rather than setting it up: the bottles and what is in them on
/// the left, and one of those at a time on the right.
struct LibraryWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.bottles, id: \.name) { bottle in
                    Section {
                        rows(for: bottle)
                    } header: {
                        heading(for: bottle)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                // Only what is about the library rather than about one bottle: putting a
                // game in, or taking a bottle away, belongs to the bottle it happens to.
                Button {
                    model.isCreatingBottle = true
                } label: {
                    Label("New Bottle…", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem {
                Button(isReady ? "Set Up…" : "Finish Setting Up…") {
                    openWindow(id: WindowID.setup)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 380)
        .sheet(isPresented: $model.isImporting) { ImportSheet().environment(model) }
        .sheet(isPresented: $model.isInstalling) { InstallSheet().environment(model) }
        .sheet(isPresented: $model.isAddingTitle) { AddTitleSheet().environment(model) }
        .sheet(isPresented: $model.isEditingTitle) { TitleOptionsSheet().environment(model) }
        .sheet(isPresented: $model.isCreatingBottle) { NewBottleSheet().environment(model) }
        .sheet(isPresented: $model.isUninstalling) { UninstallSheet().environment(model) }
        .sheet(isPresented: $model.isRenamingBottle) {
            if let selected { RenameBottleSheet(bottle: selected).environment(model) }
        }
        .alert(
            "Move “\(selected?.name ?? "")” to the Trash?",
            isPresented: $model.isDeletingBottle,
            presenting: selected
        ) { bottle in
            Button("Move to Trash", role: .destructive) { model.deleteBottle(bottle) }
            Button("Cancel", role: .cancel) {}
        } message: { bottle in
            Text(whatDeletingCosts(bottle))
        }
        .alert(
            "“\(selected?.name ?? "")” could not be moved to the Trash",
            isPresented: trashRefused,
            presenting: model.trashProblem
        ) { _ in
            if let selected {
                Button("Delete Permanently", role: .destructive) {
                    model.deleteBottle(selected, permanently: true)
                }
            }
            Button("Cancel", role: .cancel) { model.trashProblem = nil }
        } message: { reason in
            Text("\(reason)\n\nDeleting it outright frees the space and cannot be undone.")
        }
        // A survey measures what it can, but clicking from one bottle to the next is not
        // one of the things that causes a survey.
        .onChange(of: model.selectedBottle) { model.measureSelectedBottle() }
        // A bottle made in CrossOver while sake was in the background: the selection is no
        // use as a trigger, because one bottle means selectedBottle never changes.
        .onChange(of: appearsActive) { _, active in
            if active { model.surveyImportSources() }
        }
        .task {
            await model.check()
            // First run lands here with nothing built, so the wizard opens itself rather
            // than leaving an empty window and a button to find.
            if !isReady { openWindow(id: WindowID.setup) }
        }
    }

    /// A `List`'s selection only reaches its rows, so a selected heading is drawn rather
    /// than highlighted.
    private func heading(for bottle: Bottle) -> some View {
        let isSelected = model.selection == .bottle(bottle.name)
        return Button {
            model.selection = .bottle(bottle.name)
        } label: {
            Text(bottle.name)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rows(for bottle: Bottle) -> some View {
        let titles = model.titles[bottle.name] ?? []
        if titles.isEmpty {
            // Without this the section is a heading with nothing under it, which reads as
            // a rendering fault rather than as an empty bottle.
            Text("nothing here yet")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .selectionDisabled()
        } else {
            ForEach(titles) { title in
                Text(title.name)
                    .tag(LibrarySelection.title(bottle: bottle.name, id: title.id))
                    .contextMenu {
                        // Only what was added by hand, and it takes the entry away rather
                        // than the game: deleting an install is the bottle's business.
                        if model.isRemovable(title, in: bottle.name) {
                            Button("Remove from Library") {
                                model.removeTitle(title, from: bottle.name)
                            }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .title(let bottle, _):
            if let title = model.selectedTitle {
                let run = RunningTitle(bottle: bottle, title: title)
                TitleDetail(
                    title: title,
                    status: model.titleStatus[run],
                    isRunning: model.runningTitle == run,
                    blockedBy: model.blocker(for: title, in: bottle),
                    play: { model.startTitle(title, in: bottle) },
                    stop: model.stopTitle,
                    options: { model.beginEditTitle(title, in: bottle) }
                )
            }
        case .bottle(let name):
            if let bottle = model.bottle(named: name) {
                BottleDetail(
                    bottle: bottle,
                    titles: model.titles[name] ?? [],
                    size: model.bottleSizes[name],
                    problem: model.problem(with: name),
                    canImport: !model.importSources.isEmpty,
                    canRunTools: WineTool.missingPrerequisite(in: bottle) == nil,
                    importCandidates: name == model.importTarget ? model.importCandidates.count : nil,
                    importing: { model.beginImport(into: name) },
                    installing: { model.beginInstall(into: name) },
                    addingTitle: { model.beginAddTitle(into: name) },
                    renaming: { model.beginRename(bottle) },
                    deleting: { model.isDeletingBottle = true },
                    runTool: { model.runTool($0, in: name) }
                )
            }
        case .none:
            empty
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Text(model.bottles.isEmpty ? "No bottles yet" : "Nothing selected")
                .font(.title3)
                .foregroundStyle(.secondary)

            if !isReady {
                Text("sake is not set up yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isReady: Bool {
        model.setup.isComplete(machineIsReady: model.machineIsReady)
    }

    private var selected: Bottle? { model.bottle(named: model.selectedBottle) }

    private var trashRefused: Binding<Bool> {
        Binding(get: { model.trashProblem != nil }, set: { if !$0 { model.trashProblem = nil } })
    }

    /// What a delete actually costs. The Trash keeps the bottle, so it can be undone — but
    /// the space is not what the bottle's size says, because an imported game's blocks
    /// belong to CrossOver's copy as well. See docs/layout.md.
    private func whatDeletingCosts(_ bottle: Bottle) -> String {
        let games = model.titles[bottle.name] ?? []
        let holds = switch games.count {
        case 0: "There is nothing in it but the Windows it was set up with."
        case 1: "\(games[0].name) goes with it."
        default: "\(games.map(\.name).formatted()) go with it."
        }
        let stopping = model.running(in: bottle.name)
            .map { " \($0.name) is running now and will be stopped." } ?? ""
        let size = model.bottleSizes[bottle.name]?.formatted(.byteCount(style: .file))
        return """
            \(holds)\(stopping) You can put it back from the Trash — and emptying the Trash \
            returns less than \(size ?? "its size"), because a game that came from CrossOver \
            shares its blocks with CrossOver's own copy.
            """
    }
}
