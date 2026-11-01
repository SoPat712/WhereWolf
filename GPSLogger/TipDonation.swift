import Foundation

struct TipDonation: Identifiable {
    static let overlandGitHubURL = URL(string: "https://github.com/aaronpk/Overland-iOS")!

    static func allowsExternalPayments(countryCode: String?) -> Bool {
        countryCode == "USA"
    }

    let amount: String
    var id: String { amount }

    init?(_ input: String, locale: Locale = .current) {
        let separator = locale.decimalSeparator ?? "."
        let text = input.replacingOccurrences(of: separator, with: ".")
        guard text.range(of: #"\A[0-9]+(?:\.[0-9]{1,2})?\z"#, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: ".")
        let digits = parts[0].drop(while: { $0 == "0" })
        let whole = digits.isEmpty ? "0" : String(digits)
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        while fraction.last == "0" { fraction.removeLast() }
        guard whole != "0" || !fraction.isEmpty else { return nil }
        amount = fraction.isEmpty ? whole : "\(whole).\(fraction)"
    }

    enum Service: String, CaseIterable, Identifiable {
        case cashApp = "Cash App"
        case payPal = "PayPal"
        case venmo = "Venmo"

        var id: String { rawValue }
    }

    func url(for service: Service) -> URL {
        switch service {
        case .cashApp: return URL(string: "https://cash.me/$aaronpk/\(amount)")!
        case .payPal: return URL(string: "https://paypal.me/apk/\(amount)")!
        case .venmo:
            return URL(string: "https://venmo.com/?txn=pay&audience=public&recipients=aaronpk&note=Tip%20Jar&amount=\(amount)")!
        }
    }
}
