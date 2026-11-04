import SwiftUI

struct WifiPlaceNetworksView: View {
    let place: WifiPlace
    let onAdd: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var bridge = GLManagerBridge.shared
    @State private var search = ""
    @State private var selected: [String] = []
    @State private var manualNames: [String] = []

    var body: some View {
        NavigationStack {
            List {
                if canAddManualName {
                    Section {
                        Button {
                            manualNames.append(search)
                            selected.append(search)
                            search = ""
                        } label: {
                            Label("Add “\(search)”", systemImage: "plus.circle")
                        }
                        .accessibilityIdentifier("wherewolf.wifiPlaces.manualNetwork")
                    }
                }
                if let current = bridge.currentWifiSSID, matchesSearch(current) {
                    Section("Connected") {
                        networkRow(candidate(named: current), connected: true)
                    }
                }
                Section {
                    ForEach(recentNetworks) { network in
                        networkRow(network, connected: false)
                    }
                } header: {
                    Text("Recently Seen")
                } footer: {
                    Text("Each network appears once, however many access points it has. iOS reveals only the network you’re connected to, so this list grows as you use Wi-Fi.")
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search or type a network name")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Add Networks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? "Add" : "Add \(selected.count)") {
                        onAdd(selected)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("wherewolf.wifiPlaces.confirmNetworks")
                }
            }
        }
        .task { _ = await bridge.refreshWifiNetwork() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { _ = await bridge.refreshWifiNetwork() } }
        }
    }

    private var candidates: [WifiObservedNetwork] {
        var values: [String: WifiObservedNetwork] = [:]
        for network in bridge.observedWifiNetworks {
            if (values[network.name]?.lastSeen ?? .distantPast) <= (network.lastSeen ?? .distantPast) {
                values[network.name] = network
            }
        }
        let configured = bridge.wifiPlaces.flatMap(\.networks) + place.networks + manualNames
        for name in configured where values[name] == nil { values[name] = WifiObservedNetwork(name: name) }
        return values.values.sorted {
            let first = $0.lastSeen ?? .distantPast
            let second = $1.lastSeen ?? .distantPast
            if first != second { return first > second }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
    }

    private var recentNetworks: [WifiObservedNetwork] {
        candidates.filter { $0.name != bridge.currentWifiSSID && matchesSearch($0.name) }
    }

    private var canAddManualName: Bool {
        !search.isEmpty && search.utf8.count <= 32 &&
            search != bridge.currentWifiSSID && !candidates.contains { $0.name == search }
    }

    private func matchesSearch(_ name: String) -> Bool {
        search.isEmpty || name.localizedStandardContains(search)
    }

    private func candidate(named name: String) -> WifiObservedNetwork {
        candidates.first { $0.name == name } ?? WifiObservedNetwork(name: name)!
    }

    private func networkRow(_ network: WifiObservedNetwork, connected: Bool) -> some View {
        let locked = place.networks.contains(network.name)
        let checked = locked || selected.contains(network.name)
        return Button {
            if selected.contains(network.name) { selected.removeAll { $0 == network.name } }
            else { selected.append(network.name) }
        } label: {
            HStack(spacing: 12) {
                WifiPlaceIconTile(symbol: "wifi", color: connected ? .green : .gray)
                VStack(alignment: .leading, spacing: 3) {
                    Text(network.name).foregroundStyle(.primary)
                    Text(detail(network, connected: connected))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(checked && !locked ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
        }
        .disabled(locked)
        .accessibilityLabel("\(network.name), \(detail(network, connected: connected))")
        .accessibilityValue(checked ? "Selected" : "Not selected")
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private func detail(_ network: WifiObservedNetwork, connected: Bool) -> String {
        var parts = [connected ? "Connected now" : network.seenLabel]
        if place.networks.contains(network.name) { parts.append("in this place") }
        let otherPlaces = bridge.wifiPlaces.filter { $0.id != place.id && $0.networks.contains(network.name) }
        for other in otherPlaces { parts.append("also in \(other.name)") }
        return parts.joined(separator: " · ")
    }
}
