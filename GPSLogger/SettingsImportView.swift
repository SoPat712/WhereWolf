import SwiftUI

struct SettingsImportView: View {
    let preview: SettingsImport
    let bridge: GLManagerBridge
    let apply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(preview.changes.count) settings will change. Tracking on/off and active-trip state are kept. No location data is imported.")
                    if preview.includesCredentials {
                        Label("This file includes server credentials. Import Settings confirms replacing the included credentials.", systemImage: "key.fill")
                    }
                    if bridge.tripInProgress { Text("Finish the current trip before importing.").foregroundStyle(.orange) }
                    if preview.newerSchema { Text("This file uses a newer schema. Only settings understood by this version will be imported.").foregroundStyle(.orange) }
                    if !preview.ignoredKeys.isEmpty { Text("Ignored \(preview.ignoredKeys.count) unknown settings.").foregroundStyle(.secondary) }
                }
                Section("Changes") {
                    ForEach(preview.changes) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(change.title)
                            Text(SettingsSchema.secrets.contains(change.id) ? "Credential will be replaced" : "\(change.before) → \(change.after)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Review Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Import Settings", action: apply).disabled(bridge.tripInProgress) }
            }
        }
    }
}
