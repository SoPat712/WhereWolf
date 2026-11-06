import SwiftUI

struct HistoryGoToView: View {
    var history: HistoryPlaybackModel
    @Environment(\.dismiss) private var dismiss
    @State private var bridge = GLManagerBridge.shared
    @State private var time: Date
    @State private var now = Date()

    init(history: HistoryPlaybackModel) {
        self.history = history
        let now = Date()
        let window = history.landmarks.window(now: now) ?? now...now
        let selected = history.rulerTime ?? history.selectedPoint?.timestamp ?? now
        _time = State(initialValue: min(window.upperBound, max(window.lowerBound, selected)))
        _now = State(initialValue: now)
    }

    private var window: ClosedRange<Date> { history.landmarks.window(now: now) ?? now...now }

    var body: some View {
        let viewingID = history.landmarks.viewingRow(at: history.playbackIndex)?.id
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $time, in: window, displayedComponents: .date)
                    DatePicker("Time", selection: $time, in: window, displayedComponents: .hourAndMinute)
                }
                .datePickerStyle(.compact)
                ForEach(history.landmarks.journey) { day in
                    Section(day.id.formatted(date: .complete, time: .omitted)) {
                        ForEach(day.rows) { row in
                            Button {
                                history.scrub(pointAt: row.start)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: row.symbol)
                                        .foregroundStyle(WifiPlace.tint(for: row.color))
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.title).foregroundStyle(.primary)
                                        Text(row.detail(metric: bridge.speedUnit == "KM/H"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if viewingID == row.id {
                                        Text("Viewing").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Go To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") {
                        history.goTo(min(window.upperBound, max(window.lowerBound, time)))
                        dismiss()
                    }
                    .disabled(history.points.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: history.landmarks.timestamps.first) { _, _ in
            time = min(window.upperBound, max(window.lowerBound, time))
        }
    }
}
