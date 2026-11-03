import XCTest
import CoreLocation
@testable import WhereWolf

final class ConnectionTestTests: XCTestCase {
    func testSuccessfulResponsesAndStrictAcknowledgement() {
        XCTAssertEqual(ConnectionTestResult.classify(status: 200, acknowledged: true, error: nil, strict: true), .success(status: 200, acknowledged: true))
        XCTAssertEqual(ConnectionTestResult.classify(status: 204, acknowledged: false, error: nil, strict: false), .success(status: 204, acknowledged: false))
        let strict = ConnectionTestResult.classify(status: 202, acknowledged: false, error: nil, strict: true)
        XCTAssertTrue(strict.message.contains("Accept Any Successful HTTP Response"))
        XCTAssertTrue(strict.message.contains("HTTP 202"))
    }
    func testStatusFixHints() {
        for status in [401, 403] { XCTAssertTrue(classify(status).contains("token or API key")) }
        XCTAssertTrue(classify(404).contains("/api/v1/overland/batches"))
        for status in [400, 422] { XCTAssertTrue(classify(status).contains("rejected the format")) }
        for status in [500, 503, 599] { XCTAssertTrue(classify(status).contains("server error")) }
        XCTAssertTrue(classify(429).contains("HTTP 429"))
    }
    func testNetworkDNSTLSAndTimeoutHints() {
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost] {
            XCTAssertTrue(classify(code: code).contains("Check Wi-Fi or cellular"))
        }
        for code in [NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed] { XCTAssertTrue(classify(code: code).contains("DNS")) }
        for code in [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                     NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                     NSURLErrorClientCertificateRequired] { XCTAssertTrue(classify(code: code).contains("certificate chain")) }
        XCTAssertTrue(classify(code: NSURLErrorTimedOut).contains("timed out"))
    }
    func testLocationAccessFailureDoesNotLookLikeNetworkFailure() {
        let error = NSError(domain: kCLErrorDomain, code: CLError.denied.rawValue)
        let result = ConnectionTestResult.classify(status: 0, acknowledged: false, error: error, strict: false)
        XCTAssertTrue(result.message.contains("fresh location")); XCTAssertTrue(result.message.contains("Precise Location"))
        let timeout = ConnectionTestResult.classify(status: 0, acknowledged: false,
            error: NSError(domain: "WhereWolfConnectionLocationTimeout", code: 1), strict: false)
        XCTAssertTrue(timeout.message.contains("15 seconds"))
    }
    @MainActor func testFreshFixHasThirtySecondBoundaryAndRejectsFutureOrInvalidFix() {
        let now = Date(timeIntervalSince1970: 100)
        func location(_ age: Double, accuracy: Double = 5) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 45, longitude: -122), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(ConnectionTestLocation.isRecent(location(30), now: now))
        XCTAssertFalse(ConnectionTestLocation.isRecent(location(30.001), now: now))
        XCTAssertFalse(ConnectionTestLocation.isRecent(location(-1), now: now))
        XCTAssertFalse(ConnectionTestLocation.isRecent(location(0, accuracy: -1), now: now))
    }
    private func classify(_ status: Int) -> String {
        ConnectionTestResult.classify(status: status, acknowledged: false, error: nil, strict: true).message
    }
    private func classify(code: Int) -> String {
        ConnectionTestResult.classify(status: 0, acknowledged: false, error: NSError(domain: NSURLErrorDomain, code: code), strict: true).message
    }
}
