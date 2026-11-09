// TestFlight diagnostics: left out of App Store builds (WHEREWOLF_APP_STORE=YES).
#if WHEREWOLF_TESTFLIGHT_DIAGNOSTICS
import Foundation
import MetricKit

// TestFlight diagnostics: left out of App Store builds (WHEREWOLF_APP_STORE=YES).
@objc final class TestFlightDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = TestFlightDiagnostics()
    static let reportsChanged = Notification.Name("WhereWolfDiagnosticReportsChanged")
    private let queue = DispatchQueue(label: "me.joshpatra.WhereWolf.diagnostics")
    private var modern: AnyObject?
    private var started = false

    // TestFlight diagnostics: left out of App Store builds (WHEREWOLF_APP_STORE=YES).
    @objc static func start() {
        guard !shared.started else { return }
        shared.started = true
        if #available(iOS 27.0, *) {
            let collector = ModernMetricCollector()
            shared.modern = collector
            collector.start()
        } else {
            MXMetricManager.shared.add(shared)
        }
    }

    // TestFlight diagnostics: left out of App Store builds (WHEREWOLF_APP_STORE=YES).
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { save(payload.jsonRepresentation(), kind: "metric") }
    }

    // TestFlight diagnostics: left out of App Store builds (WHEREWOLF_APP_STORE=YES).
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { save(payload.jsonRepresentation(), kind: "diagnostic") }
    }

    // TestFlight diagnostics: left out of App Store builds (WHEREWOLF_APP_STORE=YES).
    func save(_ data: Data, kind: String) {
        queue.async {
            do {
                let directory = try self.directory()
                let stamp = Int(Date().timeIntervalSince1970)
                let file = directory.appendingPathComponent("\(stamp)-\(kind)-\(UUID().uuidString).json")
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                let files = try self.files(in: directory)
                for old in files.dropFirst(100) { try FileManager.default.removeItem(at: old) }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.reportsChanged, object: nil)
                }
            } catch {
                NSLog("MetricKit report could not be saved: %@", error.localizedDescription)
            }
        }
    }

    // TestFlight diagnostics: left out of App Store builds (WHEREWOLF_APP_STORE=YES).
    func loadReports(completion: @escaping ([URL]) -> Void) {
        queue.async {
            let files = (try? self.files(in: self.directory())) ?? []
            DispatchQueue.main.async { completion(files) }
        }
    }

    // TestFlight diagnostics: left out of App Store builds (WHEREWOLF_APP_STORE=YES).
    func readReport(_ file: URL, completion: @escaping (String) -> Void) {
        queue.async {
            let text: String
            do {
                let data = try Data(contentsOf: file)
                let object = try JSONSerialization.jsonObject(with: data)
                let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                text = String(decoding: pretty, as: UTF8.self)
            } catch {
                text = "Could not read report: \(error.localizedDescription)"
            }
            DispatchQueue.main.async { completion(text) }
        }
    }

    private func directory() throws -> URL {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    private func files(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

// TestFlight diagnostics: left out of App Store builds (WHEREWOLF_APP_STORE=YES).
@available(iOS 27.0, *)
private final class ModernMetricCollector {
    private let manager = MetricManager()
    private var metrics: Task<Void, Never>?
    private var diagnostics: Task<Void, Never>?

    // TestFlight diagnostics: left out of App Store builds (WHEREWOLF_APP_STORE=YES).
    func start() {
        let manager = manager
        metrics = Task {
            for await report in manager.metricReports {
                if let data = try? JSONEncoder().encode(report) { TestFlightDiagnostics.shared.save(data, kind: "metric") }
            }
        }
        diagnostics = Task {
            for await report in manager.diagnosticReports {
                if let data = try? JSONEncoder().encode(report) { TestFlightDiagnostics.shared.save(data, kind: "diagnostic") }
            }
        }
    }
}
#endif
