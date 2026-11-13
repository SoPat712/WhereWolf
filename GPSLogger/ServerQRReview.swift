import Foundation
import Observation

struct ServerQRValues: Equatable {
    var endpoint: String
    var token: String
    var deviceId: String
    var uniqueId: Bool
    var acceptHTTP: Bool
    var headers: [String: String]

    static var saved: Self {
        let gl = GLManager.shared()!
        return Self(endpoint: gl.apiEndpointURL() ?? "", token: gl.apiAccessToken() ?? "",
                    deviceId: gl.deviceId() ?? "", uniqueId: UserDefaults.standard.bool(forKey: GLIncludeUniqueIdDefaultsName),
                    acceptHTTP: UserDefaults.standard.bool(forKey: GLConsiderHTTP200SuccessDefaultsName),
                    headers: gl.customHTTPHeaders ?? [:])
    }

    var host: String { URLComponents(string: endpoint)?.host ?? "this server" }

    func changesServer(from saved: Self) -> Bool {
        Self.serverURL(endpoint) != Self.serverURL(saved.endpoint) || token != saved.token
            || Self.headerIdentity(headers) != Self.headerIdentity(saved.headers)
    }

    private static func serverURL(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text) else { return text }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        parts.fragment = nil
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.string ?? text
    }

    private static func headerIdentity(_ headers: [String: String]) -> [String: String] {
        Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
    }

    static func onboarding(_ destination: OnboardingDestination, current: Self) -> Self? {
        switch destination {
        case .setupLink(let text):
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let setup = ServerSetup.parse(url) else { return nil }
            return ServerQRReview(code: .setupLink(url, setup), current: current, ownTracks: false).values
        case .server(let endpoint, let token, _):
            var values = current
            values.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            values.token = token
            return GLManager.isValidEndpoint(values.endpoint) ? values : nil
        case .device, .iCloud: return nil
        }
    }

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
    var previewPendingQueue: ServerPendingQueue?

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

    var isDawarich: Bool {
        kind == .dawarich || DawarichServer(endpoint: values.endpoint, token: values.token) != nil
    }

    var foundAnnouncement: String { isDawarich ? "Dawarich server found" : "Code found" }

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
enum ServerQRPreviewFixture: String {
    case dawarich, setup, url, other

    static let current = ServerQRValues(endpoint: "", token: "", deviceId: "", uniqueId: false,
                                        acceptHTTP: false, headers: [:])
    private static let endpoint = "https://dawarich.example.com/tracking/api/v1/overland/batches"

    var text: String {
        switch self {
        case .dawarich:
            return #"{"server_url":"https://dawarich.example.com/tracking","api_key":"preview-only-key"}"#
        case .setup:
            var parts = URLComponents(string: "wherewolf://setup")!
            parts.queryItems = [URLQueryItem(name: "url", value: Self.endpoint),
                                URLQueryItem(name: "token", value: "preview-only-key")]
            return parts.url!.absoluteString
        case .url:
            return Self.endpoint + "?api_key=preview-only-key"
        case .other:
            return "https://dawarich.example.com/tracking/upload?api_key=preview-only-key"
        }
    }

    var status: DawarichReviewStatus {
        self == .other ? .unreachable : .dawarich(version: "1.2.3", account: "you" + "@" + "example.com")
    }
}

struct ServerQRScanPreview: Identifiable {
    enum Hold: String { case check, badge }

    let id = UUID()
    let fixture: ServerQRPreviewFixture
    let hold: Hold?

    static func parse(arguments: [String] = ProcessInfo.processInfo.arguments) -> ServerQRScanPreview? {
        guard let index = arguments.firstIndex(of: "-WhereWolfQRScanPreview"),
              arguments.indices.contains(index + 1),
              let fixture = ServerQRPreviewFixture(rawValue: arguments[index + 1]) else { return nil }
        var hold: Hold?
        if let index = arguments.firstIndex(of: "-WhereWolfQRScanPreviewHold"),
           arguments.indices.contains(index + 1) {
            hold = Hold(rawValue: arguments[index + 1])
        }
        return ServerQRScanPreview(fixture: fixture, hold: hold)
    }
}

extension ServerQRReview {
    static func preview(arguments: [String] = ProcessInfo.processInfo.arguments) -> ServerQRReview? {
        guard let index = arguments.firstIndex(of: "-WhereWolfQRReviewPreview"),
              arguments.indices.contains(index + 1),
              let fixture = ServerQRPreviewFixture(rawValue: arguments[index + 1]), fixture != .other,
              let code = DawarichServer.parseQRCode(fixture.text, ownTracks: false) else { return nil }
        var review = ServerQRReview(code: code, current: ServerQRPreviewFixture.current, ownTracks: false)
        review.previewStatus = fixture.status
        if let index = arguments.firstIndex(of: "-WhereWolfQRPendingPreview"),
           arguments.indices.contains(index + 1), let count = Int(arguments[index + 1]),
           (1...1_000_000_000).contains(count) {
            let newest = Date(timeIntervalSince1970: 1_794_484_800) // Invented, fixed UTC dates.
            review.previewPendingQueue = ServerPendingQueue(count: count, importedCount: 0,
                oldest: count == 1 ? newest : newest.addingTimeInterval(-3 * 86_400), newest: newest)
        }
        return review
    }
}
#endif
