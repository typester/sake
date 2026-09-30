import SakeKit
import SwiftUI

enum WineStatus: Equatable {
    case working(phase: String, line: String)
    case built(version: String)
    case alreadyBuilt
    case outdated
    case failed(String)
}

struct WineView: View {
    let status: WineStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("wine")
                    .font(.callout.monospaced())
                    .frame(width: 190, alignment: .leading)

                switch status {
                case .none:
                    Text("waiting")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                case .working(let phase, let line):
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                case .built(let version):
                    Text(version.isEmpty ? "built" : "built — \(version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .alreadyBuilt:
                    Text("already built")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .outdated:
                    Text("needs building again")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .failed(let reason):
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
    }
}
