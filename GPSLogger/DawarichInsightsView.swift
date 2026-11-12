import SwiftUI
import Charts
import ImageIO

struct DawarichInsightsView: View {
    let connection: DawarichInsightsConnection?
    var active = true
    let onNavigate: (HistoryNavigationRequest) -> Void
    @State private var model: DawarichInsightsModel
    @State private var photoLimit = 60

    init(connection: DawarichInsightsConnection?, active: Bool = true, preview: Bool = false,
         onNavigate: @escaping (HistoryNavigationRequest) -> Void) {
        self.connection = connection
        self.active = active
        self.onNavigate = onNavigate
        _model = State(initialValue: DawarichInsightsModel(preview: preview))
    }

    var body: some View {
        List {
            if model.preview {
                Section { Label("Invented preview data", systemImage: "sparkles") }
            }
            if !model.years.isEmpty {
                Section {
                    Picker("Year", selection: Binding(get: { model.year }, set: { value in
                        photoLimit = 60
                        Task { await model.selectYear(value) }
                    })) {
                        ForEach(model.years, id: \.self) { Text(String($0)).tag($0) }
                    }
                    .accessibilityIdentifier("wherewolf.insights.year")
                }
            }
            if model.loading && model.snapshot.sections.isEmpty {
                Section { ProgressView("Loading Insights…") }
            } else if model.snapshot.sections.isEmpty {
                Section {
                    ContentUnavailableView(model.snapshot.offline ? "Insights Unavailable Offline" : "No Insights Available",
                        systemImage: "chart.bar.xaxis",
                        description: Text(model.snapshot.offline ? "Connect to your Dawarich server, then pull to refresh."
                            : "Available sections appear here when your server has data for them."))
                }
            }
            yearSection
            comparisonSection
            patternsSection
            countriesSection
            citiesSection
            placesSection
            visitsSection
            photosSection
            digestSection
            Section {
                if let updated = model.snapshot.updated {
                    LabeledContent(model.snapshot.offline ? "Saved Copy Updated" : "Updated") {
                        Text(updated, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
                if model.snapshot.offline {
                    Label("Some sections could not refresh. Saved data is shown where available.", systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Read-only insights from your Dawarich server. Pull to refresh.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("wherewolf.insights")
        .refreshable { await model.load(connection: connection, force: true) }
        .task(id: active ? connection?.id ?? (model.preview ? "preview" : "") : "inactive") {
            guard active else { return }
            await model.load(connection: connection)
        }
        .onReceive(NotificationCenter.default.publisher(for: DawarichInsightsCache.cleared).receive(on: RunLoop.main)) { _ in
            model.clearPresentation()
        }
    }

    @ViewBuilder private var yearSection: some View {
        if model.snapshot.sections.contains("year") {
            Section(String(model.year)) {
                ForEach(model.snapshot.overview?.stats ?? []) { InsightStatRow(stat: $0) }
                if !model.snapshot.months.isEmpty {
                    InsightsMonthChart(months: model.snapshot.months, onNavigate: onNavigate)
                        .padding(.vertical, 8)
                    DisclosureGroup("Monthly Distances") {
                        ForEach(model.snapshot.months) { month in
                            Button { showMonth(month) } label: {
                                LabeledContent(month.date.formatted(.dateTime.month(.wide)),
                                               value: DawarichInsights.distanceText(month.meters / 1_000))
                            }
                            .accessibilityLabel(month.accessibilityLabel)
                            .accessibilityHint("Shows this month in Tracker")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var comparisonSection: some View {
        if let comparison = model.snapshot.details?.comparison, !comparison.stats.isEmpty {
            Section("Compared with \(String(comparison.previousYear ?? model.year - 1))") {
                ForEach(comparison.stats) { InsightStatRow(stat: $0) }
            }
        }
    }

    @ViewBuilder private var countriesSection: some View {
        if model.snapshot.sections.contains("countries") {
            Section("Countries") {
                ForEach(model.snapshot.countries?.countries ?? []) { country in
                    let days = model.snapshot.residency?.countries.first { $0.country_name == country.name }?.days
                    countryRow(name: country.name, flag: country.flag, days: days)
                }
                let names = Set((model.snapshot.countries?.countries ?? []).map(\.name))
                ForEach(Array((model.snapshot.residency?.countries ?? []).enumerated()), id: \.offset) { _, country in
                    if !names.contains(country.country_name) {
                        countryRow(name: country.country_name, flag: DawarichInsights.flag(country.country_code ?? ""), days: country.days)
                    }
                }
            }
        }
    }

    @ViewBuilder private var patternsSection: some View {
        if let patterns = model.snapshot.details?.travelPatterns, !patterns.isEmpty {
            Section("Travel Patterns") {
                patternRows("Time of Day", patterns.timeOfDay?.percentageRows ?? [])
                patternRows("Days of the Week", patterns.weekdayStats)
                patternRows("Seasons", patterns.seasonality?.percentageRows ?? [])
                patternRows("Activities", patterns.activityBreakdown?.rows ?? [])
            }
        }
    }

    @ViewBuilder private func patternRows(_ title: String, _ rows: [DawarichInsights.Stat]) -> some View {
        if !rows.isEmpty {
            DisclosureGroup(title) { ForEach(rows) { InsightStatRow(stat: $0) } }
        }
    }

    private func countryRow(name: String, flag: String, days: Int?) -> some View {
        LabeledContent {
            if let days { Text("\(days) days").foregroundStyle(.secondary) }
        } label: { Text(flag.isEmpty ? name : flag + " " + name) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name + (days.map { ", \($0) days" } ?? ""))
    }

    @ViewBuilder private var citiesSection: some View {
        if model.snapshot.sections.contains("cities") {
            Section("Cities") {
                ForEach(Array((model.snapshot.cities?.data ?? []).enumerated()), id: \.offset) { _, country in
                    if !country.cities.isEmpty {
                        DisclosureGroup(country.country) {
                            ForEach(Array(country.cities.enumerated()), id: \.offset) { _, city in
                                LabeledContent(city.city, value: city.stayed_for.map(DawarichInsights.duration) ?? "")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var placesSection: some View {
        if model.snapshot.sections.contains("places") {
            Section("Top Places by Time") {
                ForEach(model.snapshot.topPlaces.prefix(10)) { place in
                    LabeledContent {
                        VStack(alignment: .trailing) {
                            Text(DawarichInsights.duration(place.minutes))
                            Text("\(place.visits) visits").font(.caption)
                        }.foregroundStyle(.secondary)
                    } label: { Text(place.name) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(place.name), \(DawarichInsights.duration(place.minutes)), \(place.visits) visits")
                }
            }
        }
    }

    @ViewBuilder private var visitsSection: some View {
        if model.snapshot.sections.contains("visits") {
            Section("Recent Visits") {
                ForEach(model.snapshot.visits.prefix(12)) { visit in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(visit.title)
                        if let date = visit.date {
                            Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.subheadline)
                        }
                        Text(DawarichInsights.duration(visit.duration)).font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder private var photosSection: some View {
        if model.snapshot.sections.contains("photos") {
            Section("Photos") {
                let days = Dictionary(grouping: Array(model.snapshot.photos.prefix(photoLimit)), by: \.day)
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(DawarichInsights.parseDate(day)?.formatted(date: .abbreviated, time: .omitted) ?? day)
                            .font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                            ForEach(days[day] ?? [], id: \.identity) { photo in
                                Button {
                                    if let date = photo.date { onNavigate(.moment(date)) }
                                } label: {
                                    InsightPhotoThumbnail(photo: photo, model: model)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(photo.accessibilityLabel)
                                .accessibilityHint("Shows this moment in Tracker")
                            }
                        }
                    }.padding(.vertical, 4)
                }
                if photoLimit < model.snapshot.photos.count {
                    Button("Show More Photos") { photoLimit += 60 }
                }
            }
        }
    }

    @ViewBuilder private var digestSection: some View {
        if model.snapshot.sections.contains("digest"), let digest = model.snapshot.digest {
            Section("Yearly Digest") {
                ForEach(digest.stats) { InsightStatRow(stat: $0) }
                if let text = digest.distance?.comparisonText, !text.isEmpty { Text(text).foregroundStyle(.secondary) }
                NavigationLink("Explore \(String(digest.year)) Digest") { DawarichDigestView(digest: digest) }
            }
        }
    }

    private func showMonth(_ month: DawarichInsights.Month) {
        if let request = HistoryNavigationRequest.month(year: month.year, month: month.month) { onNavigate(request) }
    }
}

struct InsightsMonthChart: View {
    let months: [DawarichInsights.Month]
    let onNavigate: (HistoryNavigationRequest) -> Void

    var body: some View {
        Chart(months) { month in
            BarMark(x: .value("Month", month.month), y: .value("Distance (km)", month.meters / 1_000))
                .foregroundStyle(.blue.gradient)
                .accessibilityLabel(month.title)
                .accessibilityValue(DawarichInsights.distanceText(month.meters / 1_000))
        }
        .chartXScale(domain: 0.5...12.5)
        .chartXAxis {
            AxisMarks(values: Array(1...12)) { value in
                AxisValueLabel {
                    if let month = value.as(Int.self), let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2025, month: month)) {
                        Text(date.formatted(.dateTime.month(.narrow)))
                    }
                }
            }
        }
        .chartYAxisLabel("km")
        .frame(height: 190)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        let x = location.x - geometry[plot].minX
                        guard x >= 0, x <= geometry[plot].width, let value = proxy.value(atX: x, as: Double.self),
                              let month = months.first(where: { $0.month == Int(value.rounded()) }),
                              let request = HistoryNavigationRequest.month(year: month.year, month: month.month) else { return }
                        onNavigate(request)
                    }
            }
        }
        .accessibilityLabel("Monthly distance")
        .accessibilityIdentifier("wherewolf.insights.monthly")
    }
}

private struct InsightStatRow: View {
    let stat: DawarichInsights.Stat
    var body: some View {
        LabeledContent(stat.title, value: stat.value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stat.accessibilityLabel)
    }
}

private struct InsightPhotoThumbnail: View {
    let photo: DawarichInsights.Photo
    let model: DawarichInsightsModel
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: model.preview ? "photo.artframe" : "photo")
                        .font(.title2)
                    if model.preview { Text("Sample").font(.caption) }
                }.foregroundStyle(.secondary)
            }
        }
        .frame(height: 104).frame(maxWidth: .infinity)
        .clipped().clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: "\(photo.identity)-\(model.thumbnailRevision)") {
            let data = await model.thumbnail(photo)
            guard let data, !Task.isCancelled else { return }
            let loaded = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 480,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                      ] as CFDictionary) else { return UIImage?.none }
                return UIImage(cgImage: image)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

private struct DawarichDigestView: View {
    let digest: DawarichInsights.Digest
    var body: some View {
        List {
            Section("Year Overview") {
                ForEach(digest.stats) { InsightStatRow(stat: $0) }
                if let text = digest.distance?.comparisonText { Text(text) }
            }
            if let countries = digest.toponyms?.countries, !countries.isEmpty {
                Section("Countries and Cities") {
                    ForEach(Array(countries.enumerated()), id: \.offset) { _, country in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(country.country)
                            if let cities = country.cities, !cities.isEmpty {
                                Text(cities.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            valueSection("Time Spent", digest.timeSpentByLocation)
            valueSection("First Visits", digest.firstTimeVisits)
            if let comparison = digest.yearOverYear, !comparison.stats.isEmpty {
                Section("Year over Year") { ForEach(comparison.stats) { InsightStatRow(stat: $0) } }
            }
            if let stats = digest.allTimeStats?.stats, !stats.isEmpty {
                Section("All Time") {
                    ForEach(stats) { InsightStatRow(stat: $0) }
                }
            }
            valueSection("Time of Day", digest.travelPatterns?.timeOfDay, percentages: true)
            valueSection("Seasons", digest.travelPatterns?.seasonality, percentages: true)
            valueSection("Activities", digest.travelPatterns?.activityBreakdown)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("\(String(digest.year)) Digest")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func valueSection(_ title: String, _ value: DawarichInsights.Value?, percentages: Bool = false) -> some View {
        if let rows = percentages ? value?.percentageRows : value?.rows, !rows.isEmpty {
            Section(title) { ForEach(Array(rows.enumerated()), id: \.offset) { _, row in InsightStatRow(stat: row) } }
        }
    }
}
