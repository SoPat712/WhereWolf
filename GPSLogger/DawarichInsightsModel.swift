import Foundation
import Observation

enum DawarichInsightsSection: String, CaseIterable {
    case overview, details, countries, cities, residency, places, visits, photos, digest

    var title: String {
        switch self {
        case .overview: return "Year overview"
        case .details: return "Comparison and patterns"
        case .countries: return "Countries"
        case .cities: return "Cities"
        case .residency: return "Days by country"
        case .places: return "Place names"
        case .visits: return "Places and visits"
        case .photos: return "Photos"
        case .digest: return "Yearly digest"
        }
    }
    func endpoint(year: Int) -> DawarichInsightsEndpoint {
        switch self {
        case .overview: return .overview(year)
        case .details: return .details(year)
        case .countries: return .countries(year)
        case .cities: return .cities(year)
        case .residency: return .residency(year)
        case .places: return .places
        case .visits: return .visits(year)
        case .photos: return .photos(year)
        case .digest: return .digest(year)
        }
    }
}

enum DawarichInsightsLoadState: Equatable {
    case idle, loading, loaded, empty, unsupported(Int), failed(DawarichInsightsFailure)
    var isLoading: Bool { self == .idle || self == .loading }
    var failure: DawarichInsightsFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}

@Observable
@MainActor
final class DawarichInsightsModel {
    enum PreviewState: String { case full, loading, partial }
    private(set) var snapshot = DawarichInsights.Snapshot()
    private(set) var years: [Int] = []
    private(set) var year: Int
    private(set) var states: [DawarichInsightsSection: DawarichInsightsLoadState] = [:]
    private(set) var thumbnailRevision = 0
    private(set) var serverDescription = "Dawarich"
    private(set) var discoveryLoading = false
    private(set) var attempted = false
    private(set) var discoveryStates: [String: DawarichInsightsLoadState] = [:]
    @ObservationIgnored private var client: DawarichInsightsClient?
    @ObservationIgnored private var connection: DawarichInsightsConnection?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var selectedYear = false
    @ObservationIgnored private var serverYears = Set<Int>()
    @ObservationIgnored private var refreshedThumbnails: [String: Int] = [:]
    @ObservationIgnored private var timestamps: [DawarichInsightsSection: Date] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var retryTasks: [DawarichInsightsSection: Task<Void, Never>] = [:]
    @ObservationIgnored private var sectionGenerations: [DawarichInsightsSection: UUID] = [:]
    @ObservationIgnored private let clientFactory: (DawarichInsightsConnection) -> DawarichInsightsClient
    let preview: Bool
    let previewState: PreviewState

    init(preview: Bool = false, previewState: PreviewState? = nil,
         initialYear: Int = Calendar.current.component(.year, from: Date()),
         clientFactory: @escaping (DawarichInsightsConnection) -> DawarichInsightsClient = { DawarichInsightsClient(connection: $0) }) {
        self.preview = preview
        self.previewState = previewState ?? Self.requestedPreviewState
        self.clientFactory = clientFactory
        year = initialYear
#if !WHEREWOLF_APP_STORE
        if preview {
            year = 2025
            years = [2025, 2024]
            applyPreview()
        }
#endif
    }

    static var previewEnabled: Bool {
#if !WHEREWOLF_APP_STORE
        return ProcessInfo.processInfo.arguments.contains("-WhereWolfInsightsPreview")
#else
        return false
#endif
    }

    private static var requestedPreviewState: PreviewState {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-WhereWolfInsightsPreview"), index + 1 < arguments.count else { return .full }
        return PreviewState(rawValue: arguments[index + 1]) ?? .full
    }

    var loading: Bool { discoveryLoading || states.values.contains { $0.isLoading } }
    func state(for section: DawarichInsightsSection) -> DawarichInsightsLoadState { states[section] ?? .idle }
    var showEmptyState: Bool {
        attempted && !states.values.contains { $0.isLoading } && snapshot.sections.isEmpty
    }

    var emptyMessage: String {
        guard connection != nil || preview else { return "Connect an authenticated Dawarich server in Settings to see your year here." }
        var sentences = ["\(serverDescription) has no insights to show for \(year)."]
        let empty = DawarichInsightsSection.allCases.filter { state(for: $0) == .empty }.map(\.title)
        let missing = DawarichInsightsSection.allCases.compactMap { section -> String? in
            guard case .unsupported(let status) = state(for: section) else { return nil }
            if section == .digest, status == 404 { return "Yearly digest (not saved for this year)" }
            if section == .photos, status == 401 { return "Photos (integration not configured)" }
            return "\(section.title) (HTTP \(status))"
        }
        if !empty.isEmpty { sentences.append("Returned no data: " + empty.joined(separator: ", ") + ".") }
        if !missing.isEmpty { sentences.append("Unavailable: " + missing.joined(separator: ", ") + ".") }
        let failures = Dictionary(grouping: DawarichInsightsSection.allCases.filter {
            state(for: $0).failure != nil
        }, by: { state(for: $0).failure!.message })
        for message in failures.keys.sorted() {
            sentences.append("Could not load " + failures[message]!.map(\.title).joined(separator: ", ") + ". " + message)
        }
        let returned = DawarichInsightsSection.allCases.filter { state(for: $0) == .loaded }.map(\.title)
        let discovery = discoveryStates.keys.sorted().compactMap { name -> String? in
            switch discoveryStates[name] {
            case .loaded: return name
            default: return nil
            }
        }
        if !(returned + discovery).isEmpty {
            sentences.append("Your server did return " + (returned + discovery).joined(separator: ", ") + ".")
        }
        return sentences.joined(separator: "\n\n")
    }

    func selectYear(_ value: Int) async {
        guard years.contains(value), value != year else { return }
        year = value
        selectedYear = true
        resetSnapshot()
        await load(connection: connection)
    }

    func clearPresentation() {
        cancelTasks()
        generation = UUID()
        resetSnapshot()
        years = []
        states = Dictionary(uniqueKeysWithValues: DawarichInsightsSection.allCases.map { ($0, .empty) })
        discoveryStates = [:]
        discoveryLoading = false
        attempted = true
        thumbnailRevision &+= 1
    }

    func load(connection: DawarichInsightsConnection?, force: Bool = false) async {
#if !WHEREWOLF_APP_STORE
        if preview { applyPreview(); return }
#endif
        cancelTasks()
        let token = UUID()
        generation = token
        attempted = true
        guard let connection else {
            self.connection = nil
            client = nil
            clearPresentation()
            return
        }
        if self.connection != connection {
            self.connection = connection
            client = clientFactory(connection)
            resetSnapshot()
            years = []
            selectedYear = false
            serverYears = []
            refreshedThumbnails = [:]
            discoveryStates = [:]
        }
        serverDescription = connection.version.map { "Dawarich \($0)" } ?? "Dawarich (version not reported)"
        guard let client else { return }
        years = Array(Set(years + [year])).sorted(by: >)
        if force { thumbnailRevision &+= 1 }
        beginSections()
        discoveryLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(client: client, force: force, token: token)
        }
        loadTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if generation == token { loadTask = nil }
    }

    private func run(client: DawarichInsightsClient, force: Bool, token: UUID) async {
        defer {
            if generation == token {
                discoveryLoading = false
                for section in DawarichInsightsSection.allCases where state(for: section).isLoading && retryTasks[section] == nil {
                    states[section] = .failed(.cancelled)
                }
            }
        }
        await loadSections(client: client, force: force, token: token, discover: true)
        guard generation == token, !Task.isCancelled else { return }
        discoveryLoading = false
        // Missing current-year stats must not strand a server whose newest data is older.
        // Discovery never holds back individual current-year sections.
        if !selectedYear, retryTasks.isEmpty, snapshot.sections.isEmpty, let newest = serverYears.max(), newest != year {
            year = newest
            resetSnapshot()
            beginSections()
            await loadSections(client: client, force: force, token: token, discover: false)
        }
    }

    private func loadSections(client: DawarichInsightsClient, force: Bool, token: UUID, discover: Bool) async {
        let chosen = year
        await withTaskGroup(of: Void.self) { group in
            for section in DawarichInsightsSection.allCases {
                let revision = sectionGenerations[section]!
                group.addTask {
                    await self.fetch(section, year: chosen, client: client, force: force, token: token, revision: revision)
                }
            }
            if discover {
                group.addTask { await self.discoverYears(client: client, force: force, token: token) }
            }
        }
    }

    func retry(_ section: DawarichInsightsSection) async {
#if !WHEREWOLF_APP_STORE
        if preview { return }
#endif
        guard let client else { return }
        retryTasks[section]?.cancel()
        let revision = UUID()
        sectionGenerations[section] = revision
        states[section] = .loading
        let token = generation
        let chosen = year
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.fetch(section, year: chosen, client: client, force: true, token: token, revision: revision)
        }
        retryTasks[section] = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if generation == token, sectionGenerations[section] == revision { retryTasks[section] = nil }
    }

    private func fetch(_ section: DawarichInsightsSection, year: Int, client: DawarichInsightsClient,
                       force: Bool, token: UUID, revision: UUID) async {
        let endpoint = section.endpoint(year: year)
        switch section {
        case .overview:
            await read(DawarichInsights.Overview.self, endpoint, section, client, force, token, revision,
                       valid: { $0.year == year }) { $0.overview = $1 }
        case .details:
            await read(DawarichInsights.Details.self, endpoint, section, client, force, token, revision,
                       valid: { $0.year == year }) { $0.details = $1 }
        case .countries:
            await read(DawarichInsights.Countries.self, endpoint, section, client, force, token, revision) { $0.countries = $1 }
        case .cities:
            await read(DawarichInsights.Cities.self, endpoint, section, client, force, token, revision) { $0.cities = $1 }
        case .residency:
            await read(DawarichInsights.Residency.self, endpoint, section, client, force, token, revision,
                       valid: { $0.year == nil || $0.year == year }) { $0.residency = $1 }
        case .places:
            await read([DawarichInsights.Place].self, endpoint, section, client, force, token, revision) { $0.places = $1 ?? [] }
        case .visits:
            await read([DawarichInsights.Visit].self, endpoint, section, client, force, token, revision,
                       prepare: { DawarichInsights.sortedVisits($0) }) { $0.visits = $1 ?? [] }
        case .photos:
            await read([DawarichInsights.Photo].self, endpoint, section, client, force, token, revision,
                       prepare: { DawarichInsights.sortedPhotos($0) }) { $0.photos = $1 ?? [] }
        case .digest:
            // GET only: a missing digest returns 404, and never starts generation.
            await read(DawarichInsights.Digest.self, endpoint, section, client, force, token, revision,
                       valid: { $0.year == year }) { $0.digest = $1 }
        }
    }

    private func read<T: Decodable>(_ type: T.Type, _ endpoint: DawarichInsightsEndpoint,
                                   _ section: DawarichInsightsSection, _ client: DawarichInsightsClient,
                                   _ force: Bool, _ token: UUID, _ revision: UUID,
                                   valid: (T) -> Bool = { _ in true },
                                   prepare: @escaping @Sendable (T) -> T = { $0 },
                                   apply: (inout DawarichInsights.Snapshot, T?) -> Void) async {
        for policy in [DawarichInsightsClient.Policy.cacheOnly, .refresh(force: force)] {
            let result = await client.read(endpoint, as: type, policy: policy)
            guard generation == token, sectionGenerations[section] == revision else { return }
            if case .notCached = result.outcome { continue }
            if let value = result.value, !valid(value) {
                if case .refresh = policy { states[section] = .failed(.missingYear) }
                continue
            }
            // A cancelled refresh must not discard content already published by its cache pass.
            if result.value != nil || result.outcome == .available || isUnsupported(result.outcome) {
                let prepared = await Task.detached(priority: .utility) { result.value.map(prepare) }.value
                guard generation == token, sectionGenerations[section] == revision else { return }
                apply(&snapshot, prepared)
                timestamps[section] = result.updated
                if section == .places || section == .visits { snapshot.prepare() }
            }
            switch result.outcome {
            case .available: states[section] = hasContent(section) ? .loaded : .empty
            case .unsupported(let status): states[section] = .unsupported(status)
            case .failed(let failure): states[section] = .failed(failure)
            case .notCached: break
            }
            snapshot.updated = timestamps.values.min()
            snapshot.offline = states.values.contains { $0.failure != nil && $0.failure != .cancelled }
        }
    }

    private func discoverYears(client: DawarichInsightsClient, force: Bool, token: UUID) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.discover([DawarichInsights.TrackedYear].self, endpoint: .trackedMonths, name: "tracked years",
                                    client: client, force: force, token: token) { $0.filter { !$0.months.isEmpty }.map(\.year) }
            }
            group.addTask {
                await self.discover(DawarichInsights.DigestList.self, endpoint: .digests, name: "digest catalog",
                                    client: client, force: force, token: token) { $0.digests.map(\.year) + ($0.availableYears ?? []) }
            }
            group.addTask {
                await self.discover(DawarichInsights.Overview.self, endpoint: .overview(nil), name: "available years",
                                    client: client, force: force, token: token) {
                    ($0.availableYears ?? []) + ($0.stats.isEmpty && $0.months.isEmpty ? [] : [$0.year])
                }
            }
        }
    }

    private func discover<T: Decodable>(_ type: T.Type, endpoint: DawarichInsightsEndpoint, name: String,
                                       client: DawarichInsightsClient, force: Bool, token: UUID,
                                       extract: (T) -> [Int]) async {
        for policy in [DawarichInsightsClient.Policy.cacheOnly, .refresh(force: force)] {
            let result = await client.read(endpoint, as: type, policy: policy)
            guard generation == token else { return }
            switch result.outcome {
            case .notCached: continue
            case .available:
                let found = result.value.map(extract) ?? []
                serverYears.formUnion(found.filter { (1970...9998).contains($0) })
                years = Array(Set((years + found).filter { (1970...9998).contains($0) })).sorted(by: >)
                discoveryStates[name] = found.isEmpty ? .empty : .loaded
            case .unsupported(let status): discoveryStates[name] = .unsupported(status)
            case .failed(let failure): discoveryStates[name] = .failed(failure)
            }
        }
    }

    private func hasContent(_ section: DawarichInsightsSection) -> Bool {
        switch section {
        case .overview: return !(snapshot.overview?.stats.isEmpty ?? true) || !(snapshot.overview?.months.isEmpty ?? true)
        case .details: return !(snapshot.details?.comparison?.stats.isEmpty ?? true) || snapshot.details?.travelPatterns?.isEmpty == false
        case .countries: return !(snapshot.countries?.countries.isEmpty ?? true)
        case .cities: return snapshot.cities?.data.contains { !$0.cities.isEmpty } == true
        case .residency: return !(snapshot.residency?.countries.isEmpty ?? true)
        case .places: return !snapshot.places.isEmpty
        case .visits: return !snapshot.visits.isEmpty
        case .photos: return !snapshot.photos.isEmpty
        case .digest: return snapshot.sections.contains("digest")
        }
    }

    private func isUnsupported(_ outcome: DawarichInsightsClient.Outcome) -> Bool {
        if case .unsupported = outcome { return true }
        return false
    }
    private func beginSections() {
        for section in DawarichInsightsSection.allCases {
            states[section] = .loading
            sectionGenerations[section] = UUID()
        }
    }
    private func resetSnapshot() {
        snapshot = .init()
        timestamps = [:]
    }
    private func cancelTasks() {
        loadTask?.cancel()
        loadTask = nil
        retryTasks.values.forEach { $0.cancel() }
        retryTasks = [:]
    }

#if !WHEREWOLF_APP_STORE
    private func applyPreview() {
        attempted = true
        serverDescription = "Dawarich 1.22.0 · Preview"
        snapshot = previewState == .loading ? .init() : DawarichInsightsFixtures.snapshot(year: year)
        states = Dictionary(uniqueKeysWithValues: DawarichInsightsSection.allCases.map {
            ($0, previewState == .loading ? .loading : .loaded)
        })
        if previewState == .partial {
            snapshot.details = nil
            snapshot.photos = []
            snapshot.residency = nil
            states[.details] = .failed(.http(500))
            states[.photos] = .failed(.timedOut)
            states[.residency] = .unsupported(404)
        }
        snapshot.prepare()
    }
#endif

    func thumbnail(_ photo: DawarichInsights.Photo, force: Bool = false) async -> Data? {
        guard !preview, let client else { return nil }
        let refresh = force || (thumbnailRevision > 0 && refreshedThumbnails[photo.identity] != thumbnailRevision)
        if refresh { refreshedThumbnails[photo.identity] = thumbnailRevision }
        return await client.thumbnail(photo, force: refresh)
    }
}
