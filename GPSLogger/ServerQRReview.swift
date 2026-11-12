import Foundation
import Observation

struct ServerQRValues: Equatable {
    var endpoint: String
    var token: String
    var deviceId: String
    var uniqueId: Bool
    var acceptHTTP: Bool
    var headers: [String: String]

    // Manual Save and QR confirmation use the same bridge call and validation.
    func save(using bridge: GLManagerBridge) -> Bool {
        bridge.saveServer(url: endpoint, token: token, deviceId: deviceId, uniqueId: uniqueId,
                          acceptHTTP: acceptHTTP, headers: headers)
    }
}

struct ServerQRReview: Identifiable {
    enum Kind: String {
        case dawarich = "Dawarich server"
        case setup = "Setup link"
        case url = "Server URL"
    }

    let id = UUID()
    let kind: Kind
    let values: ServerQRValues
    let ownTracks: Bool
    private let setupURL: URL?
    // Only render fixtures supply this; real scans always check the scanned server.
    var previewStatus: DawarichReviewStatus?

    init(code: ServerSetupCode, current: ServerQRValues, ownTracks: Bool) {
        var values = current
        switch code {
        case .dawarich(let endpoint):
            kind = .dawarich
            values.endpoint = endpoint.absoluteString
            values.token = ""
            setupURL = nil
        case .setupLink(let url, let setup):
            kind = .setup
            values.endpoint = setup.endpoint
            values.token = setup.token
            values.deviceId = setup.deviceId
            values.uniqueId = setup.uniqueId
            if !setup.headers.isEmpty { values.headers = setup.headers }
            setupURL = url
        case .endpoint(let endpoint):
            kind = .url
            values.endpoint = endpoint.absoluteString
            setupURL = nil
        }
        self.values = values
        self.ownTracks = ownTracks
    }

    var destination: OnboardingDestination {
        if let setupURL { return .setupLink(setupURL.absoluteString) }
        return .server(endpoint: values.endpoint, token: values.token, ownTracks: ownTracks)
    }

    var format: String { ownTracks ? "OwnTracks" : "GeoJSON" }

    var includesKey: Bool {
        let parts = URLComponents(string: values.endpoint)
        return !(parts?.queryItems?.first(where: { $0.name == "api_key" })?.value ?? "").isEmpty
            || !values.token.isEmpty
    }

    // Never display a URL's user info, query or fragment. Keep paths encoded so escaped
    // delimiters cannot turn into credentials or query text in the review.
    var serverDisplay: String {
        guard let parts = URLComponents(string: values.endpoint), let host = parts.host, !host.isEmpty else { return "Server" }
        var path = parts.percentEncodedPath
        for suffix in ["/api/v1/overland/batches", "/api/v1/owntracks/points"] {
            if path.hasSuffix(suffix + "/") { path.removeLast() }
            if path.hasSuffix(suffix) { path = String(path.dropLast(suffix.count)); break }
        }
        while path.hasSuffix("/") { path.removeLast() }
        var display = host + (parts.port.map { ":\($0)" } ?? "") + path
        let secrets = [values.token] + (parts.queryItems ?? []).filter { $0.name == "api_key" }.compactMap(\.value)
        for secret in secrets where !secret.isEmpty {
            for spelling in [secret, secret.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? secret,
                             secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? secret] {
                display = display.replacingOccurrences(of: spelling, with: "•••")
            }
        }
        return display
    }
}

@MainActor @Observable
final class ServerQRReviewCheck {
    private(set) var status = DawarichReviewStatus.checking
    private var probe: DawarichProbe?
    private var generation = UUID()

    func start(_ review: ServerQRReview) {
        cancel()
        if let preview = review.previewStatus { status = preview; return }
        status = .checking
        guard let server = DawarichServer(endpoint: review.values.endpoint, token: review.values.token) else {
            status = .unreachable
            return
        }
        let generation = self.generation
        probe = server.probeForReview(headers: review.values.headers) { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.status = status
                self.probe = nil
            }
        }
    }

    func cancel() {
        generation = UUID()
        probe?.cancel()
        probe = nil
    }
}

#if !WHEREWOLF_APP_STORE
extension ServerQRReview {
    static func preview(arguments: [String] = ProcessInfo.processInfo.arguments) -> ServerQRReview? {
        guard let index = arguments.firstIndex(of: "-WhereWolfQRReviewPreview"),
              arguments.indices.contains(index + 1) else { return nil }
        let fixture = arguments[index + 1]
        let current = ServerQRValues(endpoint: "", token: "", deviceId: "", uniqueId: false,
                                     acceptHTTP: false, headers: [:])
        let code: ServerSetupCode
        switch fixture {
        case "dawarich":
            var parts = URLComponents(string: "https://dawarich.example.com/tracking/api/v1/overland/batches")!
            parts.queryItems = [URLQueryItem(name: "api_key", value: "preview-only-key")]
            code = .dawarich(parts.url!)
        case "setup":
            var parts = URLComponents(string: "wherewolf://setup")!
            parts.queryItems = [URLQueryItem(name: "url", value: "https://dawarich.example.com/tracking"),
                                URLQueryItem(name: "token", value: "preview-only-key")]
            code = .setupLink(parts.url!, ServerSetup.parse(parts.url!)!)
        case "url":
            code = .endpoint(URL(string: "https://dawarich.example.com/tracking")!)
        default: return nil
        }
        var review = ServerQRReview(code: code, current: current, ownTracks: false)
        review.previewStatus = .dawarich(version: "1.2.3", account: "you" + "@" + "example.com")
        return review
    }
}
#endif
