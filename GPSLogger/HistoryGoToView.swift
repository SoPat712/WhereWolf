import SwiftUI

struct HistoryGoToView: View {
    var history: HistoryPlaybackModel
    @Environment(\.dismiss) private var dismiss
    @State private var bridge = GLManagerBridge.shared
    @State private var time: Date
    @State private var now = Date()
    @State private var detent: PresentationDetent = .medium

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
        let metric = bridge.speedUnit == "KM/H"
        NavigationStack {
            Form {
                Section("Jump To") {
                    DatePicker("Date", selection: $time, in: window, displayedComponents: .date)
                    DatePicker("Time", selection: $time, in: window, displayedComponents: .hourAndMinute)
                }
                .datePickerStyle(.compact)
                .settingsRowBackground()
                ForEach(history.landmarks.journey) { day in
                    Section {
                        ForEach(day.rows) { row in
                            Button {
                                history.scrub(pointAt: row.start)
                                dismiss()
                            } label: {
                                HistoryGoToRow(row: row, metric: metric, viewing: viewingID == row.id)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HistoryGoToDayHeader(day: day, metric: metric)
                    }
                    .settingsRowBackground()
                }
            }
            .settingsFormStyle()
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
        .environment(\.glassSettingsSheet, true)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackground { ExpandingSheetBackground(detent: detent) }
        .onAppear { history.refreshLandmarks() }
        .onChange(of: history.landmarks.timestamps.first) { _, _ in
            time = min(window.upperBound, max(window.lowerBound, time))
        }
    }
}

private struct HistoryGoToDayHeader: View {
    let day: HistoryJourneyDay
    let metric: Bool

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day.id) { return "Today" }
        if calendar.isDateInYesterday(day.id) { return "Yesterday" }
        return day.id.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var summary: String {
        let stops = day.rows.filter(\.isStop).count
        let distance = day.rows.compactMap(\.distance).reduce(0, +)
        let count = stops == 1 ? "1 stop" : "\(stops) stops"
        return distance > 0 ? "\(count) · \(ReplayStatus.distanceText(distance, metric: metric))" : count
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 8)
            Text(summary)
                .monospacedDigit()
                .textCase(nil)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryGoToRow: View {
    let row: HistoryJourneyRow
    let metric: Bool
    let viewing: Bool

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: row.symbol, color: WifiPlace.tint(for: row.color))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if viewing {
                        Text("Viewing")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                Text(row.timeRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ReplayActivity.format(row.endTime.timeIntervalSince(row.startTime)))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                if let distance = row.distance {
                    Text(ReplayStatus.distanceText(distance, metric: metric))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(viewing ? .isSelected : [])
    }
}
