import SwiftUI
import MapKit

struct WifiPlaceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var bridge = GLManagerBridge.shared
    @State private var draft: WifiPlace
    @State private var coordinateChosen: Bool
    @State private var showingNetworks = false
    @State private var showingIcon = false
    @State private var confirmingDelete = false
    @State private var saveFailed = false
    private let isNew: Bool

    init(place: WifiPlace? = nil) {
        isNew = place == nil
        let location = GLManagerBridge.shared.wifiPlaceLocation
        _draft = State(initialValue: place ?? WifiPlace(latitude: location?.coordinate.latitude ?? 0,
                                                       longitude: location?.coordinate.longitude ?? 0))
        _coordinateChosen = State(initialValue: place != nil || location != nil)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Button { showingIcon = true } label: {
                        WifiPlaceIconTile(symbol: draft.symbol, color: draft.tint, size: 36)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Change icon")
                    .accessibilityIdentifier("wherewolf.wifiPlaces.icon")
                    TextField("Name", text: Binding(get: { draft.name }, set: { draft.rename(to: $0) }))
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .accessibilityIdentifier("wherewolf.wifiPlaces.name")
                }
            }

            Section {
                WifiPlaceMap(coordinate: $draft.coordinate, tint: draft.tint,
                             onChooseCoordinate: { coordinateChosen = true })
                    .frame(height: 230)
                    .listRowInsets(EdgeInsets())
                Button("Use Current Location") {
                    guard let location = bridge.wifiPlaceLocation else { return }
                    coordinateChosen = true
                    draft.coordinate = location.coordinate
                }
                .disabled(bridge.wifiPlaceLocation == nil)
                if !coordinateChosen {
                    Text("Move the map or use your current location to choose a point.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Drag the map to move the pin. WhereWolf uses this point while you’re connected to these networks within about \(WifiPlace.distanceLabel(GLWifiPlaceMatchDistance)) of it.")
            }

            Section {
                ForEach(draft.networks, id: \.self) { name in
                    HStack(spacing: 12) {
                        WifiPlaceIconTile(symbol: "wifi", color: name == bridge.currentWifiSSID ? .green : .gray)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name)
                            Text(networkDetail(name))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .deleteDisabled(draft.networks.count <= 1)
                }
                .onDelete { offsets in
                    guard draft.networks.count - offsets.count >= 1 else { return }
                    draft.networks.remove(atOffsets: offsets)
                }
                Button("Add Network…") { showingNetworks = true }
                    .accessibilityIdentifier("wherewolf.wifiPlaces.networks")
            } header: {
                Text("Networks")
            } footer: {
                Text("Every access point on these networks counts, however many there are. Swipe to remove a network.")
            }

            Section {
                Picker("Record", selection: $draft.record) {
                    ForEach(WifiPlace.Recording.allCases) { recording in
                        Text(recording.label).tag(recording)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("While Connected Here")
            } footer: {
                Text(draft.record.footer)
            }

            if !isNew {
                Section {
                    Button("Delete Place", role: .destructive) { confirmingDelete = true }
                        .frame(maxWidth: .infinity)
                }
            }
            if saveFailed {
                Section {
                    Text("Your changes could not be saved. Try again.")
                        .foregroundStyle(.red)
                    Button("Try Again") { saveDraft() }
                }
            }
        }
        .settingsFormStyle()
        .navigationTitle(isNew ? "Add Place" : (draft.name.isEmpty ? "Place" : draft.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("wherewolf.wifiPlaces.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard bridge.saveWifiPlace(draft) else { saveFailed = true; return }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .accessibilityIdentifier("wherewolf.wifiPlaces.confirm")
                }
            }
        }
        .sheet(isPresented: $showingNetworks) {
            WifiPlaceNetworksView(place: draft) { names in
                draft.networks.append(contentsOf: names.filter { !draft.networks.contains($0) })
            }
        }
        .sheet(isPresented: $showingIcon) {
            WifiPlaceIconView(name: draft.name, symbol: draft.symbol, color: draft.color) { symbol, color in
                draft.symbolChosen = true
                draft.symbol = symbol
                draft.color = color
            }
        }
        .confirmationDialog("Delete “\(draft.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Place", role: .destructive) {
                guard bridge.removeWifiPlace(draft) else { saveFailed = true; return }
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the place and its network assignments.")
        }
        .onChange(of: draft) { _, _ in
            if !isNew, canSave { saveDraft() }
        }
        .task { _ = await bridge.refreshWifiNetwork() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { _ = await bridge.refreshWifiNetwork() } }
        }
    }

    private var canSave: Bool { coordinateChosen && draft.isValid }

    private func networkDetail(_ name: String) -> String {
        if name == bridge.currentWifiSSID { return "Connected now" }
        return bridge.observedWifiNetworks.first { $0.name == name }?.seenLabel ?? "Not seen yet"
    }

    private func saveDraft() {
        guard canSave else { return }
        saveFailed = !bridge.saveWifiPlace(draft)
    }
}

private struct WifiPlaceMap: View {
    @Binding var coordinate: CLLocationCoordinate2D
    let tint: Color
    let onChooseCoordinate: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: MapCameraPosition
    @State private var mapCenter: CLLocationCoordinate2D

    init(coordinate: Binding<CLLocationCoordinate2D>, tint: Color,
         onChooseCoordinate: @escaping () -> Void) {
        _coordinate = coordinate
        self.tint = tint
        self.onChooseCoordinate = onChooseCoordinate
        _mapCenter = State(initialValue: coordinate.wrappedValue)
        _position = State(initialValue: Self.position(coordinate.wrappedValue))
    }

    var body: some View {
        Map(position: $position, interactionModes: [.pan]) { }
            .mapStyle(.standard(elevation: .flat))
            .mapControls { }
            .onMapCameraChange(frequency: .onEnd) { context in
                guard position.positionedByUser else { return }
                mapCenter = context.camera.centerCoordinate
                onChooseCoordinate()
                coordinate = mapCenter
            }
            .overlay {
                Image(systemName: "mappin")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(tint)
                    .offset(y: -16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: coordinate.latitude) { _, _ in updateCoordinate() }
            .onChange(of: coordinate.longitude) { _, _ in updateCoordinate() }
    }

    private func updateCoordinate() {
        guard abs(mapCenter.latitude - coordinate.latitude) > 0.0000001 ||
                abs(mapCenter.longitude - coordinate.longitude) > 0.0000001 else { return }
        mapCenter = coordinate
        let next = Self.position(coordinate)
        if reduceMotion { position = next }
        else { withAnimation(.easeInOut(duration: 0.35)) { position = next } }
    }

    private static func position(_ coordinate: CLLocationCoordinate2D) -> MapCameraPosition {
        .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 400,
                                   longitudinalMeters: 400))
    }
}
