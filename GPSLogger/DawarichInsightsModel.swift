import Foundation
import Observation

@Observable
@MainActor
final class DawarichInsightsModel {
    private(set) var snapshot = DawarichInsights.Snapshot()
    private(set) var years: [Int] = []
    private(set) var year = Calendar.current.component(.year, from: Date())
    private(set) var loading = false
    private(set) var thumbnailRevision = 0
    @ObservationIgnored private var client: DawarichInsightsClient?
    @ObservationIgnored private var connection: DawarichInsightsConnection?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var selectedYear = false
    @ObservationIgnored private var refreshedThumbnails: [String: Int] = [:]
    let preview: Bool

    init(preview: Bool = false) {
        self.preview = preview
#if !WHEREWOLF_APP_STORE
        if preview {
            year = 2025
            years = [2025, 2024]
            snapshot = DawarichInsightsFixtures.snapshot(year: year)
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

    func selectYear(_ value: Int) async {
        guard years.contains(value), value != year else { return }
        year = value
        selectedYear = true
        snapshot = .init()
        await load(connection: connection)
    }

    func clearPresentation() {
        generation = UUID()
        snapshot = .init()
        years = []
        loading = false
        thumbnailRevision &+= 1
    }

    func load(connection: DawarichInsightsConnection?, force: Bool = false) async {
#if !WHEREWOLF_APP_STORE
        if preview {
            snapshot = DawarichInsightsFixtures.snapshot(year: year)
            return
        }
#endif
        let generation = UUID()
        self.generation = generation
        guard let connection else {
            self.connection = nil
            client = nil
            years = []
            snapshot = .init()
            loading = false
            return
        }
        if self.connection != connection {
            self.connection = connection
            client = DawarichInsightsClient(connection: connection)
            snapshot = .init()
            years = []
            selectedYear = false
            refreshedThumbnails = [:]
        }
        guard let client else { return }
        loading = true
        defer { if self.generation == generation { loading = false } }
        for policy in [DawarichInsightsClient.Policy.cacheOnly, .refresh(force: force)] {
            async let tracked = client.read(.trackedMonths, as: [DawarichInsights.TrackedYear].self, policy: policy)
            async let catalog = client.read(.digests, as: DawarichInsights.DigestList.self, policy: policy)
            async let latest = client.read(.overview(nil), as: DawarichInsights.Overview.self, policy: policy)
            let (trackedResult, catalogResult, latestResult) = await (tracked, catalog, latest)
            guard self.generation == generation, !Task.isCancelled else { return }
            var available = (trackedResult.value ?? []).filter { !$0.months.isEmpty }.map(\.year)
            available += catalogResult.value?.digests.map(\.year) ?? []
            available += catalogResult.value?.availableYears ?? []
            available += latestResult.value?.availableYears ?? []
            if let value = latestResult.value, !value.stats.isEmpty { available.append(value.year) }
            available = Array(Set(available.filter { (1970...9998).contains($0) })).sorted(by: >)
            if !available.isEmpty { years = available }
            if !selectedYear || !years.contains(year), let newest = years.first { year = newest }
            let chosen = year
            let existingDigest = catalogResult.value?.digests.contains { $0.year == chosen } == true
            let result = await Self.loadYear(chosen, client: client, policy: policy, digestExists: existingDigest)
            guard self.generation == generation, !Task.isCancelled, year == chosen else { return }
            snapshot = result
            if force, case .refresh = policy { thumbnailRevision &+= 1 }
        }
    }

    nonisolated private static func loadYear(_ year: Int, client: DawarichInsightsClient, policy: DawarichInsightsClient.Policy,
                          digestExists: Bool) async -> DawarichInsights.Snapshot {
        async let overview = client.read(.overview(year), as: DawarichInsights.Overview.self, policy: policy)
        async let details = client.read(.details(year), as: DawarichInsights.Details.self, policy: policy)
        async let countries = client.read(.countries(year), as: DawarichInsights.Countries.self, policy: policy)
        async let cities = client.read(.cities(year), as: DawarichInsights.Cities.self, policy: policy)
        async let residency = client.read(.residency(year), as: DawarichInsights.Residency.self, policy: policy)
        async let places = client.read(.places, as: [DawarichInsights.Place].self, policy: policy)
        async let visits = client.read(.visits(year), as: [DawarichInsights.Visit].self, policy: policy)
        async let photos = client.read(.photos(year), as: [DawarichInsights.Photo].self, policy: policy)
        var digestResult = DawarichInsightsClient.Result<DawarichInsights.Digest>()
        if digestExists { digestResult = await client.read(.digest(year), as: DawarichInsights.Digest.self, policy: policy) }
        let (o, d, c, city, r, p, v, photo) = await (overview, details, countries, cities, residency, places, visits, photos)
        var result = DawarichInsights.Snapshot()
        result.overview = o.value?.year == year ? o.value : nil
        result.details = d.value?.year == year ? d.value : nil
        result.countries = c.value
        result.cities = city.value
        result.residency = r.value?.year == year ? r.value : nil
        result.places = p.value ?? []
        result.visits = (v.value ?? []).compactMap { visit -> (DawarichInsights.Visit, Date)? in
            guard visit.status != "declined", let date = visit.date else { return nil }
            return (visit, date)
        }.sorted { $0.1 > $1.1 }.map(\.0)
        var identities = Set<String>()
        result.photos = (photo.value ?? []).compactMap { photo -> (DawarichInsights.Photo, Date)? in
            guard let date = photo.date, ["immich", "photoprism"].contains(photo.source),
                  identities.insert(photo.identity).inserted else { return nil }
            return (photo, date)
        }.sorted { $0.1 > $1.1 }.map(\.0)
        result.digest = digestResult.value?.year == year ? digestResult.value : nil
        result.updated = [o.updated, d.updated, c.updated, city.updated, r.updated, p.updated, v.updated,
                          photo.updated, digestResult.updated].compactMap { $0 }.min()
        result.offline = [o.offline, d.offline, c.offline, city.offline, r.offline, p.offline, v.offline,
                          photo.offline, digestResult.offline].contains(true)
        result.prepare()
        return result
    }

    func thumbnail(_ photo: DawarichInsights.Photo) async -> Data? {
        guard !preview, let client else { return nil }
        let force = thumbnailRevision > 0 && refreshedThumbnails[photo.identity] != thumbnailRevision
        if force { refreshedThumbnails[photo.identity] = thumbnailRevision }
        return await client.thumbnail(photo, force: force)
    }
}
