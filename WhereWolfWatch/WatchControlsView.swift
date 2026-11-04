import SwiftUI
import WatchKit

struct WatchControlsView: View {
    let model: WatchModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingStop = false
    @State private var confirmingEnd = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                List {
                    if model.status != nil || model.unreachable {
                        let home = WatchHomePresentation(status: model.status, unreachable: model.unreachable,
                                                         busy: model.busy, now: context.date)
                        WatchTrackingHero(home: home) {
                            if home.hero == .off {
                                model.send(.setTracking(true))
                            } else {
                                confirmingStop = true
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))

                        ForEach(home.rows) { row in
                            control(row)
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("WhereWolf")
            .watchCommandProgress(model.busy)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.send(.refresh) }
        }
        .confirmationDialog("Stop Tracking?", isPresented: $confirmingStop) {
            Button("Stop Tracking", role: .destructive) { model.send(.setTracking(false)) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("New locations stop recording. Waiting ones stay saved.")
        }
        .confirmationDialog("End this trip?", isPresented: $confirmingEnd) {
            Button("End Trip", role: .destructive) { model.send(.endTrip) }
            Button("Keep Going", role: .cancel) { }
        }
    }

    @ViewBuilder
    private func control(_ row: WatchHomePresentation.Row) -> some View {
        switch row.id {
        case .refresh:
            Button { model.send(.refresh) } label: {
                WatchRowLabel(row: row, symbol: "arrow.clockwise", color: .blue)
            }
            .disabled(!row.isEnabled)
        case .retryUpdates:
            Button { model.send(.retryUpdates) } label: {
                WatchRowLabel(row: row, symbol: "arrow.clockwise", color: .orange)
            }
            .disabled(!row.isEnabled)
        case .startTrip:
            NavigationLink {
                WatchTripModesView(model: model)
            } label: {
                WatchRowLabel(row: row, symbol: "play.fill", color: .blue)
            }
            .disabled(!row.isEnabled)
        case .trip:
            if let status = model.status {
                WatchTripCard(status: status)
                    .opacity(row.isEnabled ? 1 : 0.45)
            }
        case .endTrip:
            // A separate native row gives End Trip its own full-size hit target.
            Button { confirmingEnd = true } label: {
                WatchRowLabel(row: row, symbol: "stop.fill", color: .gray)
            }
            .disabled(!row.isEnabled)
        case .sendNow:
            Button { model.send(.sendNow) } label: {
                WatchRowLabel(row: row, symbol: "arrow.up", color: .indigo)
            }
            .disabled(!row.isEnabled)
        case .preset:
            NavigationLink {
                WatchPresetsView(model: model)
            } label: {
                WatchRowLabel(row: row, symbol: "slider.horizontal.3", color: .gray)
            }
            .disabled(!row.isEnabled)
        }
    }
}

private struct WatchTrackingHero: View {
    let home: WatchHomePresentation
    let action: () -> Void

    private var diameter: CGFloat { 84 * WKInterfaceDevice.current().screenBounds.width / 208 }

    private var color: Color {
        switch home.hero {
        case .tracking, .off: .green
        case .stale: .orange
        case .unreachable: .gray
        }
    }

    private var symbol: String {
        switch home.hero {
        case .tracking, .off: "location.fill"
        case .stale: "exclamationmark"
        case .unreachable: "iphone.slash"
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.4, weight: .semibold))
                    .foregroundStyle(home.hero == .off ? Color.black : color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(WatchHeroButtonStyle(color: color, filled: home.hero == .off))
            .frame(width: diameter, height: diameter)
            .disabled(!home.heroIsEnabled)
            .accessibilityLabel(home.heroLabel)
            .accessibilityValue(home.heroValue)
            .accessibilityIdentifier("watch.tracking")

            Text(home.title)
                .font(.headline)
                .padding(.top, 6)
            Text(home.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

// Flat on purpose: the owner rejected glass on the watch.
private struct WatchHeroButtonStyle: ButtonStyle {
    let color: Color
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(filled ? color : color.opacity(0.18)))
            .overlay {
                if !filled { Circle().strokeBorder(color, lineWidth: 3) }
            }
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct WatchTripCard: View {
    let status: WatchStatus

    private var symbol: String {
        status.tripSymbol ?? status.modes.first { $0.name == status.tripMode }?.symbol ?? WatchTripMode.fallbackSymbol
    }

    private var distance: String {
        Measurement(value: status.tripDistance, unit: UnitLength.meters)
            .converted(to: status.metric ? .kilometers : .miles)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    var body: some View {
        HStack(spacing: 10) {
            WatchRowIcon(symbol: symbol, color: .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.tripMode ?? "Trip")
                    .font(.body)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        timer
                        if status.tripStart != nil { Text("·") }
                        Text(distance)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        timer
                        Text(distance)
                    }
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var timer: some View {
        if let start = status.tripStart { Text(start, style: .timer).fixedSize() }
    }
}
