import SwiftUI

struct DawarichStatusRow: View {
    let status: DawarichStatus
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        switch status {
        case .checking:
            HStack {
                Text("Server Type")
                Spacer()
                ProgressView().controlSize(.small).accessibilityLabel("Checking server type")
            }
        case .dawarich(let version, let authenticated, let account):
            LabeledContent {
                Label(authenticated ? "Dawarich" + (version.map { " " + $0 } ?? "") : "Dawarich · API key not accepted",
                      systemImage: authenticated ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(authenticated ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text("Server Type")
            }
            if let account {
                accountRow(account)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "Dawarich account, " + account))
            }
        case .unknown, .notDawarich:
            EmptyView()
        }
    }

    @ViewBuilder private func accountRow(_ account: String) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text("Account")
                accountText(account)
            }
        } else {
            LabeledContent {
                accountText(account)
            } label: {
                Text("Account")
            }
        }
    }

    private func accountText(_ account: String) -> some View {
        Text(verbatim: account)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}
