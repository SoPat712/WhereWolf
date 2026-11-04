import SwiftUI

struct WifiPlaceIconView: View {
    let name: String
    let onDone: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var symbol: String
    @State private var color: String

    init(name: String, symbol: String, color: String, onDone: @escaping (String, String) -> Void) {
        self.name = name
        self.onDone = onDone
        _symbol = State(initialValue: symbol)
        _color = State(initialValue: color)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        WifiPlaceIconTile(symbol: symbol, color: WifiPlace.tint(for: color), size: 88)
                        Text(name.isEmpty ? "Place" : name).font(.title2.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }

                Section {
                    HStack(spacing: 0) {
                        ForEach(WifiPlace.colors, id: \.self) { choice in
                            Button { color = choice } label: {
                                Circle()
                                    .fill(WifiPlace.tint(for: choice))
                                    .frame(width: 28, height: 28)
                                    .padding(4)
                                    .overlay {
                                        if choice == color { Circle().stroke(.primary, lineWidth: 2) }
                                    }
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.capitalized)
                            .accessibilityAddTraits(choice == color ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 12) {
                        ForEach(WifiPlace.symbols) { choice in
                            Button { symbol = choice.id } label: {
                                Image(systemName: choice.id)
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(choice.id == symbol ? Color.white : Color.primary)
                                    .frame(width: 44, height: 44)
                                    .background(choice.id == symbol ? WifiPlace.tint(for: color) : Color(uiColor: .tertiarySystemFill), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.label)
                            .accessibilityAddTraits(choice.id == symbol ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                } footer: {
                    Text("WhereWolf picks one from the name when you create a place: Home, Work, School, Gym, Café and so on. Change it any time.")
                }
            }
            .navigationTitle("Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone(symbol, color); dismiss() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("wherewolf.wifiPlaces.confirmIcon")
                }
            }
        }
    }
}
