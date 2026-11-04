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
                WifiPlaceRadiusMap(coordinate: $draft.coordinate, radius: $draft.radius,
                                   tint: draft.tint, onChooseCoordinate: { coordinateChosen = true })
                    .frame(height: 230)
                    .listRowInsets(EdgeInsets())
                Stepper {
                    HStack {
                        Text("Radius")
                        Spacer()
                        Text(draft.radiusLabel).foregroundStyle(.secondary)
                    }
                } onIncrement: {
                    draft.radius = WifiPlace.steppedRadius(draft.radius, increasing: true)
                } onDecrement: {
                    draft.radius = WifiPlace.steppedRadius(draft.radius, increasing: false)
                }
                .accessibilityValue(draft.radiusLabel)
                .accessibilityIdentifier("wherewolf.wifiPlaces.radius")
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
                Text("Drag the map to move the pin and the handle to resize. The place applies only inside the circle, allowing for each fix’s own uncertainty.")
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

private struct WifiPlaceRadiusMap: View {
    @Binding var coordinate: CLLocationCoordinate2D
    @Binding var radius: Double
    let tint: Color
    let onChooseCoordinate: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: MapCameraPosition
    @State private var mapCenter: CLLocationCoordinate2D
    @State private var displayedRadius: Double
    @State private var resizing = false
    @State private var resizeStartRadius: Double?

    init(coordinate: Binding<CLLocationCoordinate2D>, radius: Binding<Double>, tint: Color,
         onChooseCoordinate: @escaping () -> Void) {
        _coordinate = coordinate
        _radius = radius
        self.tint = tint
        self.onChooseCoordinate = onChooseCoordinate
        _mapCenter = State(initialValue: coordinate.wrappedValue)
        _displayedRadius = State(initialValue: radius.wrappedValue)
        _position = State(initialValue: Self.fittedPosition(coordinate.wrappedValue, radius: radius.wrappedValue))
    }

    var body: some View {
        MapReader { proxy in
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let knob = proxy.convert(Self.east(of: mapCenter, meters: displayedRadius), to: .local)
                    ?? CGPoint(x: center.x + 50, y: center.y)
                Map(position: $position, interactionModes: resizing ? [] : [.pan, .zoom]) {
                    MapCircle(center: mapCenter, radius: displayedRadius)
                        .foregroundStyle(.blue.opacity(0.18))
                        .stroke(.blue, lineWidth: 1.5)
                }
                .mapStyle(.standard(elevation: .flat))
                .mapControls { }
                .onMapCameraChange(frequency: .continuous) { context in
                    guard !resizing, position.positionedByUser else { return }
                    mapCenter = context.camera.centerCoordinate
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    guard !resizing, position.positionedByUser else { return }
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
                .overlay(alignment: .bottomLeading) {
                    Text(WifiPlace.distanceLabel(displayedRadius))
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 20, height: 20)
                        .overlay { Image(systemName: "line.2.vertical").font(.system(size: 10, weight: .medium)).foregroundStyle(.gray) }
                        .shadow(color: .black.opacity(0.3), radius: 1)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .position(knob)
                        .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wifiPlaceMap"))
                            .onChanged { value in
                                if !resizing { resizeStartRadius = displayedRadius }
                                resizing = true
                                guard let point = proxy.convert(value.location, from: .local),
                                      let start = proxy.convert(value.startLocation, from: .local) else { return }
                                let origin = CLLocation(latitude: mapCenter.latitude, longitude: mapCenter.longitude)
                                let target = CLLocation(latitude: point.latitude, longitude: point.longitude)
                                let initial = CLLocation(latitude: start.latitude, longitude: start.longitude)
                                let change = origin.distance(from: target) - origin.distance(from: initial)
                                displayedRadius = min(2000, max(25, (resizeStartRadius ?? radius) + change))
                            }
                            .onEnded { _ in
                                radius = displayedRadius
                                resizing = false
                                resizeStartRadius = nil
                                fitRadius()
                            })
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Radius")
                        .accessibilityIdentifier("wherewolf.wifiPlaces.radiusHandle")
                        .accessibilityValue(WifiPlace.distanceLabel(displayedRadius))
                        .accessibilityHint("Swipe up or down to resize the place.")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: radius = WifiPlace.steppedRadius(radius, increasing: true)
                            case .decrement: radius = WifiPlace.steppedRadius(radius, increasing: false)
                            @unknown default: return
                            }
                        }
                }
                .coordinateSpace(name: "wifiPlaceMap")
                .onChange(of: coordinate.latitude) { _, _ in updateCoordinate() }
                .onChange(of: coordinate.longitude) { _, _ in updateCoordinate() }
                .onChange(of: radius) { _, value in
                    guard !resizing else { return }
                    displayedRadius = value
                    fitRadius()
                }
            }
        }
    }

    private func updateCoordinate() {
        guard abs(mapCenter.latitude - coordinate.latitude) > 0.0000001 ||
                abs(mapCenter.longitude - coordinate.longitude) > 0.0000001 else { return }
        mapCenter = coordinate
        fitRadius()
    }

    private func fitRadius() {
        let next = Self.fittedPosition(mapCenter, radius: displayedRadius)
        if reduceMotion { position = next }
        else { withAnimation(.easeInOut(duration: 0.35)) { position = next } }
    }

    private static func fittedPosition(_ coordinate: CLLocationCoordinate2D, radius: Double) -> MapCameraPosition {
        .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: radius * 3.5,
                                   longitudinalMeters: radius * 3.5))
    }

    private static func east(of coordinate: CLLocationCoordinate2D, meters: Double) -> CLLocationCoordinate2D {
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180
        let distance = meters / 6_371_000
        let targetLatitude = asin(sin(latitude) * cos(distance))
        let targetLongitude = longitude + atan2(sin(distance) * cos(latitude), cos(distance) - sin(latitude) * sin(targetLatitude))
        let degrees = targetLongitude * 180 / .pi
        return CLLocationCoordinate2D(latitude: targetLatitude * 180 / .pi,
                                      longitude: (degrees + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
}
