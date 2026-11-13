import SwiftUI

struct ServerQRReviewView: View {
    let review: ServerQRReview
    let onUse: () async -> Bool
    let onScanAgain: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var check = ServerQRReviewCheck()
    @State private var confirmation = ServerChangeConfirmation()
    @State private var saved = false
    @State private var previewStarted = false
    @AccessibilityFocusState private var cardFocused: Bool

    var body: some View {
        ZStack {
            if confirmation.pending != nil {
                ServerPendingQueueView(confirmation: confirmation)
                    .transition(.opacity)
            } else {
                reviewContent.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: confirmation.pending != nil)
        .onAppear {
            if review.kind == .dawarich { check.start(review) }
            cardFocused = true
        }
        .onChange(of: confirmation.pending == nil) { _, reviewing in
            cardFocused = reviewing
        }
        .task {
            guard review.previewPendingQueue != nil, !previewStarted else { return }
            previewStarted = true
            await useServer()
        }
        .onDisappear { check.cancel(); confirmation.cancel() }
    }

    private var reviewContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                card
                VStack(spacing: 12) {
                    Button {
                        Task { await useServer() }
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
                .disabled(confirmation.busy || saved)
                if confirmation.busy { ProgressView("Checking waiting points…") }
                if let error = confirmation.error {
                    Text(error)
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
    }

    private func useServer() async {
        guard !saved else { return }
        // Render fixtures must never inspect the owner's real queue or credentials.
        let current = review.previewStatus == nil ? ServerQRValues.saved
            : ServerQRValues(endpoint: "", token: "", deviceId: "", uniqueId: false, acceptHTTP: false, headers: [:])
        let result = await confirmation.request(review.values, current: current, load: {
            if review.previewStatus != nil { return review.previewPendingQueue ?? .empty }
            return await ServerPendingQueue.load()
        }, save: onUse)
        if result == true { saved = true }
    }

    private var card: some View {
        cardContent.modifier(ServerReviewCardStyle())
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
