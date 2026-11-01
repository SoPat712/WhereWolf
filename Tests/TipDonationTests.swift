import XCTest
@testable import Overland

final class TipDonationTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    func testExternalPaymentsAreAllowedForUSA() {
        XCTAssertTrue(TipDonation.allowsExternalPayments(countryCode: "USA"))
    }

    func testExternalPaymentsAreNotAllowedForOtherCountryCodes() {
        for code in ["CAN", "GBR", "FRA", "JPN", "US", "usa", "", " USA", "USA "] {
            XCTAssertFalse(TipDonation.allowsExternalPayments(countryCode: code), code)
        }
    }

    func testExternalPaymentsAreNotAllowedWithoutAStorefront() {
        XCTAssertFalse(TipDonation.allowsExternalPayments(countryCode: nil))
    }

    func testAmountsArePositiveAndHaveAtMostTwoDecimalPlaces() {
        for input in ["", "0", "0.00", "-5", "+5", "1.234", "1.", ".5", "1e2", "NaN", " 5", "5\n", "1/2", "5&amount=9"] {
            XCTAssertNil(TipDonation(input, locale: locale), input)
        }
        for (input, expected) in [("5", "5"), ("10.00", "10"), ("0012.50", "12.5"), ("0.01", "0.01"), ("25.99", "25.99")] {
            XCTAssertEqual(TipDonation(input, locale: locale)?.amount, expected)
        }
        XCTAssertEqual(TipDonation("12,50", locale: Locale(identifier: "fr_FR"))?.amount, "12.5")
        let large = String(repeating: "9", count: 40) + ".99"
        XCTAssertEqual(TipDonation(large, locale: locale)?.amount, large)
    }

    func testPaymentURLsUseTheExactAmountAndRecipient() throws {
        for amount in ["5", "10", "25", "12.50", "0.01"] {
            let donation = try XCTUnwrap(TipDonation(amount, locale: locale))
            XCTAssertEqual(donation.url(for: .cashApp).absoluteString, "https://cash.me/$aaronpk/\(donation.amount)")
            XCTAssertEqual(donation.url(for: .payPal).absoluteString, "https://paypal.me/apk/\(donation.amount)")
            XCTAssertEqual(donation.url(for: .venmo).absoluteString, "https://venmo.com/?txn=pay&audience=public&recipients=aaronpk&note=Tip%20Jar&amount=\(donation.amount)")
        }
    }

    func testLegacyProductIDsArePreserved() {
        XCTAssertEqual(TipFrequency.once.names.map { TipFrequency.once.productID($0) }, [
            "app.p3k.overland.Wanderer", "app.p3k.overland.Trailblazer", "app.p3k.overland.Explorer",
            "app.p3k.overland.Adventurer", "app.p3k.overland.Cosmonaut"
        ])
        for frequency in [TipFrequency.monthly, .yearly] {
            XCTAssertEqual(frequency.names.map { frequency.productID($0) }, [
                "app.p3k.overland.\(frequency.rawValue).Commuter", "app.p3k.overland.\(frequency.rawValue).Mariner",
                "app.p3k.overland.\(frequency.rawValue).Aviator", "app.p3k.overland.\(frequency.rawValue).Globetrotter"
            ])
        }
    }
}
