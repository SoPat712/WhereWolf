import StoreKit
import Observation

enum TipFrequency: String, CaseIterable, Identifiable {
    case once = "Once"
    case monthly = "Monthly"
    case yearly = "Yearly"

    var id: String { rawValue }

    var names: [String] {
        switch self {
        case .once: return ["Wanderer", "Trailblazer", "Explorer", "Adventurer", "Cosmonaut"]
        case .monthly, .yearly: return ["Commuter", "Mariner", "Aviator", "Globetrotter"]
        }
    }

    func productID(_ name: String) -> String {
        "me.joshpatra.where.\(self == .once ? "" : rawValue + ".")\(name)"
    }

    var detail: String {
        switch self {
        case .once: return "A one-time thank-you."
        case .monthly: return "Renews monthly. Cancel anytime in App Store settings."
        case .yearly: return "Renews yearly. Cancel anytime in App Store settings."
        }
    }
}

@MainActor @Observable
final class TipStore {
    static let shared = TipStore()
    private(set) var products: [String: Product] = [:]
    private(set) var loading = false
    private(set) var busy = false
    private(set) var loadMessage: String?
    var notice: Notice?
    @ObservationIgnored private var updates: Task<Void, Never>?

    struct Notice: Identifiable {
        let title: String
        let message: String
        var id: String { title }
    }

    private init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await complete(result)
            }
        }
    }

    func load() async {
        guard !loading else { return }
        guard AppStore.canMakePayments else {
            loadMessage = "In-app purchases are not allowed on this device."
            return
        }
        loading = true
        loadMessage = nil
        defer { loading = false }
        do {
            let ids = TipFrequency.allCases.flatMap { frequency in
                frequency.names.map { frequency.productID($0) }
            }
            let available = try await Product.products(for: ids)
            products = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
            if available.count < ids.count {
                loadMessage = "Some tips are unavailable in the App Store right now. Please try again later."
            }
            for await result in Transaction.unfinished {
                await complete(result)
            }
        } catch {
            loadMessage = "Couldn’t load tips from the App Store. Please try again."
        }
    }

    func purchase(_ product: Product) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result): await complete(result)
            case .pending:
                notice = Notice(title: "Tip Pending", message: "Your tip is waiting for approval. Thank you for your support!")
            case .userCancelled: break
            @unknown default: break
            }
        } catch {
            notice = Notice(title: "Purchase Unavailable", message: error.localizedDescription)
        }
    }

    func restore() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
            notice = Notice(title: "Purchases Restored", message: "Your purchases have been restored")
        } catch {
            notice = Notice(title: "Couldn’t Restore Purchases", message: error.localizedDescription)
        }
    }

    private func complete(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            notice = Notice(title: "Couldn’t Verify Purchase", message: "Please try restoring your purchases.")
            return
        }
        guard TipFrequency.allCases.contains(where: { frequency in
            frequency.names.contains(where: { frequency.productID($0) == transaction.productID })
        }) else { return }
        await transaction.finish()
        if transaction.revocationDate == nil {
            notice = Notice(title: "Thank You!", message: "Your support helps keep Where moving.")
        }
    }
}
