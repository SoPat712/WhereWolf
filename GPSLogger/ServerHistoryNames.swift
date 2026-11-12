import Foundation

// Shares the history client's transport and cache. Requests never depend on a ruler frame.
@MainActor
final class ServerHistoryNames {
    private(set) var snapshot = DawarichStopNames()
    var changed: (() -> Void)?
    private let cache: ServerHistoryCache
    private var client: DawarichHistoryClient?
    private var preparation: Task<Void, Never>?
    private var placesRequest: Task<Void, Never>?
    private var requests: [Date: Task<Void, Never>] = [:]
    private var wanted: [ServerHistoryRequestSource: Set<Date>] = [:]
    private var visits: [Date: [DawarichStopVisit]] = [:]
    private var viewed: [Date] = []
    private var fetched = Set<Date>()
    private var retryAfter: [Date: Date] = [:]
    private var calendar = Calendar.current
    private var generation = 0
    private var publication = 0

    init(cache: ServerHistoryCache) { self.cache = cache }

    func configure(client: DawarichHistoryClient?, identity: String, calendar: Calendar,
                   after setup: Task<Void, Never>?) {
        let previous = cancel()
        self.client = client
        self.calendar = calendar
        let generation = generation
        fetched.removeAll(); retryAfter.removeAll()
        preparation = Task { [weak self] in
            guard let self else { return }
            await setup?.value
            for task in previous { await task.value }
            guard self.generation == generation, !Task.isCancelled else { return }
            do {
                if client == nil, try await self.cache.storageBytes() == 0 { return }
                guard self.generation == generation, !Task.isCancelled else { return }
                try await self.cache.selectSource(identity)
                let cached = try await self.cache.stopPlaces()
                guard self.generation == generation, !Task.isCancelled else { return }
                self.snapshot.places = cached
                self.publish()
            } catch { /* Cached names survive an unavailable read. */ }
        }
        let ready = preparation
        placesRequest = Task { [weak self] in
            await ready?.value
            guard let self, self.generation == generation, !Task.isCancelled, let client else { return }
            do {
                let places = try await client.stopPlaces()
                guard self.generation == generation, !Task.isCancelled else { return }
                try await self.cache.storeStopPlaces(places)
                guard self.generation == generation, !Task.isCancelled else { return }
                self.snapshot.places = places
                self.publish()
            } catch { }
        }
        schedule()
    }

    func request(_ range: ClosedRange<Date>?, source: ServerHistoryRequestSource) {
        var days = Set<Date>()
        if let range {
            var day = calendar.startOfDay(for: range.lowerBound)
            let end = min(calendar.startOfDay(for: range.upperBound), calendar.startOfDay(for: Date()))
            while day <= end, days.count < 31 {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        wanted[source] = days
        schedule()
    }

    private func schedule() {
        guard preparation != nil else { return }
        let days = Set(wanted.values.flatMap { $0 })
        for day in requests.keys where !days.contains(day) { requests[day]?.cancel() }
        for day in days.sorted() {
            guard requests[day] == nil, !fetched.contains(day), (retryAfter[day] ?? .distantPast) <= Date() else { continue }
            let generation = generation, preparation = preparation
            requests[day] = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.generation == generation {
                        self.requests.removeValue(forKey: day)
                        if Task.isCancelled { self.schedule() }
                    }
                }
                await preparation?.value
                guard self.generation == generation, !Task.isCancelled else { return }
                do {
                    if let cached = try await self.cache.stopVisits(on: day) {
                        guard self.generation == generation, !Task.isCancelled else { return }
                        self.replace(cached, on: day)
                    }
                    guard let client = self.client,
                          let end = self.calendar.date(byAdding: .day, value: 1, to: day) else {
                        self.fetched.insert(day)
                        return
                    }
                    let visits = try await client.stopVisits(from: day, to: end)
                    guard self.generation == generation, !Task.isCancelled else { return }
                    try await self.cache.storeStopVisits(visits, on: day)
                    guard self.generation == generation, !Task.isCancelled else { return }
                    self.fetched.insert(day)
                    self.replace(visits, on: day)
                } catch {
                    if self.generation == generation, !Task.isCancelled { self.retryAfter[day] = Date().addingTimeInterval(60) }
                }
            }
        }
    }

    private func replace(_ value: [DawarichStopVisit], on day: Date) {
        visits[day] = value
        viewed.removeAll { $0 == day }; viewed.append(day)
        while viewed.count > 90 {
            let removed = viewed.removeFirst()
            visits.removeValue(forKey: removed); fetched.remove(removed)
        }
        publish()
    }

    private func publish() {
        publication &+= 1
        let revision = publication, generation = generation
        let visits = visits, viewed = viewed, places = snapshot.places, calendar = calendar
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // A refreshed empty day must not inherit a stale overnight visit from another cached day.
            let values = viewed.flatMap { day -> [DawarichStopVisit] in
                guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
                return (visits[day] ?? []).compactMap { $0.clipped(from: day, to: end) }
            }
            let names = DawarichStopNames(places: places, visits: values.sorted {
                $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt
            }, days: Set(visits.keys))
            DispatchQueue.main.async {
                guard let self, self.generation == generation, self.publication == revision else { return }
                self.snapshot = names
                self.changed?()
            }
        }
    }

    @discardableResult
    func cancel() -> [Task<Void, Never>] {
        generation &+= 1
        let tasks = Array(requests.values) + (preparation.map { [$0] } ?? []) + (placesRequest.map { [$0] } ?? [])
        for task in tasks { task.cancel() }
        requests.removeAll(); preparation = nil; placesRequest = nil; client = nil
        return tasks
    }

    func reset() -> [Task<Void, Never>] {
        let tasks = cancel()
        wanted.removeAll(); visits.removeAll(); viewed.removeAll(); fetched.removeAll(); retryAfter.removeAll()
        snapshot = DawarichStopNames()
        changed?()
        return tasks
    }
}
