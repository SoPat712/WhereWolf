import SwiftUI

struct DawarichStatusRow: View {
    let status: DawarichStatus

    var body: some View {
        switch status {
        case .checking:
            HStack {
                Text("Server Type")
                Spacer()
                ProgressView().controlSize(.small).accessibilityLabel("Checking server type")
            }
        case .dawarich(let version, let authenticated):
            LabeledContent {
                Label(authenticated ? "Dawarich" + (version.map { " " + $0 } ?? "") : "Dawarich · API key not accepted",
                      systemImage: authenticated ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(authenticated ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text("Server Type")
            }
        case .unknown, .notDawarich:
            EmptyView()
        }
    }
}
