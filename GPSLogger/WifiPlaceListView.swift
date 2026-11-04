import SwiftUI
import CoreLocation

struct WifiPlaceListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var bridge = GLManagerBridge.shared
    @State private var addingPlace = false
    @State private var addedPlace: WifiPlace?
    @State private var showingAddedPlace = false
    @State private var saveFailed = false

    var body: some View {
        List {
            if let ssid = bridge.currentWifiSSID {
                Section {
                    HStack(spacing: 12) {
                        WifiPlaceIconTile(symbol: "wifi", color: .green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Connected to \(ssid)")
                            Text(connectionDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                ForEach(bridge.wifiPlaces) { place in
                    NavigationLink {
                        WifiPlaceEditorView(place: place)
                    } label: {
                        HStack(spacing: 12) {
                            WifiPlaceIconTile(symbol: place.symbol, color: place.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(place.name)
                                    if bridge.matchedWifiPlace?.id == place.id {
                                        Text("Here")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.green)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(.green.opacity(0.16), in: Capsule())
                                    }
                                }
                                Text(place.networks.joined(separator: ", "))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let places = bridge.wifiPlaces
                    for index in offsets where places.indices.contains(index) {
                        if !bridge.removeWifiPlace(places[index]) { saveFailed = true }
                    }
                }
                Button("Add Place") { addingPlace = true }
                    .accessibilityIdentifier("wherewolf.wifiPlaces.add")
            } header: {
                Text("Places")
            } footer: {
                Text("While you’re connected to a place’s network nearby, WhereWolf records the place’s point instead of indoor GPS.")
            }

            if !bridge.frequentWifiNetworks.isEmpty {
                Section {
                    ForEach(bridge.frequentWifiNetworks) { network in
                        HStack(spacing: 12) {
                            WifiPlaceIconTile(symbol: "wifi", color: .gray)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(network.name)
                                Text(network.timeThisWeekLabel)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Add") { addFrequentNetwork(network) }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .disabled(network.coordinate == nil && bridge.wifiPlaceLocation == nil)
                                .accessibilityLabel("Add \(network.name) as a place")
                                .accessibilityHint("Uses the network’s observed location or your current location.")
                        }
                    }
                } header: {
                    Text("Frequent Networks")
                } footer: {
                    Text("Networks you’ve stayed on that aren’t part of a place yet.")
                }
            }
        }
        .settingsFormStyle()
        .navigationTitle("Wi-Fi Places")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SettingsHelpButton(topic: .automation) }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Place", systemImage: "plus") { addingPlace = true }
            }
        }
        .sheet(isPresented: $addingPlace) {
            NavigationStack { WifiPlaceEditorView() }
        }
        .navigationDestination(isPresented: $showingAddedPlace) {
            if let addedPlace { WifiPlaceEditorView(place: addedPlace) }
        }
        .alert("Couldn’t Save Place", isPresented: $saveFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your places could not be saved. Try again.")
        }
        .task { await refreshNetwork() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshNetwork() } }
        }
    }

    private var connectionDetail: String {
        guard let place = bridge.matchedWifiPlace else { return "Not part of a place" }
        if place.record == .nothing { return "Not recording while at \(place.name)" }
        let point = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let distance = bridge.lastReceivedLocation.map { WifiPlace.distanceLabel($0.distance(from: point)) } ?? "–"
        return "Recording \(place.name)’s point · \(distance) from it"
    }

    private func refreshNetwork() async {
        bridge.refresh()
        _ = await bridge.refreshWifiNetwork()
    }

    private func addFrequentNetwork(_ network: WifiObservedNetwork) {
        guard let coordinate = network.coordinate ?? bridge.wifiPlaceLocation?.coordinate else { return }
        let place = WifiPlace(name: network.name, latitude: coordinate.latitude,
                              longitude: coordinate.longitude, networks: [network.name])
        guard bridge.saveWifiPlace(place) else { saveFailed = true; return }
        addedPlace = place
        showingAddedPlace = true
    }
}
