import SwiftUI
import StoreKit

struct TipJarView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var page = Recipient.sopat712
    @State private var frequency = TipFrequency.once
    @State private var store = TipStore.shared
    @State private var amount = "5"
    @State private var customAmount = ""
    @State private var donation: TipDonation?
    @State private var allowsAaronDonations = false
    @State private var didReadStorefront = false
    @FocusState private var editingAmount: Bool

    private enum Recipient: String, CaseIterable, Identifiable {
        case sopat712 = "SoPat712"
        case aaron = "aaronpk"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                explanation
                if page == .sopat712 {
                    sopat712Tips
                } else if allowsAaronDonations {
                    aaronTips
                } else {
                    aaronProjectLink
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .id(page)
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            recipientSelector
        }
        .tint(.blue)
        .navigationTitle("Tip Jar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editingAmount = false }
            }
        }
        .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onChange(of: page) { _, _ in editingAmount = false }
        .task {
            if !didReadStorefront {
                didReadStorefront = true
                let countryCode = await Storefront.current?.countryCode
                allowsAaronDonations = TipDonation.allowsExternalPayments(countryCode: countryCode)
            }
            await store.load()
        }
        .sheet(item: $donation) { donation in
            TipDonationSheet(donation: donation)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert(item: $store.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private var recipientSelector: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 4) {
                    ForEach(Recipient.allCases) { recipient in
                        Button { page = recipient } label: {
                            Text(recipient.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .padding(.vertical, 8)
                                .background {
                                    if page == recipient {
                                        Capsule().fill(Color.primary.opacity(0.1))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(page == recipient ? .blue : .primary)
                        .accessibilityAddTraits(page == recipient ? .isSelected : [])
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Tip recipient")
            } else {
                Picker("Tip recipient", selection: $page) {
                    ForEach(Recipient.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(8)
        .glassCapsule()
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var header: some View {
        DrawerHeader(title: page.rawValue,
                     subtitle: page == .sopat712 ? "Creator of this fork" : "Original creator of Overland") {
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: page == .sopat712 ? "heart.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(14)
                    .glassCapsule()
                    .accessibilityHidden(true)
            }
        }
    }

    private var explanation: some View {
        Text(explanationText)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .drawerCard()
    }

    private var explanationText: String {
        if page == .sopat712 {
            return "I built this fork of Overland and keep improving it. If it's useful to you, a tip helps me keep working on it."
        }
        if allowsAaronDonations {
            return "Aaron created Overland and released it as open source. This fork is built on his work, so his tip links stay here. Tips go straight to him."
        }
        return "Aaron created Overland and released it as open source. This fork is built on his work."
    }

    private var aaronProjectLink: some View {
        Link(destination: TipDonation.overlandGitHubURL) {
            Text("View Overland on GitHub")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .glassButtonStyle()
        .padding(.horizontal, 16)
    }

    private var sopat712Tips: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Leave a tip", systemImage: "gift")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if dynamicTypeSize.isAccessibilitySize {
                    Picker("Tip frequency", selection: $frequency) {
                        ForEach(TipFrequency.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .glassButtonStyle()
                } else {
                    Picker("Tip frequency", selection: $frequency) {
                        ForEach(TipFrequency.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Text(frequency.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(frequency.names, id: \.self) { name in
                    tipButton(name)
                }
                if store.loading {
                    ProgressView("Loading tips…")
                        .frame(maxWidth: .infinity)
                } else if let message = store.loadMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { Task { await store.load() } }
                        .glassButtonStyle()
                }
            }
            .drawerCard()

            VStack(alignment: .leading, spacing: 12) {
                Button {
                    Task { await store.restore() }
                } label: {
                    Label("Restore Purchases", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .glassButtonStyle()
                .disabled(store.busy)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { legalLinks }
                    VStack(alignment: .leading, spacing: 12) { legalLinks }
                }
                .font(.footnote)
            }
            .padding(.horizontal, 20)
        }
    }

    private func tipButton(_ name: String) -> some View {
        let product = store.products[frequency.productID(name)]
        return Button {
            guard let product else { return }
            Task { await store.purchase(product) }
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.headline)
                    Text(product?.displayPrice ?? "Unavailable").font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } else {
                HStack {
                    Text(name).font(.body.weight(.medium))
                    Spacer(minLength: 12)
                    Text(product?.displayPrice ?? "—").font(.headline.monospacedDigit())
                }
                .padding(.vertical, 6)
            }
        }
        .glassButtonStyle()
        .disabled(product == nil || store.busy)
        .accessibilityLabel("\(name), \(product?.displayPrice ?? "Unavailable"), \(frequency.rawValue)")
    }

    private var legalLinks: some View {
        Group {
            Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            Link("Privacy Policy", destination: URL(string: "https://sopat712.github.io/Where/privacy/")!)
        }
    }

    private var selectedDonation: TipDonation? {
        TipDonation(amount == "Custom" ? customAmount : amount)
    }

    private var aaronTips: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Choose an amount", systemImage: "gift")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()),
                                         count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                    ForEach(["5", "10", "25", "Custom"], id: \.self) { choice in
                        Button {
                            amount = choice
                            editingAmount = choice == "Custom"
                        } label: {
                            Text(choice == "Custom" ? choice : "$\(choice)")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .glassButtonStyle(prominent: amount == choice, tint: amount == choice ? .blue : nil)
                        .accessibilityAddTraits(amount == choice ? .isSelected : [])
                    }
                }
                if amount == "Custom" {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom amount (USD)").font(.subheadline.weight(.medium))
                        TextField("Amount", text: $customAmount)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .focused($editingAmount)
                            .accessibilityLabel("Custom amount in US dollars")
                        Text("Enter an amount greater than zero, with up to two decimal places.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("One-time tip · USD")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .drawerCard()

            Button {
                editingAmount = false
                donation = selectedDonation
            } label: {
                Text(selectedDonation.map { "Donate $\($0.amount)" } ?? "Donate")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .glassButtonStyle(prominent: true, tint: .blue)
            .disabled(selectedDonation == nil)
            .padding(.horizontal, 16)
        }
    }
}

private struct TipDonationSheet: View {
    let donation: TipDonation
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    DrawerHeader(title: "Donate $\(donation.amount)", subtitle: "A tip for aaronpk") { EmptyView() }
                    VStack(spacing: 12) {
                        ForEach(TipDonation.Service.allCases) { service in
                            Button {
                                let url = donation.url(for: service)
                                openURL(url)
                            } label: {
                                HStack {
                                    Text(service.rawValue)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                }
                                .font(.headline)
                                .padding(.vertical, 8)
                            }
                            .glassButtonStyle()
                        }
                    }
                    .drawerCard()
                }
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .tint(.blue)
    }
}
