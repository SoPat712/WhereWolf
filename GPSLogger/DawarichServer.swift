import Foundation

enum DawarichStatus: Equatable {
    case unknown
    case checking
    case dawarich(version: String?, authenticated: Bool)
    case notDawarich
}

enum ServerSetupCode {
    case dawarich(URL)
    case setupLink(URL, ServerSetup)
    case endpoint(URL)
}

struct DawarichServer {
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
        var parts = URLComponents(url: root, resolvingAgainstBaseURL: false)!
        parts.percentEncodedPath += "/api/v1/health"
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
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
                         authenticated: signature.localizedCaseInsensitiveContains("authenticated"))
    }

    @discardableResult
    func probe(headers: [String: String], completion: @escaping (DawarichStatus) -> Void) -> URLSessionDataTask {
        // Use default so the regression suite's configuration swizzle reaches this session.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: healthRequest(headers: headers)) { _, response, error in
            completion(Self.classify(response, error: error))
            session.finishTasksAndInvalidate()
        }
        task.resume()
        return task
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
