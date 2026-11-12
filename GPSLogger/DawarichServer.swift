import Foundation

enum DawarichStatus: Equatable {
    case unknown
    case checking
    // Account identity is presentation state only; never persist or log it.
    case dawarich(version: String?, authenticated: Bool, account: String?)
    case notDawarich
}

enum ServerSetupCode {
    case dawarich(URL)
    case setupLink(URL, ServerSetup)
    case endpoint(URL)
}

enum DawarichReviewStatus: Equatable {
    case checking
    case dawarich(version: String?, account: String?)
    case keyRejected
    case unreachable
}

final class DawarichProbe {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    fileprivate func replace(with task: URLSessionDataTask) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        if cancelled { task.cancel() }
        task.resume()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}

struct DawarichServer: Equatable {
    let root: URL
    private let key: String

    init?(endpoint: String, token: String) {
        guard var parts = URLComponents(string: endpoint),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              !(parts.host ?? "").isEmpty, parts.url != nil else { return nil }
        let path = parts.percentEncodedPath
        let suffixes = ["/api/v1/overland/batches", "/api/v1/owntracks/points"]
        guard let suffix = suffixes.first(where: { path.hasSuffix($0) || path.hasSuffix($0 + "/") }) else { return nil }
        let key = parts.queryItems?.first(where: { $0.name == "api_key" })?.value ?? token
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        parts.percentEncodedPath = String(path.dropLast(suffix.count + (path.hasSuffix("/") ? 1 : 0)))
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        guard let root = parts.url else { return nil }
        self.root = root
        self.key = key
    }

    func healthRequest(headers: [String: String]) -> URLRequest {
        request(path: "/api/v1/health", headers: headers)
    }

    // Paths are API-relative constants supplied by the app, never server response URLs.
    func request(path: String, queryItems: [URLQueryItem] = [], headers: [String: String]) -> URLRequest {
        var parts = URLComponents(url: root, resolvingAgainstBaseURL: false)!
        parts.percentEncodedPath += path
        parts.queryItems = queryItems.isEmpty ? nil : queryItems
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for (name, value) in headers where SettingsSchema.validHeaders([name: value]) != nil {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func classify(_ response: URLResponse?, error: Error? = nil) -> DawarichStatus {
        guard error == nil, let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let signature = http.value(forHTTPHeaderField: "X-Dawarich-Response") else { return .notDawarich }
        return .dawarich(version: http.value(forHTTPHeaderField: "X-Dawarich-Version"),
                         authenticated: signature.lowercased() == "authenticated"
                            || signature.lowercased().hasSuffix("alive and authenticated!"), account: nil)
    }

    private static func accountEmail(_ data: Data?, response: URLResponse?, error: Error?) -> String? {
        guard error == nil, let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = object["user"] as? [String: Any],
              let email = user["email"] as? String,
              !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 320 else { return nil }
        return trimmed
    }

    @discardableResult
    func probe(headers: [String: String], completion: @escaping (DawarichStatus) -> Void) -> DawarichProbe {
        performProbe(headers: headers) { status, _ in completion(status) }
    }

    @discardableResult
    func probeForHistory(headers: [String: String], completion: @escaping (DawarichStatus, Bool) -> Void) -> DawarichProbe {
        performProbe(headers: headers, redirects: .withinRoot(root), completion: completion)
    }

    @discardableResult
    func probeForReview(headers: [String: String], completion: @escaping (DawarichReviewStatus) -> Void) -> DawarichProbe {
        performProbe(headers: headers) { status, rejected in
            switch status {
            case .dawarich(let version, true, let account):
                completion(.dawarich(version: version, account: account))
            case .dawarich(_, false, _): completion(.keyRejected)
            default: completion(rejected ? .keyRejected : .unreachable)
            }
        }
    }

    private func performProbe(headers: [String: String], redirects: DawarichRequestPolicy.Redirects = .reject,
                              completion: @escaping (DawarichStatus, Bool) -> Void) -> DawarichProbe {
        // Use default so the regression suite's configuration swizzle reaches this session.
        let configuration = DawarichTransport.configuration(.default, requestTimeout: 15, resourceTimeout: 15)
        let session = URLSession(configuration: configuration, delegate: DawarichRequestPolicy(redirects: redirects),
                                 delegateQueue: nil)
        let probe = DawarichProbe()
        let healthTask = session.dataTask(with: healthRequest(headers: headers)) { _, response, error in
            let status = Self.classify(response, error: error)
            guard case .dawarich(let version, true, _) = status else {
                let rejected = error == nil && [401, 403].contains((response as? HTTPURLResponse)?.statusCode ?? 0)
                completion(status, rejected)
                session.finishTasksAndInvalidate()
                return
            }
            let accountTask = session.dataTask(with: self.request(path: "/api/v1/users/me", headers: headers)) { data, response, error in
                let account = Self.accountEmail(data, response: response, error: error)
                completion(.dawarich(version: version, authenticated: true, account: account), false)
                session.finishTasksAndInvalidate()
            }
            probe.replace(with: accountTask)
        }
        // Serialize cancellation with the handoff so neither request can escape it.
        probe.replace(with: healthTask)
        return probe
    }

    static func parseQRCode(_ text: String, ownTracks: Bool) -> ServerSetupCode? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard let server = object["server_url"] as? String,
                  let key = object["api_key"] as? String,
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  var parts = URLComponents(string: server),
                  ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  !(parts.host ?? "").isEmpty, parts.url != nil else { return nil }
            var path = parts.percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            parts.percentEncodedPath = path + (ownTracks ? "/api/v1/owntracks/points" : "/api/v1/overland/batches")
            parts.queryItems = [URLQueryItem(name: "api_key", value: key)]
            parts.fragment = nil
            guard let endpoint = parts.url else { return nil }
            return .dawarich(endpoint)
        }
        guard let url = URL(string: text) else { return nil }
        if let setup = ServerSetup.parse(url) { return .setupLink(url, setup) }
        if GLManager.isValidEndpoint(text) { return .endpoint(url) }
        return nil
    }
}

// History requires a plain release in one known major. Insights retains its
// endpoint-floor and suffix rules, including later prereleases.
struct DawarichVersion {
    enum Policy {
        case minimumRelease
        case stableMajor(Int)
    }

    private let release: [Int]
    private let prerelease: Bool
    private let plainRelease: Bool

    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let version = value.split(separator: "-", maxSplits: 1)
        guard let first = version.first, let core = first.split(separator: "+", maxSplits: 1).first else { return nil }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        let release = parts.compactMap { Int($0) }
        guard parts.count == 3, release.count == 3, release.allSatisfy({ $0 >= 0 }) else { return nil }
        self.release = release
        prerelease = version.count > 1
        plainRelease = value == String(core)
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    static func supports(_ text: String?, minimum: String, policy: Policy = .minimumRelease) -> Bool {
        guard let text, let version = Self(text), let minimum = Self(minimum) else { return false }
        switch policy {
        case .minimumRelease:
            // A prerelease of the first supported version has not shipped its
            // contract yet; a later prerelease already contains the older API.
            if version.release == minimum.release { return !version.prerelease }
        case .stableMajor(let major):
            guard version.release[0] == major, version.plainRelease else { return false }
            if version.release == minimum.release { return true }
        }
        return minimum.release.lexicographicallyPrecedes(version.release)
    }
}

struct DawarichResponse {
    enum Policy { case history, insights }
    enum Status { case success, authentication, redirectRejected, unavailable, retryable, failure }

    let data: Data
    let http: HTTPURLResponse

    func status(for policy: Policy) -> Status {
        let code = http.statusCode
        if case .insights = policy, [400, 401, 403, 404, 405, 422, 501].contains(code) { return .unavailable }
        switch code {
        case 200..<300: return .success
        case 300..<400: return .redirectRejected
        case 401, 403: return .authentication
        case 404, 405, 410:
            if case .history = policy { return .unavailable }
            return .failure
        case 429, 500, 502, 503, 504: return .retryable
        default: return .failure
        }
    }
}

// Never retain URLSession's error or response body in an error: both can contain
// credentials, account details or locations. Only a network code reaches retry policy.
enum DawarichRequestError: Error, LocalizedError {
    case invalidResponse, redirectRejected, network(URLError.Code?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The server returned an invalid response."
        case .redirectRejected: return "The server redirected outside the permitted address."
        case .network: return "The server could not be reached."
        }
    }
}

enum DawarichTransport {
    static func configuration(_ original: URLSessionConfiguration, requestTimeout: TimeInterval,
                              resourceTimeout: TimeInterval, maximumConnections: Int? = nil) -> URLSessionConfiguration {
        let configuration = original.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        if let maximumConnections { configuration.httpMaximumConnectionsPerHost = maximumConnections }
        return configuration
    }

    static func response(for request: URLRequest, session: URLSession, redirects: DawarichRequestPolicy,
                         maximumBytes: Int) async throws -> DawarichResponse {
        try Task.checkCancellation()
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request) }
        catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw DawarichRequestError.network((error as? URLError)?.code)
        }
        try Task.checkCancellation()
        let (data, response) = result
        guard let http = response as? HTTPURLResponse, let url = http.url,
              redirects.acceptsResponse(url, for: request) else { throw DawarichRequestError.redirectRejected }
        // Error bodies are never decoded or cached. An unavailable endpoint may
        // return a large proxy page; it still follows the client's status policy.
        if (200..<300).contains(http.statusCode), data.count > maximumBytes { throw DawarichRequestError.invalidResponse }
        return DawarichResponse(data: data, http: http)
    }
}

final class DawarichRequestPolicy: NSObject, URLSessionTaskDelegate {
    enum Redirects { case reject, withinRoot(URL) }
    private let redirects: Redirects

    init(redirects: Redirects = .reject) { self.redirects = redirects }
    convenience init(root: URL) { self.init(redirects: .withinRoot(root)) }

    func permits(_ url: URL) -> Bool {
        guard case .withinRoot(let root) = redirects else { return false }
        func port(_ value: URL) -> Int? { value.port ?? (value.scheme?.lowercased() == "https" ? 443 : 80) }
        let prefix = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        let components = url.path.split(separator: "/", omittingEmptySubsequences: false)
        return url.scheme?.lowercased() == root.scheme?.lowercased()
            && url.host?.lowercased() == root.host?.lowercased() && port(url) == port(root)
            && url.user == nil && url.password == nil
            && !components.contains(".") && !components.contains("..") && !url.path.contains("\\")
            && (prefix.isEmpty || url.path == prefix || url.path.hasPrefix(prefix + "/"))
    }

    func acceptsResponse(_ url: URL, for request: URLRequest) -> Bool {
        switch redirects {
        case .reject: return url == request.url
        case .withinRoot: return permits(url)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, permits(url), let original = task.originalRequest else {
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.allHTTPHeaderFields = original.allHTTPHeaderFields
        redirected.httpShouldHandleCookies = false
        completionHandler(redirected)
    }
}

// Keep existing History callers and tests source-compatible with the shared policy.
typealias DawarichHistoryRedirectDelegate = DawarichRequestPolicy
