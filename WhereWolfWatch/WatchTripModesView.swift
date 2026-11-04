import SwiftUI

struct WatchTripModesView: View {
    let model: WatchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(model.status?.modes ?? []) { mode in
            Button {
                model.send(.startTrip(mode: mode.id))
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    WatchRowIcon(symbol: mode.symbol, color: .blue)
                    Text(mode.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 44)
            }
            .disabled(model.busy || model.unreachable || model.status?.tripActive != false)
        }
        .navigationTitle("Start Trip")
        .watchCommandProgress(model.busy)
    }
}
