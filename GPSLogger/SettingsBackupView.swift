import SwiftUI
import UniformTypeIdentifiers

struct SettingsBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SettingsBackupView: View {
    @State private var bridge = GLManagerBridge.shared
    @State private var sync = SettingsSync.shared
    @State private var includeCredentials = true
    @State private var exporting = false
    @State private var importing = false
    @State private var document = SettingsBackupDocument(data: Data())
    @State private var preview: SettingsImport?
    @State private var error: String?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("Include Server URL and Token", isOn: $includeCredentials)
                    .accessibilityIdentifier("wherewolf.backup.includeCredentials")
                Button("Export Settings…") {
                    do {
                        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                        document = SettingsBackupDocument(data: try SettingsBackup.encode(bridge.settingsSnapshot(), credentials: includeCredentials, appVersion: version))
                        exporting = true
                    } catch { self.error = error.localizedDescription }
                }
                .accessibilityLabel("Export Settings…")
                .accessibilityIdentifier("wherewolf.backup.export")
                Button("Import Settings…") { importing = true }
                    .accessibilityLabel("Import Settings…")
                    .accessibilityIdentifier("wherewolf.backup.import")
            } header: {
                SettingsSectionHeader(title: "Settings File", topic: .backup)
            } footer: {
                Text(includeCredentials
                     ? "The JSON file contains your server credential and custom headers. Keep it private. It contains settings only; no locations, trips, queue, imports or Health data."
                     : "The JSON file omits the server URL, token and custom headers. It contains settings only; no locations, trips, queue, imports or Health data.")
            }
            Section {
                Toggle("Sync Settings with iCloud", isOn: Binding(get: { sync.enabled }, set: { sync.setEnabled($0) }))
                    .disabled(!sync.available && !sync.enabled)
                    .accessibilityIdentifier("wherewolf.backup.sync")
                Text(sync.status).font(.footnote).foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader(title: "iCloud Sync", topic: .backup)
            } footer: {
                Text("Server credentials sync through iCloud Keychain. Tracking on/off and permissions stay on each iPhone.")
            }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Backup & Sync")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: exportName) { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1_000_000 else { throw SettingsBackupError.invalid("file") }
                preview = try SettingsBackup.preview(Data(contentsOf: url), current: bridge.settingsSnapshot())
            } catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview {
                SettingsImportView(preview: preview, bridge: bridge) {
                    do {
                        try bridge.applySettings(preview.values)
                        self.preview = nil
                        message = "Imported \(preview.changes.count) changed settings. Tracking on/off was kept."
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .alert("Couldn’t Update Settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
    private var exportName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return "WhereWolf Settings " + formatter.string(from: Date())
    }

}
