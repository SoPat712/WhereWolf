import MapKit
import SwiftUI

struct WorkoutImportView: View {
    @State private var bridge = GLManagerBridge.shared
    private var importer: WorkoutRouteImporter { bridge.workoutImporter }

    var body: some View {
        Form {
            Section {
                if !importer.available {
                    Label("Apple Health is unavailable in this build", systemImage: "heart.slash")
                        .foregroundStyle(.secondary)
                }
                Button(importer.connected ? "Review Health Access" : "Connect Apple Health") {
                    Task { await importer.connect() }
                }
                .disabled(importer.busy || !importer.available)
                Toggle("Import When WhereWolf Opens", isOn: Binding(
                    get: { importer.automatic }, set: { bridge.setAutomaticWorkoutImport($0) }))
                    .disabled(!importer.connected || !importer.available)
                Picker("Look Back", selection: Binding(
                    get: { importer.days }, set: { bridge.setWorkoutImportDays($0) })) {
                    Text("24 Hours").tag(1)
                    Text("7 Days").tag(7)
                    Text("30 Days").tag(30)
                }
                .disabled(importer.busy)
                Button("Check for Workouts", systemImage: "arrow.clockwise") {
                    Task { await importer.refresh(importAutomatically: true) }
                }
                .disabled(importer.busy || !importer.connected || !importer.available)
                if importer.busy { ProgressView("Reading workout routes…") }
                if let error = importer.error { Text(error).foregroundStyle(.orange).font(.footnote) }
                if let message = importer.message { Text(message).foregroundStyle(.secondary).font(.footnote) }
            } header: {
                Text("Workout Import")
            } footer: {
                Text("Copies routes that Workouts and other apps saved to Health. Nothing is written to Health or uploaded automatically, and your watch may need time to sync.")
            }

            Section {
                if importer.imported.isEmpty {
                    Text("No imported routes").foregroundStyle(.secondary)
                }
                ForEach(importer.imported) { item in
                    NavigationLink {
                        ImportedWorkoutView(id: item.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.workout.name).font(.body.weight(.medium))
                            Text(item.workout.start.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text("\(item.count.formatted()) points · \(item.workout.source)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Imported Routes")
            } footer: {
                Text("Kept apart from the Tracker timeline, location and trips until you remove them. Open a route to send its points.")
            }

            if importer.connected {
                Section {
                    ForEach(importer.workouts) { workout in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workout.name)
                                Text("\(workout.source) · \(workout.start.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button(importer.imported.contains(where: { $0.id == workout.id }) ? "Update" : "Import") {
                                Task { await importer.importWorkout(workout) }
                            }
                            .glassButtonStyle()
                            .disabled(importer.busy)
                        }
                    }
                    if importer.workouts.isEmpty {
                        Text("No readable workouts in this period. Health doesn’t say whether access was denied; review it in the Health app.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Recent Workouts · Up to 100")
                } footer: {
                    Text("Workouts without routes remain available to retry after syncing. WhereWolf’s own Health exports are excluded.")
                }
            }
        }
        .navigationTitle("Import Workout Routes")
        .navigationBarTitleDisplayMode(.inline)
        .settingsFormStyle()
        .task {
            await importer.loadSaved()
            if importer.connected && importer.available { await importer.refresh() }
        }
    }
}

private struct ImportedWorkoutView: View {
    let id: UUID
    @State private var bridge = GLManagerBridge.shared
    @State private var locations: [CLLocation] = []
    @State private var error: String?
    @State private var confirmRemoval = false
    @Environment(\.dismiss) private var dismiss
    private var importer: WorkoutRouteImporter { bridge.workoutImporter }
    private var item: ImportedWorkout? { importer.imported.first { $0.id == id } }

    var body: some View {
        Form {
            if let item {
                Section {
                    if !locations.isEmpty {
                        Map(initialPosition: .automatic) {
                            if locations.count > 1 {
                                MapPolyline(coordinates: locations.map(\.coordinate))
                                    .stroke(.blue, lineWidth: ReplayRouteStyle.pastWidth)
                            }
                            if let first = locations.first { Marker("Start", coordinate: first.coordinate).tint(.green) }
                            if let last = locations.last, locations.count > 1 { Marker("Finish", coordinate: last.coordinate).tint(.red) }
                        }
                        .frame(height: 270)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .listRowInsets(EdgeInsets())
                    } else if error == nil { ProgressView("Loading route…") }
                    LabeledContent("Recorded By", value: item.workout.source)
                    LabeledContent("Started", value: item.workout.start.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Points", value: item.count.formatted())
                    LabeledContent("Distance", value: Measurement(value: item.workout.distance, unit: UnitLength.meters)
                        .formatted(.measurement(width: .abbreviated, usage: .road)))
                }
                Section {
                    Button("Queue Points for Destination", systemImage: "arrow.up.doc") {
                        Task { await importer.queue(item) }
                    }
                    .disabled(importer.busy || !item.needsQueue)
                    if !item.needsQueue {
                        Label("Points have been queued", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    if importer.busy { ProgressView() }
                    if let error = importer.error ?? error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    if let message = importer.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } footer: {
                    Text("Queues the points, with original timestamps and source, to go out at your send interval. Needs All Data logging or iCloud export and a destination that accepts past points; overlapping phone points stay a separate source.")
                }
                Section {
                    Button("Remove Local Route", role: .destructive) { confirmRemoval = true }
                        .disabled(importer.busy)
                } footer: {
                    Text("Removes only this local copy; Health and queued or uploaded points stay. You can import it again.")
                }
            }
        }
        .navigationTitle(item?.workout.name ?? "Workout Route")
        .navigationBarTitleDisplayMode(.inline)
        .settingsFormStyle()
        .task(id: item?.revision) {
            do {
                let points = try await importer.store.locations(for: id)
                guard !Task.isCancelled else { return }
                locations = points
                error = nil
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .confirmationDialog("Remove this imported route from WhereWolf?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove Local Route", role: .destructive) {
                Task { await importer.remove(id); if !importer.imported.contains(where: { $0.id == id }) { dismiss() } }
            }
        }
    }
}
