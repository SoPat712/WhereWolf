import SwiftUI

struct WatchPresetsView: View {
    let model: WatchModel

    var body: some View {
        List {
            Section {
                if model.status?.presetName == "Custom" {
                    selection("Custom", selected: true)
                        .accessibilityAddTraits(.isSelected)
                }
                ForEach(WatchStatus.presets, id: \.id) { preset in
                    let selected = model.status?.preset == preset.id
                    Button { model.send(.setPreset(preset.id)) } label: {
                        selection(preset.name, selected: selected)
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .disabled(model.busy || model.unreachable || model.status?.tripActive != false)
                }
            } footer: {
                Text("Applies on your iPhone.")
            }
        }
        .navigationTitle("Preset")
        .watchCommandProgress(model.busy)
    }

    private func selection(_ name: String, selected: Bool) -> some View {
        HStack {
            Text(name)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if selected {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.primary)
        .frame(minHeight: 44)
    }
}
