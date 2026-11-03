import SwiftUI

struct WatchControlsView: View {
    let model: WatchModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingStop = false
    @State private var confirmingEnd = false

    var body: some View {
        NavigationStack {
            List {
                if model.unreachable {
                    Label("iPhone not reachable", systemImage: "iphone.slash")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let status = model.status {
                    controls(status)
                } else if !model.unreachable {
                    ProgressView()
                }
            }
            .navigationTitle("WhereWolf")
            .toolbar {
                if model.busy {
                    ToolbarItem(placement: .topBarTrailing) { ProgressView() }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.send(.refresh) }
        }
        .confirmationDialog("Stop location tracking?", isPresented: $confirmingStop) {
            Button("Stop Tracking", role: .destructive) { model.send(.setTracking(false)) }
            Button("Keep Tracking", role: .cancel) { }
        } message: {
            Text("New locations will stop recording. Queued locations stay saved for sending later.")
        }
        .confirmationDialog("End this trip?", isPresented: $confirmingEnd) {
            Button("End Trip", role: .destructive) { model.send(.endTrip) }
            Button("Keep Going", role: .cancel) { }
        }
    }

    @ViewBuilder
    private func controls(_ status: WatchStatus) -> some View {
        Section {
            Toggle("Tracking", isOn: Binding(
                get: { status.tracking },
                set: { enabled in
                    if enabled { model.send(.setTracking(true)) } else { confirmingStop = true }
                }))
            if let lastFix = status.lastFix {
                Text("Updated \(lastFix, style: .relative) ago")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if status.isStale(at: Date()) {
                Button("Retry Updates", systemImage: "arrow.clockwise") { model.send(.retryUpdates) }
            }
        }

        Section("Trip") {
            if status.tripActive {
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.tripMode ?? "Trip").font(.headline)
                    if let start = status.tripStart {
                        Text(start, style: .timer).monospacedDigit()
                    }
                    Text(distanceText(status)).font(.footnote).foregroundStyle(.secondary)
                }
                Button("End Trip", systemImage: "stop.fill", role: .destructive) { confirmingEnd = true }
            } else {
                NavigationLink {
                    WatchTripModesView(modes: status.modes) { model.send(.startTrip(mode: $0)) }
                } label: {
                    Label("Start Trip", systemImage: "play.fill")
                }
            }
        }

        Section("Sending") {
            Button("Send Now", systemImage: "arrow.up.circle") { model.send(.sendNow) }
                .disabled(status.queued == 0)
            Text(status.queued == 1 ? "1 location waiting" : "\(status.queued.formatted()) locations waiting")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section {
            Picker("Usage Preset", selection: Binding(
                get: { status.preset },
                set: { model.send(.setPreset($0)) })) {
                if status.preset == WatchStatus.customPreset {
                    Text("Custom").tag(WatchStatus.customPreset)
                }
                ForEach(WatchStatus.presets, id: \.id) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .disabled(status.tripActive)
        } footer: {
            if status.tripActive { Text("Presets can't change during a trip.") }
        }
    }

    private func distanceText(_ status: WatchStatus) -> String {
        Measurement(value: status.tripDistance, unit: UnitLength.meters)
            .converted(to: status.metric ? .kilometers : .miles)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
    }
}

private struct WatchTripModesView: View {
    let modes: [WatchTripMode]
    let start: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(modes) { mode in
            Button {
                start(mode.id)
                dismiss()
            } label: {
                Label(mode.name, systemImage: "location.fill")
            }
        }
        .navigationTitle("Start Trip")
    }
}
