import SwiftUI
import Charts
import ImageIO

struct DawarichInsightsView: View {
    let connection: DawarichInsightsConnection?
    var active = true
    let onNavigate: (HistoryNavigationRequest) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                heroHeader
                if model.showEmptyState {
                    emptyState
                } else {
                    overviewSection
                    detailsSection
                    countriesSection
                    citiesSection
                    placesSection
                    visitsSection
                    photosSection
                    digestSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(InsightsPalette.background)
        .tint(InsightsPalette.blue)
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

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            adaptiveRow(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your year in motion").font(.title2.weight(.bold))
                    if !model.serverDescription.isEmpty {
                        Text(model.serverDescription).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !model.years.isEmpty {
                    Menu {
                        Picker("Year", selection: Binding(get: { model.year }, set: { value in
                            photoLimit = 60
                            Task { await model.selectYear(value) }
                        })) {
                            ForEach(model.years, id: \.self) { Text(String($0)).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Text(String(model.year)).monospacedDigit()
                            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(InsightsPalette.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(InsightsPalette.border, lineWidth: 1))
                    }
                    .accessibilityLabel("Year").accessibilityValue(String(model.year))
                    .accessibilityIdentifier("wherewolf.insights.year")
                }
            }
            if model.preview {
                Label("Invented preview data", systemImage: "sparkles")
                    .font(.caption.weight(.medium)).foregroundStyle(InsightsPalette.teal)
            } else if model.snapshot.offline {
                Label("Saved copy", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Insights Yet", systemImage: "chart.bar.xaxis")
        } description: {
            Text(model.emptyMessage)
        } actions: {
            Button("Try Again") { Task { await model.load(connection: connection, force: true) } }
                .buttonStyle(.borderedProminent).disabled(model.loading)
                .accessibilityIdentifier("wherewolf.insights.retry")
        }
        .padding(.vertical, 30)
    }

    @ViewBuilder private var overviewSection: some View {
        let stats = model.snapshot.heroStats
        let months = model.snapshot.months
        let loading = model.state(for: .overview).isLoading
        if !stats.isEmpty {
            heroGrid(stats)
        } else if loading {
            heroGrid(Self.placeholderStats).modifier(InsightsLoading(section: .overview))
        }
        if !months.isEmpty {
            monthCard(months)
        } else if loading {
            monthCard(Self.placeholderMonths(year: model.year)).modifier(InsightsLoading(section: .overview))
        }
        failureRow(.overview)
    }

    private func heroGrid(_ stats: [DawarichInsights.Stat]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 12) {
            ForEach(stats) { InsightsStatTile(stat: $0) }
        }
        .accessibilityIdentifier("wherewolf.insights.overview")
    }

    private func monthCard(_ months: [DawarichInsights.Month]) -> some View {
        InsightsSection(title: "Monthly distance", symbol: "chart.bar.fill") {
            InsightsCard {
                InsightsMonthChart(months: months, onNavigate: onNavigate)
                Divider().padding(.vertical, 4)
                DisclosureGroup {
                    VStack(spacing: 0) {
                        ForEach(months) { month in
                            Button {
                                if let request = month.navigationRequest { onNavigate(request) }
                            } label: {
                                InsightsValueRow(title: month.date.formatted(.dateTime.month(.wide)),
                                                 value: DawarichInsights.distanceText(month.meters / 1_000), chevron: true)
                                    .padding(.vertical, 11).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(month.navigationRequest == nil)
                            .accessibilityLabel(month.accessibilityLabel)
                            .accessibilityHint("Shows this month in Tracker")
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Explore by month").font(.subheadline.weight(.medium))
                }
                .accessibilityIdentifier("wherewolf.insights.months")
            }
        }
    }

    @ViewBuilder private var detailsSection: some View {
        let comparison = model.snapshot.comparison
        let patterns = model.snapshot.details?.travelPatterns
        if let comparison, !comparison.stats.isEmpty {
            InsightsComparisonStrip(stats: comparison.stats, previousYear: comparison.previousYear ?? model.year - 1)
        } else if model.state(for: .details).isLoading {
            InsightsComparisonStrip(stats: Self.placeholderChanges, previousYear: model.year - 1)
                .modifier(InsightsLoading(section: .details))
        }
        if let patterns, !patterns.isEmpty {
            InsightsSection(title: "Travel patterns", symbol: "sun.horizon.fill") {
                InsightsCard {
                    patternRows("Time of Day", symbol: "clock", patterns.timeOfDay?.percentageRows ?? [])
                    patternRows("Days of the Week", symbol: "calendar", patterns.weekdayStats)
                    patternRows("Seasons", symbol: "leaf", patterns.seasonality?.percentageRows ?? [])
                    patternRows("Activities", symbol: "figure.walk", patterns.activityBreakdown?.rows ?? [])
                }
            }
        }
        failureRow(.details)
    }

    @ViewBuilder private func patternRows(_ title: String, symbol: String, _ rows: [DawarichInsights.Stat]) -> some View {
        if !rows.isEmpty {
            DisclosureGroup {
                VStack(spacing: 14) { ForEach(rows) { InsightStatRow(stat: $0) } }.padding(.vertical, 12)
            } label: {
                Label(title, systemImage: symbol).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            }
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder private var countriesSection: some View {
        let countries = countryItems
        let loadingSection: DawarichInsightsSection = model.state(for: .countries).isLoading ? .countries : .residency
        if !countries.isEmpty || model.state(for: .countries).isLoading || model.state(for: .residency).isLoading {
            InsightsSection(title: "Countries", symbol: "globe.europe.africa.fill") {
                if !countries.isEmpty {
                    countryGrid(countries)
                } else {
                    countryGrid(Self.placeholderCountries).modifier(InsightsLoading(section: loadingSection))
                }
                failureRow(.countries)
                failureRow(.residency)
            }
        } else {
            failureRow(.countries)
            failureRow(.residency)
        }
    }

    private var countryItems: [InsightsCountry] {
        let countries = model.snapshot.countries?.countries ?? []
        let residency = model.snapshot.residency?.countries ?? []
        let names = Set(countries.map { $0.name.lowercased() })
        return countries.map { country in
            InsightsCountry(name: country.name, flag: country.flag,
                            days: residency.first { $0.country_name.lowercased() == country.name.lowercased() }?.days)
        } + residency.filter { !names.contains($0.country_name.lowercased()) }.map { country in
            InsightsCountry(name: country.country_name, flag: DawarichInsights.flag(country.country_code ?? ""), days: country.days)
        }
    }

    private func countryGrid(_ countries: [InsightsCountry]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 10) {
            ForEach(countries) { InsightsCountryChip(country: $0) }
        }
        .accessibilityIdentifier("wherewolf.insights.countries")
    }

    @ViewBuilder private var citiesSection: some View {
        let countries = (model.snapshot.cities?.data ?? []).filter { !$0.cities.isEmpty }
        if !countries.isEmpty || model.state(for: .cities).isLoading {
            InsightsSection(title: "Cities", symbol: "building.2.fill") {
                if !countries.isEmpty {
                    InsightsCard {
                        ForEach(Array(countries.enumerated()), id: \.offset) { _, country in
                            cityGroup(country.country, rows: country.cities.map {
                                DawarichInsights.Stat(title: $0.city, value: $0.stayed_for.map(DawarichInsights.duration) ?? "")
                            })
                        }
                    }
                } else {
                    InsightsCard {
                        cityGroup("United Kingdom", rows: [.init(title: "London", value: "12 days")])
                        cityGroup("France", rows: [.init(title: "Paris", value: "5 days")])
                    }
                    .modifier(InsightsLoading(section: .cities))
                }
                failureRow(.cities)
            }
        } else {
            failureRow(.cities)
        }
    }

    private func cityGroup(_ country: String, rows: [DawarichInsights.Stat]) -> some View {
        DisclosureGroup {
            VStack(spacing: 14) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, stat in InsightStatRow(stat: stat) }
            }
            .padding(.vertical, 12)
        } label: {
            Text(country).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder private var placesSection: some View {
        let places = Array(model.snapshot.topPlaces.prefix(10))
        let loading = model.state(for: .places).isLoading || model.state(for: .visits).isLoading
        if !places.isEmpty || loading {
            InsightsSection(title: "Top places by time", symbol: "mappin.and.ellipse") {
                if !places.isEmpty {
                    placesCard(places)
                } else {
                    placesCard(Self.placeholderPlaces)
                        .modifier(InsightsLoading(section: model.state(for: .places).isLoading ? .places : .visits))
                }
                failureRow(.places)
            }
        } else {
            failureRow(.places)
        }
    }

    private func placesCard(_ places: [DawarichInsights.TopPlace]) -> some View {
        InsightsCard {
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                if index > 0 { Divider().padding(.vertical, 2) }
                InsightsPlaceRow(place: place, index: index)
            }
        }
        .accessibilityIdentifier("wherewolf.insights.places")
    }

    @ViewBuilder private var visitsSection: some View {
        let visits = Array(model.snapshot.visits.filter { $0.status != "declined" }.prefix(12))
        if !visits.isEmpty || model.state(for: .visits).isLoading {
            InsightsSection(title: "Recent visits", symbol: "clock.arrow.circlepath") {
                if !visits.isEmpty {
                    InsightsCard {
                        ForEach(Array(visits.enumerated()), id: \.element.id) { index, visit in
                            if index > 0 { Divider().padding(.vertical, 2) }
                            InsightsVisitRow(title: visit.title, date: visit.date, minutes: visit.duration)
                        }
                    }
                } else {
                    InsightsCard {
                        InsightsVisitRow(title: "Riverside Gardens", date: Self.placeholderDate, minutes: 120)
                        Divider().padding(.vertical, 2)
                        InsightsVisitRow(title: "Neighborhood Café", date: Self.placeholderDate, minutes: 60)
                    }
                    .modifier(InsightsLoading(section: .visits))
                }
                failureRow(.visits)
            }
        } else {
            failureRow(.visits)
        }
    }

    @ViewBuilder private var photosSection: some View {
        let photos = Array(model.snapshot.photos.prefix(photoLimit))
        if !photos.isEmpty || model.state(for: .photos).isLoading {
            InsightsSection(title: "Moments along the way", symbol: "photo.on.rectangle.angled") {
                if !photos.isEmpty {
                    let days = Dictionary(grouping: photos, by: \.day)
                    ForEach(days.keys.sorted(by: >), id: \.self) { day in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(DawarichInsights.parseDate(day)?.formatted(date: .abbreviated, time: .omitted) ?? day)
                                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                                ForEach(days[day] ?? [], id: \.identity) { photo in
                                    InsightsPhotoTile(photo: photo, model: model, onNavigate: onNavigate)
                                }
                            }
                        }
                    }
                    if photoLimit < model.snapshot.photos.count {
                        Button("Show More Photos") { photoLimit += 60 }
                            .font(.subheadline.weight(.semibold)).buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 14) {
                        ForEach(0..<4, id: \.self) { _ in
                            InsightsPhotoTile(photo: nil, model: model, onNavigate: onNavigate)
                        }
                    }
                    .modifier(InsightsLoading(section: .photos))
                }
                failureRow(.photos)
            }
            .accessibilityIdentifier("wherewolf.insights.photos")
        } else {
            failureRow(.photos)
        }
    }

    @ViewBuilder private var digestSection: some View {
        if let digest = model.snapshot.digest, model.snapshot.sections.contains("digest") {
            NavigationLink {
                DawarichDigestView(digest: digest)
            } label: {
                InsightsDigestHighlight(year: digest.year, stats: digest.stats,
                                        comparisonText: digest.distance?.comparisonText)
            }
            .buttonStyle(.plain).accessibilityIdentifier("wherewolf.insights.digest")
        } else if model.state(for: .digest).isLoading {
            InsightsDigestHighlight(year: model.year, stats: Self.placeholderStats.filter { $0.title != "Active Days" },
                                    comparisonText: "A look back at the places and journeys that shaped your year.")
                .modifier(InsightsLoading(section: .digest))
        }
        failureRow(.digest)
    }

    @ViewBuilder private func failureRow(_ section: DawarichInsightsSection) -> some View {
        if let failure = model.state(for: section).failure {
            adaptiveRow(alignment: .center, spacing: 12) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(InsightsPalette.blue).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(section.title) couldn’t refresh").font(.subheadline.weight(.medium))
                        Text(failure.message).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Retry") { Task { await model.retry(section) } }
                    .font(.subheadline.weight(.semibold)).buttonStyle(.bordered)
                    .disabled(model.state(for: section).isLoading)
                    .accessibilityLabel("Retry \(section.title)")
            }
            .accessibilityIdentifier("wherewolf.insights.error.\(section.rawValue)")
        }
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    private func adaptiveRow<Content: View>(alignment: VerticalAlignment, spacing: CGFloat,
                                            @ViewBuilder content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
        return layout { content() }
    }

    private static let placeholderStats: [DawarichInsights.Stat] = [
        .init(title: "Distance", value: "12,450 km"), .init(title: "Active Days", value: "248"),
        .init(title: "Countries", value: "8"), .init(title: "Cities", value: "32"),
    ]
    private static let placeholderChanges: [DawarichInsights.Stat] = [
        .init(title: "Distance Change", value: "+24%"), .init(title: "Countries Change", value: "+3"),
        .init(title: "Cities Change", value: "+12"), .init(title: "Days Traveling Change", value: "+18"),
    ]
    private static let placeholderCountries: [InsightsCountry] = [
        .init(name: "United Kingdom", flag: "🇬🇧", days: 184), .init(name: "France", flag: "🇫🇷", days: 24),
        .init(name: "Japan", flag: "🇯🇵", days: 18), .init(name: "Portugal", flag: "🇵🇹", days: 12),
    ]
    private static let placeholderPlaces: [DawarichInsights.TopPlace] = [
        .init(id: "loading-1", name: "Riverside Gardens", minutes: 3_600, visits: 24),
        .init(id: "loading-2", name: "Neighborhood Café", minutes: 1_200, visits: 16),
        .init(id: "loading-3", name: "City Library", minutes: 720, visits: 8),
    ]
    private static let placeholderDate = Date(timeIntervalSince1970: 1_767_225_600)
    private static func placeholderMonths(year: Int) -> [DawarichInsights.Month] {
        [420.0, 680, 560, 920, 1_300, 1_080, 1_600, 1_400, 880, 720, 540, 360].enumerated().map {
            .init(year: year, month: $0.offset + 1, meters: $0.element * 1_000)
        }
    }
}

struct InsightsMonthChart: View {
    let months: [DawarichInsights.Month]
    let onNavigate: (HistoryNavigationRequest) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.redactionReasons) private var redactionReasons
    @State private var selectedMonth: Double?

    /// A chart coordinate can only resolve to a valid month actually returned by the server.
    static func month(at value: Double, in months: [DawarichInsights.Month]) -> DawarichInsights.Month? {
        guard value.isFinite, value >= 0.5, value < 12.5 else { return nil }
        let number = Int(value.rounded())
        return months.first {
            $0.month == number && $0.meters.isFinite && $0.meters >= 0 && $0.navigationRequest != nil
        }
    }

    private var validMonths: [DawarichInsights.Month] {
        months.filter { (1...12).contains($0.month) && $0.meters.isFinite && $0.meters >= 0 && $0.navigationRequest != nil }
    }

    private var highlightedMonth: DawarichInsights.Month? {
        if let selectedMonth, let month = Self.month(at: selectedMonth, in: validMonths) { return month }
        return validMonths.max { lhs, rhs in
            lhs.meters == rhs.meters ? lhs.month < rhs.month : lhs.meters < rhs.meters
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let month = highlightedMonth {
                Button {
                    if let request = month.navigationRequest { onNavigate(request) }
                } label: {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                        : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
                    layout {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(month.date.formatted(.dateTime.month(.wide)))
                                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                            Text(DawarichInsights.distanceText(month.meters / 1_000))
                                .font(.system(.title, design: .rounded, weight: .bold)).foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Label("View month", systemImage: "arrow.up.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(InsightsPalette.blue)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(month.accessibilityLabel)
                .accessibilityHint("Shows this month in Tracker")
            }
            chart
        }
        .onChange(of: months.first?.year) { _, _ in selectedMonth = nil }
    }

    // Split out of body: as one expression the chart exceeded the type checker's time limit.
    private var chart: some View {
        Chart(validMonths) { month in
            BarMark(x: .value("Month", month.month), y: .value("Distance (km)", month.meters / 1_000), width: .ratio(0.68))
                .foregroundStyle(barGradient)
                .cornerRadius(5)
                .opacity(barOpacity(month))
                .accessibilityLabel(month.title)
                .accessibilityValue(DawarichInsights.distanceText(month.meters / 1_000))
        }
        .chartXScale(domain: 0.5...12.5)
        .chartXSelection(value: $selectedMonth)
        .chartXAxis {
            AxisMarks(values: Array(1...12)) { value in
                AxisValueLabel {
                    if let label = value.as(Int.self).flatMap(Self.narrowMonth) {
                        Text(label).font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel().font(.caption2)
            }
        }
        .chartYAxisLabel("km", position: .topLeading)
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 240 : 190)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in tap(at: location, proxy: proxy, geometry: geometry) }
            }
        }
        .accessibilityLabel("Monthly distance")
        .accessibilityIdentifier("wherewolf.insights.monthly")
    }

    private var barGradient: LinearGradient {
        let placeholder = Color.secondary.opacity(0.14)
        let colors = redactionReasons.contains(.placeholder) ? [placeholder, placeholder] : [InsightsPalette.blue, InsightsPalette.teal]
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private func barOpacity(_ month: DawarichInsights.Month) -> Double {
        redactionReasons.contains(.placeholder) || highlightedMonth?.month == month.month ? 1 : 0.65
    }

    private static func narrowMonth(_ month: Int) -> String? {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2025, month: month))?
            .formatted(.dateTime.month(.narrow))
    }

    private func tap(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plot = proxy.plotFrame else { return }
        let frame = geometry[plot]
        guard frame.contains(location),
              let value = proxy.value(atX: location.x - frame.minX, as: Double.self),
              let month = Self.month(at: value, in: validMonths),
              let request = month.navigationRequest else { return }
        selectedMonth = Double(month.month)
        onNavigate(request)
    }
}

private enum InsightsPalette {
    static let blue = adaptive(light: 0x3B82F6, dark: 0x60A5FA)
    static let teal = adaptive(light: 0x0D9488, dark: 0x2DD4BF)
    static let background = adaptive(light: 0xF5F5F3, dark: 0x141414)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x202020)
    static let border = Color.primary.opacity(0.055)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

private struct InsightsSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol).font(.headline)
                .labelStyle(InsightsSectionLabelStyle()).accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct InsightsSectionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(InsightsPalette.teal).accessibilityHidden(true)
            configuration.title.foregroundStyle(.primary)
        }
    }
}

private struct InsightsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 13) { content }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(InsightsPalette.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(InsightsPalette.border, lineWidth: 1))
    }
}

private struct InsightsLoading: ViewModifier {
    let section: DawarichInsightsSection
    func body(content: Content) -> some View {
        content.redacted(reason: .placeholder).disabled(true).allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading \(section.title)").accessibilityRemoveTraits(.isButton)
    }
}

private struct InsightsStatTile: View {
    let stat: DawarichInsights.Stat
    private var symbol: String {
        switch stat.title {
        case "Distance": return "point.topleft.down.to.point.bottomright.curvepath"
        case "Active Days": return "calendar"
        case "Countries": return "globe.europe.africa.fill"
        default: return "building.2.fill"
        }
    }
    private var tint: Color { stat.title == "Distance" || stat.title == "Countries" ? InsightsPalette.blue : InsightsPalette.teal }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbol).font(.system(.body, weight: .semibold)).foregroundStyle(tint)
                .padding(10).background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(stat.value).font(.system(.title, design: .rounded, weight: .bold)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(stat.title).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(17).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(tint.opacity(0.09), lineWidth: 1))
        .accessibilityElement(children: .ignore).accessibilityLabel(stat.accessibilityLabel)
    }
}

private struct InsightsComparisonStrip: View {
    let stats: [DawarichInsights.Stat]
    let previousYear: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compared with \(String(previousYear))").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: direction(stat.value)).font(.caption2.weight(.bold))
                            Text(stat.value).font(.subheadline.weight(.bold)).monospacedDigit()
                        }
                        .foregroundStyle(stat.value.hasPrefix("+") ? InsightsPalette.teal : InsightsPalette.blue)
                        Text(stat.title.replacingOccurrences(of: " Change", with: "")
                            .replacingOccurrences(of: "Days Traveling", with: "Travel days"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore).accessibilityLabel(stat.accessibilityLabel)
                }
            }
        }
        .padding(17).frame(maxWidth: .infinity, alignment: .leading)
        .background(InsightsPalette.teal.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityIdentifier("wherewolf.insights.comparison")
    }

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : (dynamicTypeSize >= .xLarge ? 2 : max(1, stats.count))
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count)
    }

    private func direction(_ value: String) -> String {
        if value.hasPrefix("+") { return "arrow.up.right" }
        if value.hasPrefix("-") || value.hasPrefix("−") { return "arrow.down.right" }
        return "equal"
    }
}

private struct InsightsCountry: Identifiable {
    let name: String
    let flag: String
    let days: Int?
    var id: String { name }
}

private struct InsightsCountryChip: View {
    let country: InsightsCountry
    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            if country.flag.isEmpty {
                Image(systemName: "globe").font(.title2).foregroundStyle(InsightsPalette.teal)
            } else {
                Text(country.flag).font(.title2)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(country.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if let days = country.days { Text("\(days) days").font(.caption).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(InsightsPalette.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(InsightsPalette.border, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(country.name + (country.days.map { ", \($0) days" } ?? ""))
    }
}

private struct InsightsPlaceRow: View {
    let place: DawarichInsights.TopPlace
    let index: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: index == 0 ? "mappin.circle.fill" : "mappin.circle").font(.title2)
                .foregroundStyle(index == 0 ? InsightsPalette.teal : InsightsPalette.blue).accessibilityHidden(true)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                VStack(alignment: .leading, spacing: 5) {
                    Text(place.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("\(place.visits) visits").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(DawarichInsights.duration(place.minutes)).font(.subheadline.weight(.medium)).foregroundStyle(InsightsPalette.teal)
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            }
        }
        .padding(.vertical, 3).accessibilityElement(children: .ignore)
        .accessibilityLabel("\(place.name), \(DawarichInsights.duration(place.minutes)), \(place.visits) visits")
    }
}

private struct InsightsVisitRow: View {
    let title: String
    let date: Date?
    let minutes: Double
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock").font(.subheadline).foregroundStyle(InsightsPalette.teal)
                .padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                if let date {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
                Text(DawarichInsights.duration(minutes)).font(.caption.weight(.medium)).foregroundStyle(InsightsPalette.teal)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3).accessibilityElement(children: .combine)
    }
}

private struct InsightsValueRow: View {
    let title: String
    let value: String
    var chevron = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 14))
        layout {
            Text(title).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Text(value).foregroundStyle(.secondary)
                if chevron {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                }
            }
        }
        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
    }
}

private struct InsightStatRow: View {
    let stat: DawarichInsights.Stat
    var body: some View {
        InsightsValueRow(title: stat.title, value: stat.value)
            .accessibilityElement(children: .ignore).accessibilityLabel(stat.accessibilityLabel)
    }
}

private struct InsightsPhotoTile: View {
    let photo: DawarichInsights.Photo?
    let model: DawarichInsightsModel
    let onNavigate: (HistoryNavigationRequest) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InsightPhotoThumbnail(photo: photo, model: model, onNavigate: onNavigate)
            if let photo, !photo.title.isEmpty {
                Text(photo.title).font(.caption.weight(.medium)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
            } else if photo == nil {
                Text("A place to remember").font(.caption.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InsightPhotoThumbnail: View {
    let photo: DawarichInsights.Photo?
    let model: DawarichInsightsModel
    let onNavigate: (HistoryNavigationRequest) -> Void
    @State private var image: UIImage?
    @State private var failed = false
    @State private var retryRevision = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            if let photo {
                Button {
                    if let date = photo.date { onNavigate(.moment(date)) }
                } label: {
                    imageSurface.overlay(alignment: .bottomTrailing) {
                        if photo.type == "video" {
                            Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.25), radius: 4).padding(10)
                        }
                    }
                }
                .buttonStyle(.plain).disabled(photo.date == nil)
                .accessibilityLabel(photo.accessibilityLabel)
                .accessibilityHint(photo.date == nil ? "" : "Shows this moment in Tracker")
            } else {
                imageSurface.accessibilityHidden(true)
            }
            if failed && image == nil {
                Button { retryRevision += 1 } label: {
                    Label("Retry photo", systemImage: "arrow.clockwise").font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered).background(InsightsPalette.card, in: Capsule()).clipShape(Capsule())
                .padding(10).accessibilityLabel("Retry photo, \(photo?.title ?? "")")
            }
        }
        .task(id: "\(photo?.identity ?? "placeholder")-\(model.thumbnailRevision)-\(retryRevision)") {
            guard let photo, !model.preview else { return }
            failed = false
            let data = await model.thumbnail(photo, force: retryRevision > 0)
            guard !Task.isCancelled else { return }
            guard let data else { failed = true; return }
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
            if let loaded { image = loaded } else { failed = true }
        }
    }

    private var imageSurface: some View {
        GeometryReader { geometry in
            ZStack {
                InsightsPalette.card
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if model.preview, let photo {
                    InsightsPreviewPhoto(identity: photo.identity)
                } else {
                    LinearGradient(colors: [InsightsPalette.blue.opacity(0.08), InsightsPalette.teal.opacity(0.12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .aspectRatio(1.12, contentMode: .fit)
    }
}

private struct InsightsPreviewPhoto: View {
    let identity: String
    private var variation: Int { identity.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 4 }
    private var colors: [Color] {
        switch variation {
        case 0: return [Color(red: 0.30, green: 0.63, blue: 0.80), Color(red: 0.09, green: 0.38, blue: 0.48)]
        case 1: return [Color(red: 0.91, green: 0.68, blue: 0.47), Color(red: 0.61, green: 0.33, blue: 0.38)]
        case 2: return [Color(red: 0.51, green: 0.69, blue: 0.59), Color(red: 0.16, green: 0.39, blue: 0.35)]
        default: return [Color(red: 0.54, green: 0.60, blue: 0.80), Color(red: 0.28, green: 0.32, blue: 0.55)]
        }
    }
    private var symbol: String { ["mountain.2.fill", "building.2.fill", "leaf.fill", "sailboat.fill"][variation] }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.white.opacity(0.20)).frame(width: geometry.size.width * 0.55)
                    .offset(x: geometry.size.width * 0.33, y: -geometry.size.height * 0.30)
                Image(systemName: symbol).resizable().scaledToFit().foregroundStyle(.white.opacity(0.82))
                    .frame(width: geometry.size.width * 0.62, height: geometry.size.height * 0.56)
                    .rotationEffect(.degrees(variation == 2 ? -18 : 0)).offset(y: geometry.size.height * 0.08)
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }
}

private struct InsightsDigestHighlight: View {
    let year: Int
    let stats: [DawarichInsights.Stat]
    let comparisonText: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(InsightsPalette.teal).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text("Your \(String(year)) in review").font(.title2.weight(.bold)).foregroundStyle(.primary)
                if let comparisonText, !comparisonText.isEmpty {
                    Text(comparisonText).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            let layout = dynamicTypeSize >= .xxLarge
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            layout {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(stat.value).font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(.primary)
                        Text(stat.title).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore).accessibilityLabel(stat.accessibilityLabel)
                }
            }
            Label("Explore your digest", systemImage: "arrow.right")
                .font(.subheadline.weight(.semibold)).foregroundStyle(InsightsPalette.blue)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [InsightsPalette.blue.opacity(0.11), InsightsPalette.teal.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(InsightsPalette.blue.opacity(0.09), lineWidth: 1))
        .accessibilityElement(children: .combine)
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
                Section("All Time") { ForEach(stats) { InsightStatRow(stat: $0) } }
            }
            valueSection("Time of Day", digest.travelPatterns?.timeOfDay, percentages: true)
            valueSection("Seasons", digest.travelPatterns?.seasonality, percentages: true)
            valueSection("Activities", digest.travelPatterns?.activityBreakdown)
        }
        .listStyle(.insetGrouped).tint(InsightsPalette.blue)
        .navigationTitle("\(String(digest.year)) Digest").navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func valueSection(_ title: String, _ value: DawarichInsights.Value?, percentages: Bool = false) -> some View {
        if let rows = percentages ? value?.percentageRows : value?.rows, !rows.isEmpty {
            Section(title) { ForEach(Array(rows.enumerated()), id: \.offset) { _, row in InsightStatRow(stat: row) } }
        }
    }
}
