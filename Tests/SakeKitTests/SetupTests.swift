import Foundation
import Testing

@testable import SakeKit

private func temporaryRoot() -> Paths {
    let root = FileManager.default.temporaryDirectory.appending(path: "sake-setup-\(UUID().uuidString)")
    return Paths(root: root.appending(path: "support"), cache: root.appending(path: "cache"))
}

private func remove(_ paths: Paths) {
    try? FileManager.default.removeItem(at: paths.root.deletingLastPathComponent())
}

private func touch(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: url.path, contents: nil)
}

/// Put on disk exactly what one step produces, so the next step becomes the current one.
private func finish(_ step: SetupStep, in paths: Paths) throws {
    switch step {
    case .machine:
        break
    case .sources:
        for component in Component.all {
            try FileManager.default.createDirectory(
                at: component.unpackedURL(in: paths), withIntermediateDirectories: true
            )
        }
    case .prefix:
        for recipe in BuildRecipe.all { try touch(recipe.productURL(in: paths.engine)) }
    case .wine:
        try touch(paths.engine.appending(path: "bin/wine"))
    case .d3dMetal:
        try touch(paths.d3dMetalFramework.appending(path: "D3DMetal"))
        try touch(paths.wineUnixLibraries.appending(path: "D3DMetal.framework/D3DMetal"))
        // The four DLLs are as much of what this step produces as the framework is, and
        // the only half a Wine rebuild can undo.
        for name in D3DMetalInstaller.appleOwnedDLLs {
            let dll = paths.engine.appending(path: "lib/wine/x86_64-windows/\(name)")
            try touch(dll)
            try Data(D3DMetalInstaller.appleMarker.utf8).write(to: dll)
        }
    case .gdkRuntime:
        try touch(GDKRuntime(paths: paths).dll)
    case .bottle:
        try touch(Bottle(paths: paths).systemRegistry)
    }
}

@Test func setupOpensOnTheFirstThingThatIsNotDone() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let setup = Setup(paths: paths, runtimeSources: nil)

    // Nothing on disk and a Mac that cannot do it: there is only one place to start.
    #expect(setup.current(machineIsReady: false) == .machine)
    #expect(setup.current(machineIsReady: true) == .sources)
    #expect(!setup.isComplete(machineIsReady: true))
}

@Test func eachStepFinishedMovesTheWizardToTheNextOne() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let setup = Setup(paths: paths, runtimeSources: nil)

    // The order Setup declares, so this also fails if the cases are reordered.
    let expected: [SetupStep] = [.sources, .prefix, .wine, .d3dMetal, .gdkRuntime, .bottle]
    for (index, step) in expected.enumerated() {
        #expect(setup.current(machineIsReady: true) == step)
        try finish(step, in: paths)
        if index == expected.count - 1 { break }
    }

    #expect(setup.isComplete(machineIsReady: true))
}

@Test func aStepWhosePrerequisiteIsMissingSaysWhichOne() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    let setup = Setup(paths: paths, runtimeSources: nil)

    func reason(_ step: SetupStep) -> String? {
        if case .blocked(let why) = setup.state(of: step, machineIsReady: true) { why } else { nil }
    }

    #expect(reason(.prefix)?.contains("sources") == true)
    #expect(reason(.wine)?.contains("bison") == true)
    #expect(reason(.d3dMetal)?.contains("Build Wine first") == true)
    #expect(reason(.gdkRuntime)?.contains("carries no source") == true)
    #expect(reason(.bottle)?.contains("Build Wine first") == true)

    // Wine's own prerequisite names the first library it cannot find, which is how the
    // wizard tells the user where to go back to.
    try finish(.sources, in: paths)
    try finish(.prefix, in: paths)
    #expect(setup.state(of: .wine, machineIsReady: true) == .ready)

    // The runtime needs the compiler the sources brought, and nothing Wine does.
    let runtimeSources = paths.root.deletingLastPathComponent().appending(path: "xgameruntime")
    try FileManager.default.createDirectory(at: runtimeSources, withIntermediateDirectories: true)
    #expect(Setup(paths: paths, runtimeSources: runtimeSources)
        .state(of: .gdkRuntime, machineIsReady: true) == .ready)
}

@Test func aMacThatIsNotReadyBlocksEverythingBelowTheFirstStep() throws {
    let paths = temporaryRoot()
    defer { remove(paths) }
    for step in SetupStep.allCases { try finish(step, in: paths) }
    let setup = Setup(paths: paths, runtimeSources: nil)

    #expect(setup.isComplete(machineIsReady: true))
    // A finished tree on a Mac that fails preflight is not finished: the check is the
    // first step, not a decoration.
    #expect(!setup.isComplete(machineIsReady: false))
    #expect(setup.current(machineIsReady: false) == .machine)
    #expect(setup.state(of: .machine, machineIsReady: false) == .ready)
}
