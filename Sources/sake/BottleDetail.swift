import SakeKit
import SwiftUI

/// One bottle, on its own. What is in it, what can be put in it — which is the only thing a
/// bottle just created can do — and the two ways it can be taken away again.
struct BottleDetail: View {
    let bottle: Bottle
    let titles: [Title]
    /// What it occupies, or `nil` while that is still being added up.
    let size: Int64?
    /// What went wrong the last time something was done to it, as a sentence.
    let problem: String?
    /// Whether there is a CrossOver bottle to import from at all. Without one the sheet can
    /// only say why it cannot work, so the way in is not offered.
    let canImport: Bool
    /// How many things a CrossOver bottle has that this one does not, or `nil` when that
    /// has not been worked out for this bottle.
    let importCandidates: Int?
    let importing: () -> Void
    let installing: () -> Void
    let addingTitle: () -> Void
    let renaming: () -> Void
    let deleting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(bottle.name)
                    .font(.largeTitle.weight(.semibold))
                Text(bottle.url.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                if canImport {
                    Button("Import from CrossOver…", action: importing)
                        .controlSize(.large)
                }
                Button("Install from an Installer…", action: installing)
                    .controlSize(.large)
                Button("Add a Title…", action: addingTitle)
                    .controlSize(.large)
                Spacer(minLength: 24)
                Button("Rename…", action: renaming)
                    .controlSize(.large)
                Button("Delete…", action: deleting)
                    .controlSize(.large)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(holds)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(counts)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                if let importCandidates, importCandidates > 0 {
                    Text("""
                        \(importCandidates) in a CrossOver bottle could come over, and \
                        cloning costs nothing.
                        """)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var holds: String {
        let games = titles.isEmpty
            ? "nothing that can be started"
            : "\(titles.count) that can be started"
        guard let size else { return games }
        return "\(games) — \(size.formatted(.byteCount(style: .file))) on disk"
    }

    /// syswow64 is here for the same reason the wizard shows it: it is empty on a prefix
    /// that looks complete, and nothing 32-bit runs then. See docs/runtime.md.
    private var counts: String {
        let files = bottle.systemFileCounts()
        return """
            system32 \(files.system32.formatted()) / \
            syswow64 \(files.sysWoW64.formatted()) files
            """
    }
}
