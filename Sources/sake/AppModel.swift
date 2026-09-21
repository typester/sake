import Observation
import SakeKit
import SwiftUI

/// A long operation that can be stopped and started again.
///
/// The generation is load-bearing: a stopped run finishes winding down after the next one
/// has started, and must not clear that one's handle.
@MainActor
@Observable
final class Run {
    private(set) var task: Task<Void, Never>?
    private var generation = 0

    var isRunning: Bool { task != nil }

    func start(_ body: @escaping @MainActor () async -> Void, then done: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        generation += 1
        let mine = generation
        task = Task {
            await body()
            if mine == generation {
                task = nil
                done()
            }
        }
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
    }
}

/// A title and the bottle it was started in, because stopping goes after a `WINEPREFIX`
/// and the wrong one would take somebody else's game down.
struct RunningTitle: Hashable {
    let bottle: String
    let title: Title
}

/// Everything both windows show. The wizard and the library are two views of one machine's
/// state, so the state cannot belong to either of them.
@MainActor
@Observable
final class AppModel {
    let paths = Paths.default

    var requirements: [Requirement] = []
    var isChecking = false

    var sources: [String: SourceStatus] = [:]
    var prefix: [String: PrefixStatus] = [:]
    var wine: WineStatus?
    var d3dMetal: D3DMetalStatus?

    /// Keyed by bottle name, the way `sources` and `prefix` are keyed by component: the
    /// wizard watches `default` while the library may be making another one.
    var bottleStatus: [String: BottleStatus] = [:]
    var isCreatingBottle = false
    var typedBottleName = ""
    var isRenamingBottle = false
    var typedRenameName = ""
    var isDeletingBottle = false
    /// Why the Trash would not take a bottle. Non-nil is the only way sake offers to remove
    /// anything outright, and the user is told what the offer is before it appears.
    var trashProblem: String?
    /// What a bottle occupies, as it looks from outside. Keyed by name and filled only for
    /// what is on screen: see ``measureSelectedBottle()``.
    var bottleSizes: [String: Int64] = [:]

    var importSources: [CrossOverBottle] = []
    var importSource: CrossOverBottle?
    var importCandidates: [String] = []
    var importChoices: Set<String> = []
    var importSizes: [String: Int64] = [:]
    var importStatus: ImportStatus?
    var importBlockedBy: String?
    var isImporting = false
    /// Which bottle an import lands in. The sheet offers it as a menu once there is more
    /// than one; until then it follows whatever the library has selected.
    var importTarget = Bottle.defaultName

    /// An installer the user downloaded, and which bottle it goes into. sake never
    /// fetches one -- see docs/licensing.md.
    var installer: URL?
    var installTarget = Bottle.defaultName
    var installStatus: InstallStatus?
    var isInstalling = false

    var isAddingTitle = false
    /// The title whose options are open, and the bottle it is in. Editing writes into that
    /// bottle's own file, which is also how a built-in title is overridden.
    var editingTitle: Title?
    var editingTitleBottle = Bottle.defaultName
    var isEditingTitle = false
    var addTitleTarget = Bottle.defaultName
    var addedTitleExecutable: URL?
    var typedTitleName = ""
    var typedTitleArguments = ""
    /// Why the program that was picked cannot be a title, as a sentence from SakeKit.
    var addTitleProblem: String?

    var isUninstalling = false
    var uninstallItems: [Uninstaller.Item] = []
    var uninstallSizes: [String: Int64] = [:]
    /// Where each root landed in the Trash, which is what somebody who changes their mind
    /// needs to know.
    var uninstallLanded: [URL] = []
    var uninstallStatus: UninstallStatus?

    var bottles: [Bottle] = []
    var titles: [String: [Title]] = [:]
    var selection: LibrarySelection?
    var runningTitle: RunningTitle?
    /// Keyed by the run it came out of and not by the title alone: the same game can be
    /// installed in two bottles, so an id on its own names two different things.
    var titleStatus: [RunningTitle: TitleStatus] = [:]

    let fetching = Run()
    let building = Run()
    let buildingWine = Run()
    let installing = Run()
    let creating = Run()
    let changingBottle = Run()
    let importing = Run()
    let installingGame = Run()
    let playing = Run()
    let uninstalling = Run()

    var machineIsReady: Bool {
        !requirements.isEmpty && requirements.allSatisfy(\.status.isSatisfied)
    }

    var setup: Setup { Setup(paths: paths) }

    var selectedBottle: String? {
        switch selection {
        case .bottle(let name): name
        case .title(let bottle, _): bottle
        case nil: nil
        }
    }

    func bottle(named name: String?) -> Bottle? {
        name.flatMap { wanted in bottles.first { $0.name == wanted } }
    }

    /// What went wrong the last time something was done to this bottle, as a sentence.
    func problem(with bottle: String) -> String? {
        if case .failed(let reason) = bottleStatus[bottle] { reason } else { nil }
    }

    var selectedTitle: Title? {
        guard case .title(let bottle, let id) = selection else { return nil }
        return titles[bottle]?.first { $0.id == id }
    }

    /// What sake started in this bottle and has not seen end.
    ///
    /// Only what sake started this session: nothing in `ps` says which prefix a Wine
    /// process belongs to, so a game left from an earlier run is not here. ``Bottle`` taking
    /// the prefix down itself is what keeps that case safe rather than merely quiet.
    func running(in bottle: String) -> Title? {
        runningTitle.flatMap { $0.bottle == bottle ? $0.title : nil }
    }

    /// Why this bottle cannot be renamed to `typed`, as a sentence, or `nil` when it can.
    ///
    /// Renaming stops the prefix, and nobody asked for that by changing a label — so it is
    /// refused rather than warned about. Deleting stops it too and is not refused, because
    /// stopping is part of what throwing a bottle away means.
    func renameProblem(_ bottle: Bottle, to typed: String) -> String? {
        if let running = running(in: bottle.name) {
            return "\(running.name) is running in it. Stop it first."
        }
        return Bottle.problem(withName: typed, in: paths, renaming: bottle.name)
    }

    /// Why Play is off for this title, as a sentence, or `nil` when it is on.
    func blocker(for title: Title, in bottle: String) -> String? {
        TitleLauncher(paths: paths, name: bottle, title: title).missingPrerequisite
    }

    func state(of step: SetupStep) -> StepState {
        setup.state(of: step, machineIsReady: machineIsReady)
    }

    func isRunning(_ step: SetupStep) -> Bool {
        switch step {
        case .machine: isChecking
        case .sources: fetching.isRunning
        case .prefix: building.isRunning
        case .wine: buildingWine.isRunning
        case .d3dMetal: installing.isRunning
        case .bottle: creating.isRunning
        }
    }

    func start(_ step: SetupStep) {
        switch step {
        case .machine:
            Task { await check() }
        case .sources:
            fetching.start({ for await e in SourceFetcher(paths: self.paths).fetch() { self.apply(e) } },
                           then: survey)
        case .prefix:
            building.start({ for await e in PrefixBuilder(paths: self.paths).build() { self.apply(e) } },
                           then: survey)
        case .wine:
            buildingWine.start({ for await e in WineBuilder(paths: self.paths).build() { self.apply(e) } },
                               then: survey)
        case .d3dMetal:
            installing.start({ for await e in D3DMetalInstaller(paths: self.paths).install() { self.apply(e) } },
                             then: survey)
        case .bottle:
            create(Bottle.defaultName)
        }
    }

    func stop(_ step: SetupStep) {
        switch step {
        case .machine: break
        case .sources: fetching.stop()
        case .prefix: building.stop()
        case .wine: buildingWine.stop()
        case .d3dMetal: installing.stop()
        case .bottle: creating.stop()
        }
    }

    func check() async {
        isChecking = true
        defer { isChecking = false }
        requirements = await Preflight.run()
        survey()
    }

    /// What is already on disk. Without this the rows all read "waiting" until a run is
    /// started, however much of the work is already done.
    func survey() {
        for component in Component.all where component.isUnpacked(in: paths) {
            sources[component.id] = .inPlace
        }
        for recipe in BuildRecipe.all where recipe.isBuilt(in: paths.engine) {
            prefix[recipe.id] = .alreadyBuilt
        }
        if WineBuilder(paths: paths).isBuilt { wine = .alreadyBuilt }

        let installer = D3DMetalInstaller(paths: paths)
        if installer.isInstalled {
            d3dMetal = .alreadyInstalled(version: installer.installedVersion())
        }

        bottles = Bottle.all(in: paths)
        for bottle in bottles where bottleStatus[bottle.name] == nil {
            let counts = bottle.systemFileCounts()
            bottleStatus[bottle.name] = .alreadyCreated(
                system32: counts.system32, sysWoW64: counts.sysWoW64
            )
        }
        titles = Dictionary(uniqueKeysWithValues: bottles.map { ($0.name, Title.installed(in: $0)) })

        // A selection that no longer names anything -- the first survey, or a bottle just
        // made -- lands on something rather than leaving the detail pane empty.
        if selection == nil || !isStillThere(selection) {
            selection = bottles.first.map { bottle in
                titles[bottle.name]?.first.map { .title(bottle: bottle.name, id: $0.id) }
                    ?? .bottle(bottle.name)
            }
        }
        if !bottles.contains(where: { $0.name == importTarget }) {
            importTarget = selectedBottle ?? bottles.first?.name ?? Bottle.defaultName
        }

        bottleSizes = bottleSizes.filter { name, _ in bottles.contains { $0.name == name } }
        titleStatus = titleStatus.filter { key, _ in titles[key.bottle]?.contains(key.title) == true }
        measureSelectedBottle()

        surveyImportSources()
    }

    /// Called from ``survey()`` and again when the selection moves: without the second
    /// caller a bottle made in CrossOver after sake started stays invisible until a
    /// relaunch.
    func surveyImportSources() {
        importSources = CrossOverBottle.available()
        if importSource == nil || !importSources.contains(where: { $0 == importSource }) {
            importSource = importSources.first
        }
        if let source = importSource {
            let importer = BottleImporter(paths: paths, name: importTarget, source: source)
            importCandidates = importer.candidates()
            importBlockedBy = importer.missingPrerequisite
        } else {
            importCandidates = []
            importBlockedBy = "No CrossOver bottle to import from."
        }
    }

    private func isStillThere(_ selection: LibrarySelection?) -> Bool {
        switch selection {
        case .bottle(let name): bottles.contains { $0.name == name }
        case .title(let bottle, let id): titles[bottle]?.contains { $0.id == id } == true
        case nil: false
        }
    }

    /// Making a bottle, whether the wizard asked for the first one or the library asked for
    /// another. One ``Run`` for both: two winebooots at once is not a thing to allow.
    func create(_ name: String) {
        creating.start({
            for await e in BottleBuilder(paths: self.paths, name: name).create() {
                self.apply(e, for: name)
            }
        }) {
            self.survey()
            // Land on what was just made, which is also what the import sheet will offer.
            if self.bottles.contains(where: { $0.name == name }) {
                self.selection = .bottle(name)
                self.importTarget = name
            }
        }
    }

    /// Walked rather than remembered, and only for the one on screen: a bottle with a game
    /// in it is a hundred gigabytes and tens of thousands of files to add up.
    func measureSelectedBottle() {
        guard let name = selectedBottle, bottleSizes[name] == nil, let bottle = bottle(named: name)
        else { return }
        Task {
            let size = await Task.detached { DiskUsage.size(of: bottle.url) }.value
            bottleSizes[name] = size
        }
    }

    func beginRename(_ bottle: Bottle) {
        typedRenameName = bottle.name
        isRenamingBottle = true
    }

    /// The rename itself is a directory rename. What follows it is everything sake keys by
    /// the name and the disk does not: the selection, the import target, the progress row
    /// the wizard drew and the size already measured.
    func renameBottle(_ bottle: Bottle, to typed: String) {
        changingBottle.start({
            do {
                let renamed = try await bottle.rename(to: typed)
                self.bottleStatus[renamed.name] = self.bottleStatus.removeValue(forKey: bottle.name)
                self.bottleSizes[renamed.name] = self.bottleSizes.removeValue(forKey: bottle.name)
                self.titleStatus = self.titleStatus.reduce(into: [:]) { moved, entry in
                    let key = entry.key.bottle == bottle.name
                        ? RunningTitle(bottle: renamed.name, title: entry.key.title)
                        : entry.key
                    moved[key] = entry.value
                }
                self.selection = .bottle(renamed.name)
                self.importTarget = renamed.name
            } catch {
                self.bottleStatus[bottle.name] = .failed(error.localizedDescription)
            }
        }, then: survey)
    }

    func deleteBottle(_ bottle: Bottle, permanently: Bool = false) {
        changingBottle.start({
            do {
                _ = try await bottle.remove(trash: permanently ? .permanent : .system)
                self.bottleStatus[bottle.name] = nil
                self.trashProblem = nil
            } catch {
                self.trashProblem = error.localizedDescription
            }
        }, then: survey)
    }

    func beginImport(into bottle: String) {
        importTarget = bottle
        importStatus = nil
        isImporting = true
    }

    /// What the import sheet offers. The names are a pair of directory listings and come
    /// back at once; the sizes walk the source bottle, so they arrive afterwards.
    func loadImportOffer() {
        guard let source = importSource else { return }
        let importer = BottleImporter(paths: paths, name: importTarget, source: source)
        importCandidates = importer.candidates()
        importBlockedBy = importer.missingPrerequisite
        importChoices = Set(importCandidates)
        importSizes = [:]
        Task { importSizes = await importer.sizes(of: importCandidates) }
    }

    private func apply(_ event: FetchEvent) {
        switch event {
        case .alreadyInPlace(let component):
            sources[component.id] = .inPlace
        case .started(let component):
            sources[component.id] = .downloading(fraction: nil)
        case .progress(let component, let bytes, let total):
            sources[component.id] = .downloading(fraction: total.map { Double(bytes) / Double($0) })
        case .downloaded(let component, let verified):
            sources[component.id] = .unpacking(verified: verified)
        case .unpacked(let component):
            if case .unpacking(let verified) = sources[component.id] {
                sources[component.id] = .ready(verified: verified)
            } else {
                sources[component.id] = .ready(verified: component.sha256 != nil)
            }
        case .failed(let component, let reason):
            sources[component.id] = .failed(reason)
        case .finished:
            break
        }
    }

    private func apply(_ event: BuildEvent) {
        switch event {
        case .alreadyBuilt(let recipe):
            prefix[recipe.id] = .alreadyBuilt
        case .started(let recipe):
            prefix[recipe.id] = .working(phase: "starting", line: "")
        case .phase(let recipe, let phase):
            prefix[recipe.id] = .working(phase: phase.rawValue, line: "")
        case .output(let recipe, let line):
            if case .working(let phase, _) = prefix[recipe.id] {
                prefix[recipe.id] = .working(phase: phase, line: line)
            }
        case .installed(let recipe):
            prefix[recipe.id] = .built
        case .failed(let recipe, let reason, _):
            prefix[recipe.id] = .failed(reason)
        case .finished:
            break
        }
    }

    private func apply(_ event: WineEvent) {
        switch event {
        case .alreadyBuilt: wine = .alreadyBuilt
        case .started: wine = .working(phase: "starting", line: "")
        case .phase(let phase): wine = .working(phase: phase.rawValue, line: "")
        case .output(let line):
            if case .working(let phase, _) = wine { wine = .working(phase: phase, line: line) }
        case .installed(let version): wine = .built(version: version)
        case .failed(let reason, _): wine = .failed(reason)
        case .finished: break
        }
    }

    private func apply(_ event: D3DMetalEvent) {
        switch event {
        case .alreadyInstalled(let version): d3dMetal = .alreadyInstalled(version: version)
        case .started: d3dMetal = .working(phase: "starting", item: "")
        case .phase(let phase): d3dMetal = .working(phase: phase.rawValue, item: "")
        case .placed(let item):
            if case .working(let phase, _) = d3dMetal { d3dMetal = .working(phase: phase, item: item) }
        case .installed(let version): d3dMetal = .installed(version: version)
        case .failed(let reason): d3dMetal = .failed(reason)
        case .finished: break
        }
    }

    private func apply(_ event: BottleEvent, for name: String) {
        switch event {
        case .alreadyCreated(let system32, let sysWoW64):
            bottleStatus[name] = .alreadyCreated(system32: system32, sysWoW64: sysWoW64)
        case .started: bottleStatus[name] = .working(phase: "starting", line: "")
        case .phase(let phase): bottleStatus[name] = .working(phase: phase.rawValue, line: "")
        case .output(let line):
            if case .working(let phase, _) = bottleStatus[name] {
                bottleStatus[name] = .working(phase: phase, line: line)
            }
        case .created(let system32, let sysWoW64):
            bottleStatus[name] = .created(system32: system32, sysWoW64: sysWoW64)
        case .failed(let reason, _): bottleStatus[name] = .failed(reason)
        case .finished: break
        }
    }

    func startImport() {
        guard let source = importSource else { return }
        let chosen = Array(importChoices)
        importing.start({
            let importer = BottleImporter(paths: self.paths, name: self.importTarget, source: source)
            for await e in importer.run(chosen) {
                self.apply(e)
            }
        }) {
            self.bottleSizes[self.importTarget] = nil
            self.survey()
            self.loadImportOffer()
        }
    }

    func stopImport() { importing.stop() }

    private func apply(_ event: ImportEvent) {
        switch event {
        case .nothingToImport: importStatus = .nothingToImport
        case .started: importStatus = .working(entry: "")
        case .cloning(let entry): importStatus = .working(entry: entry)
        case .cloned: break
        case .failed(let reason, _): importStatus = .failed(reason)
        case .finished(let cloned, let bytes):
            // A run that failed has already said so, and its count would read as success.
            if case .failed = importStatus {} else if cloned > 0 {
                importStatus = .imported(count: cloned, bytes: bytes)
            }
        }
    }

    func beginInstall(into bottle: String) {
        installTarget = bottle
        installer = nil
        installStatus = nil
        isInstalling = true
    }

    func startInstall() {
        guard let installer else { return }
        let bottle = installTarget
        installingGame.start({
            let runner = InstallerRunner(paths: self.paths, name: bottle, installer: installer)
            for await e in runner.run() { self.apply(e) }
        }) {
            // An installer that finished put something in the bottle, so what the library
            // can start and what the bottle weighs are both out of date.
            self.bottleSizes[bottle] = nil
            self.survey()
        }
    }

    /// Cancelling reaches `wine` and nothing else, so the bottle is taken down explicitly.
    /// See docs/runtime.md.
    func stopInstall() {
        guard let installer else { return }
        let bottle = installTarget
        installingGame.stop()
        Task {
            let left = await InstallerRunner(
                paths: paths, name: bottle, installer: installer
            ).stop()
            installStatus = .stopped(left: left.count)
            survey()
        }
    }

    private func apply(_ event: InstallEvent) {
        switch event {
        case .started: installStatus = .working(line: "")
        case .output(let line): installStatus = .working(line: line)
        case .exited(let status): installStatus = .exited(status: status)
        case .failed(let reason, _): installStatus = .failed(reason)
        case .finished: break
        }
    }

    /// The installer has closed; what it installed is what somebody wants to start next.
    func addTitleAfterInstall() {
        isInstalling = false
        beginAddTitle(into: installTarget)
    }

    func beginAddTitle(into bottle: String) {
        addTitleTarget = bottle
        addedTitleExecutable = nil
        typedTitleName = ""
        typedTitleArguments = ""
        addTitleProblem = nil
        isAddingTitle = true
    }

    /// The name follows the program until somebody types over it, which is what makes the
    /// common case one click and a Return. A Chromium app's flags come with it.
    func chooseTitleExecutable(_ url: URL) {
        addedTitleExecutable = url
        addTitleProblem = nil
        if typedTitleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            typedTitleName = url.deletingPathExtension().lastPathComponent
        }
        if typedTitleArguments.isEmpty {
            typedTitleArguments = Title.suggestedArguments(for: url).joined(separator: " ")
        }
    }

    func beginEditTitle(_ title: Title, in bottle: String) {
        editingTitle = title
        editingTitleBottle = bottle
        typedTitleName = title.name
        typedTitleArguments = title.arguments.joined(separator: " ")
        addTitleProblem = nil
        isEditingTitle = true
    }

    /// Saved into the bottle, whether it started as a built-in or not.
    func saveEditedTitle() {
        guard let title = editingTitle else { return }
        let store = TitleStore(bottle: Bottle(paths: paths, name: editingTitleBottle))
        let name = typedTitleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            addTitleProblem = TitleStoreError.unnamed.localizedDescription
            return
        }
        let edited = Title(
            id: title.id,
            name: name,
            executable: title.executable,
            arguments: typedTitleArguments.split(separator: " ").map(String.init)
        )
        do {
            try store.add(edited)
            isEditingTitle = false
            survey()
        } catch {
            addTitleProblem = error.localizedDescription
        }
    }

    func addTitle() {
        guard let executable = addedTitleExecutable else { return }
        let store = TitleStore(bottle: Bottle(paths: paths, name: addTitleTarget))
        do {
            let arguments = typedTitleArguments
                .split(separator: " ")
                .map(String.init)
            try store.add(store.title(at: executable, named: typedTitleName, arguments: arguments))
            addTitleProblem = nil
            isAddingTitle = false
            survey()
        } catch {
            addTitleProblem = error.localizedDescription
        }
    }

    /// Only what was added by hand can be taken out of the library, and taking it out
    /// leaves the game where it is: this is a list sake keeps, not the install.
    func isRemovable(_ title: Title, in bottle: String) -> Bool {
        TitleStore(bottle: Bottle(paths: paths, name: bottle)).contains(id: title.id)
    }

    func removeTitle(_ title: Title, from bottle: String) {
        try? TitleStore(bottle: Bottle(paths: paths, name: bottle)).remove(id: title.id)
        if selection == .title(bottle: bottle, id: title.id) { selection = .bottle(bottle) }
        survey()
    }

    /// What uninstalling would take away, and what each piece occupies. The list is a
    /// directory listing; the sizes walk the trees, so they arrive afterwards -- the same
    /// split the import sheet makes.
    func loadUninstallOffer() {
        uninstallItems = Uninstaller(paths: paths).items()
        uninstallSizes = [:]
        let items = uninstallItems
        Task {
            for item in items {
                uninstallSizes[item.id] = await Task.detached { DiskUsage.size(of: item.url) }.value
            }
        }
    }

    func uninstall() {
        uninstallLanded = []
        uninstallStatus = .working("starting")
        uninstalling.start({
            for await e in Uninstaller(paths: self.paths).run() { self.apply(e) }
        }) {
            self.forgetWhatWasOnDisk()
            self.survey()
            self.loadUninstallOffer()
        }
    }

    /// Everything the model remembers about the disk. ``survey()`` only ever fills these in
    /// -- it has never had to notice something going away -- so an uninstall has to empty
    /// them itself or the wizard goes on reporting steps that are done.
    private func forgetWhatWasOnDisk() {
        sources = [:]
        prefix = [:]
        wine = nil
        d3dMetal = nil
        bottleStatus = [:]
        bottleSizes = [:]
        titleStatus = [:]
        runningTitle = nil
        selection = nil
    }

    private func apply(_ event: UninstallEvent) {
        switch event {
        case .started: uninstallStatus = .working("starting")
        case .stopping(let bottle): uninstallStatus = .working("stopping \(bottle)")
        case .removing(let path): uninstallStatus = .working("moving \(path)")
        case .removed(_, let landed): if let landed { uninstallLanded.append(landed) }
        case .failed(let reason): uninstallStatus = .failed(reason)
        case .finished(let removed):
            // A run that failed has already said so, and a count would read as success.
            if case .failed = uninstallStatus {} else { uninstallStatus = .done(count: removed) }
        }
    }

    func startTitle(_ title: Title, in bottle: String) {
        let running = RunningTitle(bottle: bottle, title: title)
        runningTitle = running
        titleStatus[running] = .starting
        playing.start({
            let launcher = TitleLauncher(paths: self.paths, name: bottle, title: title)
            for await e in launcher.launch() { self.apply(e, for: running) }
        }) {
            self.runningTitle = nil
            self.survey()
        }
    }

    /// Cancelling reaches `wine` and nothing else, so the bottle is taken down explicitly
    /// and then looked at again rather than assumed down. See docs/runtime.md.
    func stopTitle() {
        guard let running = runningTitle else { return }
        playing.stop()
        Task {
            let launcher = TitleLauncher(
                paths: paths, name: running.bottle, title: running.title
            )
            let left = await launcher.stop()
            titleStatus[running] = .stopped(left: left.count)
            runningTitle = nil
            survey()
        }
    }

    private func apply(_ event: LaunchEvent, for running: RunningTitle) {
        switch event {
        case .started: titleStatus[running] = .starting
        case .output(let line): titleStatus[running] = .running(line: line)
        case .exited(let status): titleStatus[running] = .exited(status: status)
        case .failed(let reason, _): titleStatus[running] = .failed(reason)
        case .finished: break
        }
    }
}
