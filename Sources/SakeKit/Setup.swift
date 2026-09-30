import Foundation

/// The steps of first-time setup. None comes before a step whose product it needs; the GDK
/// runtime needs only the sources, and goes after D3DMetal so that the bottle stays last.
public enum SetupStep: String, CaseIterable, Sendable, Identifiable {
    case machine
    case sources
    case prefix
    case wine
    case d3dMetal
    case gdkRuntime
    case bottle

    public var id: String { rawValue }
}

public enum StepState: Sendable, Equatable {
    case done
    case ready
    /// Why it cannot be started yet, as a sentence.
    case blocked(String)
    /// Done once and not any more: why, as sentences.
    case outdated(String)

    public var isDone: Bool { self == .done }

    /// What the wizard says about the step, when there is anything to say.
    public var reason: String? {
        switch self {
        case .blocked(let why), .outdated(let why): why
        case .done, .ready: nil
        }
    }
}

/// How far setup has got, read from what is on disk.
///
/// This lives in SakeKit rather than in the wizard because it is the only real decision the
/// wizard makes; what is left there is a window and a button.
public struct Setup: Sendable {
    private let paths: Paths
    private let runtimeSources: URL?
    private let patches: URL?

    public init(
        paths: Paths = .default,
        runtimeSources: URL? = GDKRuntimeBuilder.bundled,
        patches: URL? = WinePatcher.bundled
    ) {
        self.paths = paths
        self.runtimeSources = runtimeSources
        self.patches = patches
    }

    static let machineNotReady = "This Mac is not ready yet."

    /// `machineIsReady` is handed in rather than worked out here. ``Preflight/run()`` is
    /// async, and taking it inside would make every question about the wizard's state
    /// async with it.
    public func state(of step: SetupStep, machineIsReady: Bool) -> StepState {
        switch step {
        case .machine:
            // Never "blocked": whatever is missing is the user's to install, and the
            // requirement rows say which.
            return machineIsReady ? .done : .ready

        case .sources:
            guard machineIsReady else { return .blocked(Self.machineNotReady) }
            return Component.all.allSatisfy { $0.isUnpacked(in: paths) } ? .done : .ready

        case .prefix:
            guard machineIsReady else { return .blocked(Self.machineNotReady) }
            if BuildRecipe.all.allSatisfy({ $0.isBuilt(in: paths.engine) }) { return .done }
            // The only step with no `missingPrerequisite` of its own: what it needs is the
            // step above it.
            guard state(of: .sources, machineIsReady: machineIsReady).isDone else {
                return .blocked("The sources are not all unpacked yet.")
            }
            return .ready

        case .wine:
            let builder = WineBuilder(paths: paths, patcher: WinePatcher(directory: patches))
            return state(builder.isBuilt, builder.missingPrerequisite, machineIsReady,
                         outdated: builder.outdatedReason)

        case .d3dMetal:
            return state(D3DMetalInstaller(paths: paths).isInstalled,
                         D3DMetalInstaller(paths: paths).missingPrerequisite,
                         machineIsReady)

        case .gdkRuntime:
            let builder = GDKRuntimeBuilder(paths: paths, sources: runtimeSources)
            return state(builder.isBuilt, builder.missingPrerequisite, machineIsReady)

        case .bottle:
            let builder = BottleBuilder(paths: paths)
            return state(builder.bottle.exists, builder.missingPrerequisite, machineIsReady)
        }
    }

    private func state(
        _ isDone: Bool, _ missing: String?, _ machineIsReady: Bool, outdated: String? = nil
    ) -> StepState {
        if isDone { return .done }
        guard machineIsReady else { return .blocked(Self.machineNotReady) }
        if let missing { return .blocked(missing) }
        if let outdated { return .outdated(outdated) }
        return .ready
    }

    /// The first step that is not finished, which is where the wizard opens.
    public func current(machineIsReady: Bool) -> SetupStep {
        SetupStep.allCases.first { !state(of: $0, machineIsReady: machineIsReady).isDone }
            ?? SetupStep.allCases[SetupStep.allCases.count - 1]
    }

    public func isComplete(machineIsReady: Bool) -> Bool {
        SetupStep.allCases.allSatisfy { state(of: $0, machineIsReady: machineIsReady).isDone }
    }

    /// Whether the wizard opens itself at launch: only until setup has been finished once,
    /// which a bottle says, making one being the last step. A step an update leaves to do
    /// again is pointed out instead, because the window was in the way.
    public func opensItself(machineIsReady: Bool) -> Bool {
        !isComplete(machineIsReady: machineIsReady) && Bottle.all(in: paths).isEmpty
    }

    public func needsAttention(machineIsReady: Bool) -> Bool {
        !isComplete(machineIsReady: machineIsReady) && !Bottle.all(in: paths).isEmpty
    }
}
