//
//  TripModesView.swift
//  WhereWolf
//
//  SwiftUI editor for the trip-mode catalog. GLManagerBridge remains the write boundary so a
//  successful save updates GLManager and the shared snapshot together.
//

import SwiftUI
import WidgetKit

// MARK: - Persistence

extension TripModeStore {
    private static func normalized(_ modes: [TripMode]) -> [TripMode]? {
        guard !modes.isEmpty else { return nil }

        var ids = Set<String>()
        var result: [TripMode] = []
        result.reserveCapacity(modes.count)

        for mode in modes {
            let id = mode.id
            guard !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines), ids.insert(id).inserted else {
                return nil
            }

            let name = mode.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let symbol = mode.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !symbol.isEmpty else { return nil }

            let serverValue: String?
            if let value = mode.serverValue {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                serverValue = trimmed == id ? nil : trimmed
            } else {
                serverValue = nil
            }

            let healthWorkout: String?
            if let value = mode.healthWorkout {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, HealthWorkout.forKey(trimmed) != nil else { return nil }
                healthWorkout = trimmed
            } else {
                healthWorkout = nil
            }

            var synonyms: [String] = []
            for synonym in mode.synonyms {
                let trimmed = synonym.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if !synonyms.contains(trimmed) { synonyms.append(trimmed) }
            }

            result.append(TripMode(id: id, name: name, symbol: symbol, closeZoom: mode.closeZoom,
                                  synonyms: synonyms, healthWorkout: healthWorkout,
                                  serverValue: serverValue))
        }
        return result
    }

    // Returns false without changing preferences when any mode is invalid.
    @discardableResult
    static func save(_ modes: [TripMode]) -> Bool {
        guard let modes = normalized(modes),
              let data = try? JSONEncoder().encode(modes),
              let defaults = persistenceDefaults() else { return false }

        defaults.set(data, forKey: modesKey)
        defaults.set(TripMode.defaults.map(\.id), forKey: builtInIDsKey)
        NotificationCenter.default.post(name: Notification.Name(GLSettingsChangedNotification), object: nil)
        WhereWolfShortcuts.updateAppShortcutParameters()
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadAllControls()
        }
        return true
    }

    // Restores built-ins to their current definitions while keeping custom modes after them.
    @discardableResult
    static func restoreDefaults() -> Bool {
        let builtInIDs = Set(TripMode.defaults.map(\.id))
        let custom = modes.filter { !builtInIDs.contains($0.id) }
        return save(TripMode.defaults + custom)
    }

    // Makes a stable ID such as "kayak" or "e-scooter-2" from an editable name.
    static func newID(forName name: String) -> String {
        let words = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let base = words.isEmpty ? "mode" : words.joined(separator: "-")
        var id = base
        var number = 2
        while contains(id) {
            id = "\(base)-\(number)"
            number += 1
        }
        return id
    }
}

// MARK: - Catalog

struct TripModesView: View {
    private struct Editor: Identifiable {
        let id = UUID()
        let mode: TripMode?
    }

    @State private var bridge = GLManagerBridge.shared
    @State private var editor: Editor?
    @State private var restoreRequested = false
    @State private var saveFailed = false

    var body: some View {
        Form {
            Section {
                if bridge.tripModes.isEmpty {
                    Text("Add at least one trip mode.")
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(bridge.tripModes.enumerated()), id: \.element.id) { item in
                    let mode = item.element
                    Button {
                        editor = Editor(mode: mode)
                    } label: {
                        HStack(spacing: 12) {
                            TripModeIcon(symbol: mode.symbol)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.name)
                                    .foregroundStyle(.primary)
                                if let workout = HealthWorkout.forKey(mode.healthWorkout) {
                                    Text(workout.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: delete)
                .onMove(perform: move)
            } header: {
                Text("Trip Modes")
            } footer: {
                Text("Modes appear in this order in the trip picker. Names and icons are local; the server value stays stable unless you set one.")
            }
            .listRowBackground(Color.settingsRow)

            Section {
                Button("Restore Default Modes", systemImage: "arrow.counterclockwise") {
                    restoreRequested = true
                }
            } footer: {
                Text("Restoring brings back deleted built-ins and resets their names, icons and settings. Your custom modes stay at the end.")
            }
            .listRowBackground(Color.settingsRow)
        }
        .settingsFormStyle()
        .navigationTitle("Trip Modes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editor = Editor(mode: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Trip Mode")
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .sheet(item: $editor) { item in
            TripModeEditor(mode: item.mode) { candidate in
                save(candidate, replacing: item.mode)
            }
        }
        .confirmationDialog("Restore Default Modes?", isPresented: $restoreRequested) {
            Button("Restore", role: .destructive) { restore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleted built-ins come back, while your custom modes are kept.")
        }
        .alert("Trip Mode Not Saved", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check that the name, icon, server value and Apple Health workout are valid.")
        }
        .onAppear { bridge.refreshTripModes() }
    }

    private func delete(_ offsets: IndexSet) {
        guard bridge.tripModes.count - offsets.count > 0 else { return }
        var modes = bridge.tripModes
        modes.remove(atOffsets: offsets)
        if !bridge.saveTripModes(modes) { saveFailed = true }
    }

    private func move(_ offsets: IndexSet, _ destination: Int) {
        var modes = bridge.tripModes
        modes.move(fromOffsets: offsets, toOffset: destination)
        if !bridge.saveTripModes(modes) { saveFailed = true }
    }

    private func save(_ candidate: TripMode, replacing original: TripMode?) -> Bool {
        var modes = bridge.tripModes
        if let original, let index = modes.firstIndex(where: { $0.id == original.id }) {
            modes[index] = candidate
        } else {
            modes.append(candidate)
        }
        let saved = bridge.saveTripModes(modes)
        if !saved { saveFailed = true }
        return saved
    }

    private func restore() {
        if !bridge.restoreTripModes() { saveFailed = true }
    }
}

private struct TripModeIcon: View {
    let symbol: String

    var body: some View {
        Group {
            if let image = TripModeStore.image(symbol: symbol) {
                // Custom symbol sets otherwise draw in their original black.
                Image(uiImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "questionmark.square")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 28, height: 28)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }
}

// MARK: - Editor

private struct TripModeEditor: View {
    let original: TripMode?
    let onSave: (TripMode) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: String
    @State private var synonymsText: String
    @State private var healthWorkout: String?
    @State private var closeZoom: Bool
    @State private var serverValue: String
    @State private var saveFailed = false

    init(mode: TripMode?, onSave: @escaping (TripMode) -> Bool) {
        original = mode
        self.onSave = onSave
        _name = State(initialValue: mode?.name ?? "")
        _symbol = State(initialValue: TripModeStore.resolvedSymbol(mode?.symbol ?? "wherewolf.walk"))
        _synonymsText = State(initialValue: mode?.synonyms.joined(separator: ", ") ?? "")
        _healthWorkout = State(initialValue: mode?.healthWorkout)
        _closeZoom = State(initialValue: mode?.closeZoom ?? true)
        _serverValue = State(initialValue: mode?.serverValue ?? "")
    }

    private var modeID: String {
        original?.id ?? TripModeStore.newID(forName: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } header: {
                    Text("Name")
                } footer: {
                    Text("The name shown in the trip picker.")
                }

                Section {
                    TripModeIcon(symbol: symbol)
                        .frame(maxWidth: .infinity, minHeight: 42)

                    Picker("App Icon", selection: $symbol) {
                        if !TripModeStore.customSymbols.contains(symbol) {
                            Text(symbol).tag(symbol)
                        }
                        ForEach(TripModeStore.customSymbols, id: \.self) { value in
                            Text(value.replacingOccurrences(of: "wherewolf.", with: "").capitalized)
                                .tag(value)
                        }
                    }

                    TextField("SF Symbol name", text: $symbol)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Icon")
                } footer: {
                    Text("Choose a WhereWolf icon or enter an SF Symbol name. App-owned icons can be included in trip records; SF Symbols are sent by name for Apple platforms.")
                }

                Section {
                    TextField("Synonyms", text: $synonymsText, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Synonyms")
                } footer: {
                    Text("Separate alternate names with commas. Siri and Shortcuts use these names.")
                }

                Section {
                    Picker("Workout", selection: $healthWorkout) {
                        Text("None").tag(nil as String?)
                        ForEach(HealthWorkout.all, id: \.key) { workout in
                            Text(workout.name).tag(Optional(workout.key))
                        }
                    }
                    Toggle("Closer map zoom", isOn: $closeZoom)
                } header: {
                    Text("Trip Behavior")
                } footer: {
                    Text("A selected workout lets WhereWolf save this mode's trips to Apple Health. Closer zoom is useful for slower travel.")
                }

                Section {
                    TextField("Default: \(modeID)", text: $serverValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Server Value")
                } footer: {
                    Text("Sent as trip_mode and as the trip's mode. Leave it empty to send \(modeID). Renaming the mode does not change this value.")
                }

                if saveFailed {
                    Section {
                        Text("This mode could not be saved. Check each field and try again.")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(original == nil ? "New Trip Mode" : "Edit Trip Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        let name = trimmedName
        let symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !symbol.isEmpty else { return }

        let server = serverValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedServerValue = server.isEmpty || server == modeID ? nil : server
        let synonyms = synonymsText
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let candidate = TripMode(id: modeID, name: name, symbol: symbol, closeZoom: closeZoom,
                                 synonyms: synonyms, healthWorkout: healthWorkout,
                                 serverValue: normalizedServerValue)
        guard onSave(candidate) else {
            saveFailed = true
            return
        }
        dismiss()
    }
}
