import SwiftUI
import MapKit

struct WifiZoneListView: View {
    private struct Editor: Identifiable {
        let id = UUID()
        var zone: [String: String]?
    }

    @State private var bridge = GLManagerBridge.shared
    @State private var editor: Editor?

    var body: some View {
        List {
            Section {
                if bridge.wifiZones.isEmpty {
                    Text("Choose the networks at a place and give them one shared location.")
                        .foregroundStyle(.secondary)
                }
                ForEach(bridge.wifiZones.indices, id: \.self) { index in
                    let zone = bridge.wifiZones[index]
                    Button {
                        editor = Editor(zone: zone)
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(symbol: "wifi", color: .blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(zone["name"] ?? "").foregroundStyle(.primary)
                                Text(zone["bssid"] ?? "Any access point")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(zone["latitude"] ?? "0"), \(zone["longitude"] ?? "0")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { bridge.removeWifiZones(at: $0) }
            } footer: {
                Text("Each network has one location. The same name can have different locations when its access-point address (BSSID) differs. Tap a network to edit its assignment.")
            }
        }
        .navigationTitle("WiFi Zones")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SettingsHelpButton(topic: .automation) }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editor = Editor()
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add Zone")
            }
        }
        .sheet(item: $editor) { editor in
            AddWifiZoneView(seed: editor.zone, onSave: bridge.refresh)
        }
        .onAppear { bridge.refresh() }
    }
}

struct AddWifiZoneView: View {
    var seed: [String: String]? = nil
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var bridge = GLManagerBridge.shared
    @State private var networks: [WifiZoneNetwork] = []
    @State private var selected: Set<WifiZoneNetwork> = []
    @State private var current: WifiZoneNetwork?
    @State private var name = ""
    @State private var bssid = ""
    @State private var showingCoordinateMap = false
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var loaded = false
    @State private var saveFailed = false

    private var manualNetwork: WifiZoneNetwork? { WifiZoneNetwork(name: name, bssid: bssid) }
    private var validLocation: Bool {
        guard let lat = Double(latitude), let lon = Double(longitude) else { return false }
        return lat.isFinite && lon.isFinite && (-90...90).contains(lat) && (-180...180).contains(lon)
    }
    private var hasExistingSelection: Bool {
        bridge.wifiZones.contains { zone in WifiZoneNetwork(zone).map { selected.contains($0) } ?? false }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(networks) { network in
                        Button {
                            if selected.contains(network) { selected.remove(network) }
                            else { selected.insert(network) }
                        } label: {
                            HStack(spacing: 12) {
                                SettingsIcon(symbol: "wifi", color: .blue)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(network.name).foregroundStyle(.primary)
                                    Text(network.bssid ?? "Any access point")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if network == current {
                                        Text("Connected").font(.caption).foregroundStyle(.blue)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: selected.contains(network) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(network) ? Color.blue : Color.secondary)
                                    .font(.title3)
                            }
                        }
                        .accessibilityLabel(network.name + (network.bssid.map { ", \($0)" } ?? ", any access point"))
                        .accessibilityValue(selected.contains(network) ? "Selected" : "Not selected")
                    }
                    if current == nil {
                        Label("Current network unavailable", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.secondary)
                        Text("Connect to WiFi and allow Precise Location. Network identification also requires WiFi access in the app’s signing profile.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Refresh Networks", systemImage: "arrow.clockwise") { loadNetworks() }
                } header: {
                    Text("Choose Networks")
                } footer: {
                    Text("Select the networks that share this location. This list includes networks WhereWolf has seen or you have saved. iOS does not provide a nearby-network scan or access to its full saved-network list. To add another connected network, switch to it in iOS Settings and refresh.")
                }

                Section {
                    TextField("Network name (SSID)", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("BSSID (optional)", text: $bssid)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add to Selection", systemImage: "plus.circle") {
                        guard let network = manualNetwork else { return }
                        mergeNetworks([network])
                        selected.insert(network)
                        name = ""
                        bssid = ""
                    }
                    .disabled(manualNetwork == nil)
                } header: {
                    Text("Add a Network Manually")
                } footer: {
                    Text("Enter the exact network name. A BSSID identifies the access point, not your phone’s private WiFi address. Add it to distinguish access points with the same name, or leave it empty to match any access point on that network.")
                }

                Section {
                    TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
                    TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
                    Button("Choose on Map", systemImage: "map") { showingCoordinateMap = true }
                    Button("Use Latest Location", systemImage: "location") {
                        if let location = bridge.wifiZoneLocation {
                            latitude = String(format: "%.6f", location.coordinate.latitude)
                            longitude = String(format: "%.6f", location.coordinate.longitude)
                        }
                    }
                    .disabled(bridge.wifiZoneLocation == nil)
                    if hasExistingSelection {
                        Text("Saving updates the location of any selected network already assigned elsewhere.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if saveFailed {
                        Text("The networks could not be saved. Check the names, addresses and coordinates.")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Shared Location")
                } footer: {
                    Text("These coordinates apply to all \(selected.count) selected networks. They replace GPS coordinates only while connected to a matching network.")
                }
            }
            .navigationTitle(seed == nil ? "Add Zone" : "Edit Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let chosen = networks.filter { selected.contains($0) }
                        guard bridge.saveWifiNetworks(chosen, latitude: latitude, longitude: longitude) else {
                            saveFailed = true
                            return
                        }
                        onSave()
                        dismiss()
                    }
                    .disabled(selected.isEmpty || !validLocation || !name.isEmpty || !bssid.isEmpty)
                }
            }
        }
        .onAppear { loadNetworks() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { loadNetworks() } }
        .sheet(isPresented: $showingCoordinateMap) {
            WifiZoneMapPicker(coordinate: CLLocationCoordinate2D(
                latitude: Double(latitude) ?? 0, longitude: Double(longitude) ?? 0)) { coordinate in
                latitude = String(format: "%.7f", coordinate.latitude)
                longitude = String(format: "%.7f", coordinate.longitude)
            }
        }
    }

    private func loadNetworks() {
        let snapshot = bridge.wifiNetworkSnapshot()
        current = snapshot.current
        mergeNetworks(snapshot.known + (snapshot.current.map { [$0] } ?? []))
        let firstLoad = !loaded
        bridge.refreshCurrentWifiNetwork { network in
            guard let network else { return }
            let wasMissing = current == nil
            current = network
            mergeNetworks([network])
            if firstLoad, wasMissing, seed == nil, selected.isEmpty { selected.insert(network) }
        }
        guard !loaded else { return }
        loaded = true
        if let seed, let network = WifiZoneNetwork(seed) {
            mergeNetworks([network])
            selected.insert(network)
            latitude = seed["latitude"] ?? ""
            longitude = seed["longitude"] ?? ""
        } else {
            if let current { selected.insert(current) }
            if let location = snapshot.location, abs(location.timestamp.timeIntervalSinceNow) <= 60 {
                latitude = String(format: "%.6f", location.coordinate.latitude)
                longitude = String(format: "%.6f", location.coordinate.longitude)
            }
        }
    }

    private func mergeNetworks(_ incoming: [WifiZoneNetwork]) {
        networks = Array(Set(networks).union(incoming)).sorted {
            if ($0 == current) != ($1 == current) { return $0 == current }
            if $0.name != $1.name {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
            }
            return ($0.bssid ?? "") < ($1.bssid ?? "")
        }
    }
}

private struct WifiZoneMapPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    let onSelect: (CLLocationCoordinate2D) -> Void

    init(coordinate: CLLocationCoordinate2D, onSelect: @escaping (CLLocationCoordinate2D) -> Void) {
        let valid = CLLocationCoordinate2DIsValid(coordinate) ? coordinate : CLLocationCoordinate2D(latitude: 0, longitude: 0)
        _center = State(initialValue: valid)
        _position = State(initialValue: .region(MKCoordinateRegion(center: valid, latitudinalMeters: 1_000, longitudinalMeters: 1_000)))
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            Map(position: $position)
                .mapControls { MapCompass(); MapScaleView() }
                .onMapCameraChange(frequency: .onEnd) { center = $0.camera.centerCoordinate }
                .overlay {
                    Image(systemName: "mappin")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.blue)
                        .offset(y: -16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .safeAreaInset(edge: .bottom) {
                    Text(String(format: "%.7f, %.7f", center.latitude, center.longitude))
                        .font(.caption.monospacedDigit())
                        .padding(12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                }
                .navigationTitle("Zone Location")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Use Location") { onSelect(center); dismiss() }
                    }
                }
        }
    }
}
