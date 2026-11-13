import SwiftUI

struct ServerReviewCardStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // Glass on the glass sheet frosts to white; match the guide's tertiary-fill groups.
            content.background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 22))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

struct ServerPendingQueueView: View {
    @Bindable var confirmation: ServerChangeConfirmation
    @AccessibilityFocusState private var cardFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let pending = confirmation.pending {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("On This iPhone", systemImage: "iphone")
                            .font(.headline).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pending.countText()).font(.title2.bold())
                            if let imported = pending.importedText() { Text(imported).font(.headline) }
                            Text(pending.rangeText()).foregroundStyle(.secondary)
                        }
                        Divider()
                        Text("They’ll be sent to \(confirmation.host) after you continue.")
                        if pending.importedCount > 0 {
                            Text("Imported workout points are sent as GeoJSON.").foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(22)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(ServerReviewCardStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityFocused($cardFocused)
                    .accessibilityIdentifier("wherewolf.server.pendingPoints")
                }
                VStack(spacing: 12) {
                    Button { Task { await confirmation.confirm() } } label: {
                        Text("Use This Server").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .glassButtonStyle(prominent: true, tint: .blue)
                    .accessibilityIdentifier("wherewolf.server.pendingPoints.use")
                    Button(action: confirmation.back) {
                        Text("Back").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .glassButtonStyle()
                    .accessibilityIdentifier("wherewolf.server.pendingPoints.back")
                }
                .buttonBorderShape(.capsule)
                .disabled(confirmation.busy)
                if let error = confirmation.error { Text(error).foregroundStyle(.orange) }
            }
            .frame(maxWidth: 580)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background { if #unavailable(iOS 26) { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() } }
        .onAppear { cardFocused = true }
    }
}

struct ServerPendingQueuePresentation: ViewModifier {
    @Bindable var confirmation: ServerChangeConfirmation

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { confirmation.pending != nil }, set: { if !$0 { confirmation.back() } })) {
                NavigationStack {
                    ServerPendingQueueView(confirmation: confirmation)
                        .navigationTitle("Use This Server")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .tint(.blue)
                .presentationDetents([.fraction(0.7), .large])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(confirmation.busy)
            }
            .alert("Server Not Saved", isPresented: Binding(
                get: { confirmation.pending == nil && confirmation.error != nil },
                set: { if !$0 { confirmation.clearError() } })) {
                    Button("OK") { confirmation.clearError() }
                } message: { Text(confirmation.error ?? "") }
            .onDisappear { confirmation.cancel() }
    }
}
