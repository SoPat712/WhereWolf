import SwiftUI

struct EndpointView: View {
    @State private var url = ""
    @State private var token = ""
    @State private var deviceId = ""
    @State private var uniqueId = false
    @State private var saved = false
    @State private var saveFailed = false
    @State private var scanned = false
    @State private var acceptHTTP = false
    @State private var headers: [HeaderField] = []
    @State private var bridge = GLManagerBridge.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var configured: Bool { bridge.endpointSet }

    var body: some View {
        Form {
            Section {
                Picker("Save Locations To", selection: $bridge.savesToICloudDrive) {
                    Text("Server").tag(false)
                    Text("iCloud Drive").tag(true)
                }
                if bridge.savesToICloudDrive {
                    Picker("File Organization", selection: $bridge.cloudFileMode) {
                        Text("One File per Day").tag(0)
                        Text("One File per Trip").tag(1)
                    }
                    if !bridge.cloudAvailable {
                        Label("iCloud Drive is unavailable", systemImage: "icloud.slash")
                            .foregroundStyle(.orange)
                        Text("Turn on iCloud Drive for WhereWolf in iOS Settings. Unwritten data stays in the queue.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                SettingsSectionHeader(title: "Location Destination", topic: .destination)
            } footer: {
                Text(bridge.savesToICloudDrive
                     ? "Saves GeoJSON files to iCloud Drive. Your server settings below stay saved."
                     : "Sends through the upload queue to the server below.")
            }

            Section {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Status")
                        connectionStatus
                    }
                } else {
                    HStack {
                        Text("Status")
                        Spacer()
                        connectionStatus
                    }
                }
                if configured {
                    HStack {
                        Text("Endpoint")
                        Spacer()
                        Text(GLManager.shared().apiEndpointURL() ?? "")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                }
                if bridge.sending {
                    Label("Sending…", systemImage: "arrow.up.circle")
                }
                DawarichStatusRow(status: bridge.dawarich)
                sendChart
            } header: {
                SettingsSectionHeader(title: "Server", topic: .destination)
            }

            Section {
                TextField("https://server.example.com/api", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                ServerQRCodeButton(onScan: scan)
                if scanned {
                    Text("Scanned. Review the server, then tap Save.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                SettingsSectionHeader(title: "Server Endpoint", topic: .destination)
            } footer: {
                if !url.isEmpty && !validURL {
                    Text("Not a valid http(s) URL").foregroundStyle(.red)
                }
            }

            Section {
                SecureField("Access Token", text: $token)
                TextField("Device ID", text: $deviceId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Include unique_id", isOn: $uniqueId)
            } header: {
                SettingsSectionHeader(title: "Authentication", topic: .destination)
            } footer: {
                Text("OwnTracks expects a Base64-encoded username:password token.")
            }

            Section {
                ForEach($headers) { $header in
                    VStack(alignment: .leading) {
                        TextField("Header name", text: $header.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Value", text: $header.value)
                        Button("Remove Header", role: .destructive) {
                            headers.removeAll { $0.id == header.id }
                        }
                        .font(.caption)
                    }
                }
                Button("Add Header") { headers.append(HeaderField()) }
            } header: {
                SettingsSectionHeader(title: "Custom HTTP Headers", topic: .destination)
            } footer: {
                Text(headersValid ? "Sent with each request, including authentication required by a reverse proxy." : "Use unique HTTP header names and values without line breaks. Host, Content-Length, Connection, Transfer-Encoding, and Authorization are reserved.")
                    .foregroundStyle(headersValid ? Color.secondary : .red)
            }

            Section {
                Toggle("Accept Any Successful HTTP Response", isOn: $acceptHTTP)
            } footer: {
                Text("Enable for OwnTracks or servers that return an empty response. Otherwise, the server must acknowledge the upload with a JSON result of ok.")
            }

            ConnectionTestSection(enabled: validURL && headersValid) {
                saved = bridge.saveServer(url: url, token: token, deviceId: deviceId, uniqueId: uniqueId,
                                          acceptHTTP: acceptHTTP, headers: Dictionary(uniqueKeysWithValues: headers.map { ($0.name, $0.value) }))
                saveFailed = !saved
                return saved
            }

            Section {
                Button("Save") {
                    saved = bridge.saveServer(url: url, token: token, deviceId: deviceId, uniqueId: uniqueId,
                                              acceptHTTP: acceptHTTP, headers: Dictionary(uniqueKeysWithValues: headers.map { ($0.name, $0.value) }))
                    saveFailed = !saved
                }
                .disabled(!validURL || !headersValid)
                .frame(maxWidth: .infinity)
                Button("Clear Server URL", role: .destructive) {
                    saved = bridge.clearServer()
                    saveFailed = !saved
                    if saved { url = ""; token = "" }
                }
                .frame(maxWidth: .infinity)
            }
            if saveFailed { Section { Text("Couldn’t save the server credential. Unlock this iPhone and try again.").foregroundStyle(.orange) } }
            if saved {
                Section { Text("Saved").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Destination")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onChange(of: url) { _, _ in saved = false }
        .onChange(of: token) { _, _ in saved = false }
        .onChange(of: deviceId) { _, _ in saved = false }
        .onChange(of: uniqueId) { _, _ in saved = false }
        .onChange(of: acceptHTTP) { _, _ in saved = false }
        .onChange(of: headers) { _, _ in saved = false }
        .onChange(of: saved) { _, value in if value { scanned = false } }
        .onAppear {
            load()
            bridge.refresh()
            bridge.refreshDawarich()
        }
    }

    private func scan(_ text: String) -> Bool {
        guard let code = DawarichServer.parseQRCode(text, ownTracks: GLManager.shared().loggingModeCurrentValue.rawValue == 2) else { return false }
        switch code {
        case .dawarich(let endpoint):
            url = endpoint.absoluteString
            token = ""
        case .setupLink(_, let setup):
            url = setup.endpoint
            token = setup.token
            deviceId = setup.deviceId
            uniqueId = setup.uniqueId
            if !setup.headers.isEmpty {
                headers = setup.headers.sorted { $0.key < $1.key }.map { HeaderField(name: $0.key, value: $0.value) }
            }
        case .endpoint(let endpoint):
            url = endpoint.absoluteString
        }
        saved = false
        saveFailed = false
        scanned = true
        return true
    }

    private var connectionStatus: some View {
        Label(configured ? "Configured" : "Not Configured",
              systemImage: configured ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(configured ? .green : .orange)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var sendChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Sends · This Session")
                .font(.subheadline)
            if bridge.sendHistory.isEmpty {
                Text("No sends yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 2) {
                    ForEach(bridge.sendHistory) { entry in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color(for: entry.kind))
                            .frame(maxWidth: .infinity)
                            .frame(height: 18)
                            .accessibilityLabel("\(entry.date.formatted(date: .omitted, time: .standard)): \(statusLabel(entry.kind))")
                    }
                }
                HStack(spacing: 12) {
                    legend(.green, "OK")
                    legend(.orange, "Rejected")
                    legend(.red, "Network")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for kind: SendStatusEntry.Kind) -> Color {
        switch kind {
        case .success: return .green
        case .server: return .orange
        case .network: return .red
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    private var validURL: Bool {
        GLManager.isValidEndpoint(url)
    }

    private func load() {
        guard let gl = GLManager.shared() else { return }
        url = gl.apiEndpointURL() ?? ""
        token = gl.apiAccessToken() ?? ""
        deviceId = gl.deviceId() ?? ""
        uniqueId = UserDefaults.standard.bool(forKey: GLIncludeUniqueIdDefaultsName)
        acceptHTTP = UserDefaults.standard.bool(forKey: GLConsiderHTTP200SuccessDefaultsName)
        headers = (gl.customHTTPHeaders ?? [:]).sorted { $0.key < $1.key }.map { HeaderField(name: $0.key, value: $0.value) }
        saved = false
        scanned = false
    }

    private var headersValid: Bool {
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var names = Set<String>()
        for header in headers {
            let name = header.name.lowercased()
            if name.isEmpty || !header.name.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return false }
            if ["host", "content-length", "connection", "transfer-encoding", "authorization"].contains(name) { return false }
            if !names.insert(name).inserted || header.value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { return false }
        }
        return true
    }

    private func statusLabel(_ kind: SendStatusEntry.Kind) -> String {
        switch kind {
        case .success: return "Success"
        case .server: return "Server rejected the upload"
        case .network: return "Network failure"
        }
    }
}

private struct HeaderField: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var value = ""
}
