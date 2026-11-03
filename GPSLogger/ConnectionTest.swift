import Foundation
import CoreLocation
import SwiftUI

enum ConnectionTestResult: Equatable {
    case success(status: Int, acknowledged: Bool)
    case failure(String, String)

    var message: String {
        switch self {
        case .success(let status, let acknowledged):
            return "HTTP \(status) · \(acknowledged ? "Acknowledged with result: ok." : "No result: ok acknowledgement.")"
        case .failure(let message, let hint): return "\(message) \(hint)"
        }
    }
    static func classify(status: Int, acknowledged: Bool, error: NSError?, strict: Bool) -> Self {
        if let error {
            if error.domain == "WhereWolfConnectionLocationTimeout" {
                return .failure("A fresh location did not arrive within 15 seconds.", "Check location access and Precise Location in iOS Settings, then try outdoors.")
            }
            if error.domain == kCLErrorDomain {
                return .failure("Couldn’t get a fresh location.", "Allow location access and Precise Location in iOS Settings, then try outdoors.")
            }
            if error.domain == NSURLErrorDomain {
                switch error.code {
                case NSURLErrorTimedOut: return .failure("The connection timed out.", "Check the network and server, then try again.")
                case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                     NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
                     NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
                    return .failure("TLS or certificate error.", "Use HTTPS with a valid certificate matching the hostname and a complete certificate chain.")
                case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                    return .failure("The server name could not be found.", "Check the hostname, DNS and network connection.")
                case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost, NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed:
                    return .failure("No connection to the server.", "Check Wi-Fi or cellular access and whether the server is reachable.")
                case NSURLErrorBadURL: return .failure("The server URL is invalid.", "Save a complete HTTP or HTTPS endpoint.")
                case NSURLErrorCancelled: return .failure("Connection test cancelled.", "Try again when ready.")
                default: break
                }
            }
            return .failure("The request failed.", "Check the network and server configuration, then try again.")
        }
        switch status {
        case 200..<300:
            if strict && !acknowledged {
                return .failure("HTTP \(status), without result: ok.", "The uploader requires that acknowledgement. If your server uses another response, enable Accept Any Successful HTTP Response in Settings → Server.")
            }
            return .success(status: status, acknowledged: acknowledged)
        case 401, 403: return .failure("HTTP \(status): access denied.", "Check the token or API key and custom authentication headers.")
        case 404: return .failure("HTTP 404: endpoint not found.", "Check the URL path; for example, Dawarich uses /api/v1/overland/batches.")
        case 400, 422: return .failure("HTTP \(status): the server rejected the format.", "Choose the server’s expected GeoJSON or OwnTracks format and check its API documentation.")
        case 500..<600: return .failure("HTTP \(status): server error.", "Check the server logs or try again later.")
        default: return .failure("HTTP \(status): unexpected response.", "Check the endpoint and server configuration.")
        }
    }
}

@MainActor final class ConnectionTestLocation: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeout: DispatchWorkItem?

    static func isRecent(_ location: CLLocation, now: Date) -> Bool {
        let age = now.timeIntervalSince(location.timestamp)
        return age >= 0 && age <= 30 && location.horizontalAccuracy >= 0 && location.horizontalAccuracy.isFinite
            && CLLocationCoordinate2DIsValid(location.coordinate)
    }
    func freshLocation(recent: CLLocation?) async throws -> CLLocation {
        if let recent, Self.isRecent(recent, now: Date()) { return recent }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let manager = CLLocationManager()
            self.manager = manager
            guard [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) else {
                finish(.failure(NSError(domain: kCLErrorDomain, code: CLError.denied.rawValue))); return
            }
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyBest
            let work = DispatchWorkItem { [weak self] in
                self?.finish(.failure(NSError(domain: "WhereWolfConnectionLocationTimeout", code: 1)))
            }
            timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
            manager.requestLocation()
        }
    }
    private func finish(_ result: Result<CLLocation, Error>) {
        timeout?.cancel(); timeout = nil
        manager?.delegate = nil; manager = nil
        let continuation = continuation; self.continuation = nil
        continuation?.resume(with: result)
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: { Self.isRecent($0, now: Date()) }) else { return }
        finish(.success(location))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(.failure(error)) }
}

@MainActor @Observable final class ConnectionTestModel {
    private(set) var busy = false
    private(set) var result: ConnectionTestResult?
    private var locationSource = ConnectionTestLocation()
    private var request: URLSessionDataTask?

    func run() async {
        guard !busy else { return }
        busy = true; result = nil
        defer { busy = false; request = nil }
        let gl = GLManager.shared()!
        do {
            let location = try await locationSource.freshLocation(recent: gl.lastReceivedLocation ?? gl.locationManager.location)
            let strict = !UserDefaults.standard.bool(forKey: GLConsiderHTTP200SuccessDefaultsName) && gl.loggingModeCurrentValue.rawValue != 2
            let response: (Int, Bool, NSError?) = await withCheckedContinuation { continuation in
                var finished = false
                var timeout: DispatchWorkItem?
                request = gl.testConnection(at: location) { status, acknowledged, error in
                    guard !finished else { return }
                    finished = true; timeout?.cancel()
                    continuation.resume(returning: (status, acknowledged, error as NSError?))
                }
                let work = DispatchWorkItem { [weak self] in
                    guard !finished else { return }
                    finished = true; self?.request?.cancel()
                    continuation.resume(returning: (0, false, NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
                }
                timeout = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
            }
            result = .classify(status: response.0, acknowledged: response.1, error: response.2, strict: strict)
        } catch { result = .classify(status: 0, acknowledged: false, error: error as NSError, strict: false) }
    }
}
