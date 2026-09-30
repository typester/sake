import Foundation

/// The steps of first-time setup, in the order their prerequisites force. Nothing here is
/// a preference: each one needs what the one above it produced.
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

    public var isDone: Bool { self == .done }
}

/// How far setup has got, read from what is on disk.
///
/// This lives in SakeKit rather than in the wizard because it is the only real decision the
/// wizard makes; what is left there is a window and a button.
public struct Setup: Sendable {
    private let paths: Paths
    private let runtimeSources: URL?

    public init(paths: Paths = .default, runtimeSources: URL? = GDKRuntimeBuilder.bundled) {
        self.paths = paths
        self.runtimeSources = runtimeSources
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
            return state(WineBuilder(paths: paths).isBuilt,
                         WineBuilder(paths: paths).missingPrerequisite,
                         machineIsReady)

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

    private func state(_ isDone: Bool, _ missing: String?, _ machineIsReady: Bool) -> StepState {
        if isDone { return .done }
        guard machineIsReady else { return .blocked(Self.machineNotReady) }
        if let missing { return .blocked(missing) }
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
}
