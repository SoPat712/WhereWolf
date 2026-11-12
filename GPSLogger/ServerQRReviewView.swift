import SwiftUI

struct ServerQRReviewView: View {
    let review: ServerQRReview
    let onUse: () async -> Bool
    let onScanAgain: () -> Void

    @State private var check = ServerQRReviewCheck()
    @State private var saving = false
    @State private var saveFailed = false
    @AccessibilityFocusState private var cardFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                card
                VStack(spacing: 12) {
                    Button {
                        guard !saving else { return }
                        saving = true
                        Task { @MainActor in
                            saveFailed = !(await onUse())
                            saving = false
                        }
                    } label: {
                        Text("Use This Server")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .glassButtonStyle(prominent: true, tint: .blue)
                    .accessibilityIdentifier("wherewolf.scanQRCode.use")
                    Button(action: onScanAgain) {
                        Text("Scan Again").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .glassButtonStyle()
                    .accessibilityIdentifier("wherewolf.scanQRCode.again")
                }
                .buttonBorderShape(.capsule)
                .disabled(saving)
                if saveFailed {
                    Text("Couldn’t save the server credential. Unlock this iPhone and try again.")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("wherewolf.scanQRCode.saveError")
                }
            }
            .frame(maxWidth: 580)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background { if #unavailable(iOS 26) { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() } }
        .onAppear {
            if review.kind == .dawarich { check.start(review) }
            cardFocused = true
        }
        .onDisappear { check.cancel() }
    }

    @ViewBuilder private var card: some View {
        if #available(iOS 26, *) {
            // On the glass sheet the card is a tertiary-fill group, as in the setup guide: glass on glass frosts to white.
            cardContent.background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 22))
        } else {
            cardContent.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Code found", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 6) {
                Text(review.kind.rawValue).font(.title2.bold())
                Text(verbatim: review.serverDisplay)
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Format: \(review.format)")
            if review.includesKey {
                Label("API key included", systemImage: "key.fill")
            }
            if review.kind == .dawarich {
                verification
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityFocused($cardFocused)
        .accessibilityIdentifier("wherewolf.scanQRCode.review")
    }

    @ViewBuilder private var verification: some View {
        switch check.status {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking server…")
            }
            .foregroundStyle(.secondary)
        case .dawarich(let version, let account):
            VStack(alignment: .leading, spacing: 8) {
                Label("Dawarich" + (version.map { " " + $0 } ?? ""), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let account {
                    Text(verbatim: account)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)
                }
            }
        case .keyRejected:
            Label("The server didn't accept this key", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unreachable:
            Label("Couldn't reach the server", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.secondary)
        }
    }
}
