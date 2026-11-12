import SwiftUI

struct HistoryGoToCalendar {
    let calendar: Calendar
    let firstDay: Date?
    let now: Date

    var today: Date { calendar.startOfDay(for: now) }
    var first: Date { min(today, calendar.startOfDay(for: firstDay ?? now)) }

    func contains(_ day: Date) -> Bool { day >= first && day <= today }

    func month(containing date: Date) -> DateInterval { calendar.dateInterval(of: .month, for: date)! }

    func clampedMonth(_ date: Date) -> Date {
        min(month(containing: today).start, max(month(containing: first).start, month(containing: date).start))
    }

    func page(from date: Date, by offset: Int) -> Date? {
        guard let next = calendar.date(byAdding: .month, value: offset, to: month(containing: date).start),
              next >= month(containing: first).start, next <= month(containing: today).start else { return nil }
        return next
    }

    func days(in date: Date) -> [Date] {
        let interval = month(containing: date)
        var day = interval.start
        var days: [Date] = []
        while day < interval.end {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return days
    }

    func leadingDays(in date: Date) -> Int {
        (calendar.component(.weekday, from: month(containing: date).start) - calendar.firstWeekday + 7) % 7
    }

    func window(firstPoint: Date?) -> ClosedRange<Date> {
        guard firstPoint != nil || firstDay != nil else { return now...now }
        let earliest = firstPoint.map { first < calendar.startOfDay(for: $0) ? first : $0 } ?? first
        return min(earliest, now)...now
    }

    func time(on day: Date, preserving time: Date, in window: ClosedRange<Date>) -> Date {
        let clock = calendar.dateComponents([.hour, .minute, .second], from: time)
        // date(bySettingHour:of:) lands a time skipped by spring-forward on the hour; nextDate keeps its minutes.
        let selected = calendar.nextDate(after: calendar.startOfDay(for: day).addingTimeInterval(-1), matching: clock,
                                         matchingPolicy: .nextTimePreservingSmallerComponents) ?? day
        return min(window.upperBound, max(window.lowerBound, selected))
    }

    func journey(on day: Date, in days: [HistoryJourneyDay]) -> HistoryJourneyDay? {
        let start = calendar.startOfDay(for: day)
        return days.first { $0.id == start }
    }

    func title(for date: Date, template: String, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

struct HistoryGoToDay: Identifiable {
    let day: Date
    let summary: HistoryDaySummary?
    let enabled: Bool
    let today: Bool
    let viewing: Bool
    let selected: Bool
    var id: Date { day }
    var notDownloaded: Bool { summary?.state == .notDownloaded }

    init(day: Date, summary: HistoryDaySummary?, selected: Date, viewed: Date?, bounds: HistoryGoToCalendar) {
        self.day = day
        self.summary = summary
        enabled = bounds.contains(day)
        today = bounds.calendar.isDate(day, inSameDayAs: bounds.now)
        viewing = viewed.map { bounds.calendar.isDate(day, inSameDayAs: $0) } ?? false
        self.selected = bounds.calendar.isDate(day, inSameDayAs: selected)
    }

    var markerSize: CGFloat {
        guard let distance = summary?.distance, distance.isFinite else { return 8 }
        return CGFloat(4 + 8 * min(1, log1p(max(0, distance) / 1_000) / log(101)))
    }

    func accessibilityValue(metric: Bool) -> String {
        var parts: [String] = []
        if let summary {
            if let distance = summary.distance { parts.append(ReplayStatus.distanceText(distance, metric: metric)) }
            switch summary.state {
            case .phone: parts.append("On this phone")
            case .server: parts.append("Downloaded from server")
            case .notDownloaded: parts.append("Not downloaded")
            }
        } else { parts.append(enabled ? "No data" : "Unavailable") }
        if today { parts.append("Today") }
        if viewing { parts.append("Viewing") }
        return parts.joined(separator: ", ")
    }
}

struct HistoryGoToView: View {
    var history: HistoryPlaybackModel
    var daySummaries: (any HistoryDaySummaryProvider)?
    var onSelectDay: ((Date) -> Void)?
    var onMonthChange: ((DateInterval) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bridge = GLManagerBridge.shared
    @State private var time: Date
    @State private var month: Date
    @State private var now: Date
    @State private var detent: PresentationDetent = .medium
    @State private var daySelection = 0
    @AccessibilityFocusState(for: .voiceOver) private var dayDetailsFocused: Bool

    init(history: HistoryPlaybackModel, daySummaries: (any HistoryDaySummaryProvider)? = nil,
         onSelectDay: ((Date) -> Void)? = nil, onMonthChange: ((DateInterval) -> Void)? = nil) {
        self.history = history
        self.daySummaries = daySummaries
        self.onSelectDay = onSelectDay
        self.onMonthChange = onMonthChange
        let now = Date()
        let bounds = HistoryGoToCalendar(calendar: .current,
            firstDay: (daySummaries ?? history.daySummaries).firstDay, now: now)
        let window = bounds.window(firstPoint: history.landmarks.timestamps.first)
        let selected = history.rulerTime ?? history.selectedPoint?.timestamp ?? now
        let time = min(window.upperBound, max(window.lowerBound, selected))
        _time = State(initialValue: time)
        _month = State(initialValue: bounds.clampedMonth(time))
        _now = State(initialValue: now)
    }

    private var provider: any HistoryDaySummaryProvider { daySummaries ?? history.daySummaries }
    private var bounds: HistoryGoToCalendar {
        HistoryGoToCalendar(calendar: calendar, firstDay: provider.firstDay, now: now)
    }
    private var window: ClosedRange<Date> { bounds.window(firstPoint: history.landmarks.timestamps.first) }
    private var selectedDay: Date { calendar.startOfDay(for: time) }
    private var selectedSummary: HistoryDaySummary? {
        guard let interval = calendar.dateInterval(of: .day, for: time) else { return nil }
        return provider.summaries(in: interval).first
    }
    private var timeSelection: Binding<Date> { Binding(get: { time }, set: { selectTime($0) }) }

    var body: some View {
        let viewingID = history.landmarks.viewingRow(at: history.playbackIndex)?.id
        let metric = bridge.speedUnit == "KM/H"
        let day = bounds.journey(on: time, in: history.landmarks.journey)
        let summary = selectedSummary
        NavigationStack {
            ScrollViewReader { scroll in
                Form {
                    Section {
                        DisclosureGroup("Exact Date and Time") {
                            DatePicker("Date", selection: timeSelection, in: window, displayedComponents: .date)
                            DatePicker("Time", selection: timeSelection, in: window, displayedComponents: .hourAndMinute)
                        }
                    }
                    .datePickerStyle(.compact)
                    .settingsRowBackground()
                    calendarSection(metric: metric)
                    Section {
                        if let day, !day.rows.isEmpty {
                            ForEach(day.rows) { row in
                                Button {
                                    choose(row) { dismiss() }
                                } label: {
                                    HistoryGoToRow(row: row, metric: metric, viewing: viewingID == row.id)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            Label(summary?.state == .notDownloaded ? "Not downloaded" : "No data for this day",
                                  systemImage: summary?.state == .notDownloaded ? "icloud.and.arrow.down" : "calendar")
                                .foregroundStyle(.secondary)
                                .frame(minHeight: 44)
                        }
                    } header: {
                        HistoryGoToDayHeader(day: day ?? HistoryJourneyDay(id: selectedDay, rows: []),
                                             metric: metric, summary: summary)
                            .id("selectedDay")
                            .accessibilityFocused($dayDetailsFocused)
                    }
                    .settingsRowBackground()
                }
                .settingsFormStyle()
                .onChange(of: daySelection) { _, _ in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        scroll.scrollTo("selectedDay", anchor: .top)
                    }
                    dayDetailsFocused = true
                }
            }
            .navigationTitle("Go To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") {
                        go { dismiss() }
                    }
                    .disabled(history.points.isEmpty || summary?.state == .notDownloaded)
                }
            }
        }
        .environment(\.glassSettingsSheet, true)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackground { ExpandingSheetBackground(detent: detent) }
        .onAppear {
            history.refreshLandmarks()
            onMonthChange?(bounds.month(containing: bounds.clampedMonth(month)))
            onSelectDay?(selectedDay)
        }
        .onChange(of: window) { _, _ in
            time = min(window.upperBound, max(window.lowerBound, time))
            month = bounds.clampedMonth(month)
        }
        .onChange(of: calendar) { _, _ in month = bounds.clampedMonth(time) }
        .onChange(of: month) { _, _ in onMonthChange?(bounds.month(containing: month)) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            now = Date()
        }
    }

    private func calendarSection(metric: Bool) -> some View {
        let month = bounds.clampedMonth(self.month)
        let summaries = Dictionary(provider.summaries(in: bounds.month(containing: month)).map { ($0.day, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let viewed = history.rulerTime ?? history.selectedPoint?.timestamp
        let days = bounds.days(in: month).map {
            HistoryGoToDay(day: $0, summary: summaries[$0], selected: time, viewed: viewed, bounds: bounds)
        }
        return Section {
            VStack(spacing: 8) {
                HStack {
                    monthButton("Previous month", symbol: "chevron.backward", date: bounds.page(from: month, by: -1))
                    Spacer(minLength: 0)
                    Text(bounds.title(for: month, template: "MMMM y", locale: locale))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    monthButton("Next month", symbol: "chevron.forward", date: bounds.page(from: month, by: 1))
                }
                HistoryGoToMonth(days: days, leadingDays: bounds.leadingDays(in: month),
                                 bounds: bounds, metric: metric, select: selectDay)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
        } footer: {
            if days.contains(where: \.notDownloaded) { Text("Dashed rings: Not downloaded") }
        }
        .settingsRowBackground()
    }

    private func monthButton(_ label: String, symbol: String, date: Date?) -> some View {
        Button {
            if let date { month = date }
        } label: {
            Image(systemName: symbol).frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .disabled(date == nil)
    }

    private func selectTime(_ date: Date) {
        let previous = selectedDay
        time = min(window.upperBound, max(window.lowerBound, date))
        month = bounds.clampedMonth(time)
        if previous != selectedDay { onSelectDay?(selectedDay) }
    }

    private func selectDay(_ date: Date) {
        let previous = selectedDay
        selectTime(bounds.time(on: date, preserving: time, in: window))
        if previous == selectedDay { onSelectDay?(selectedDay) }
        detent = .large
        dayDetailsFocused = false
        daySelection &+= 1
    }

    func go(dismiss: () -> Void) {
        guard !history.points.isEmpty, selectedSummary?.state != .notDownloaded else { return }
        history.goTo(min(window.upperBound, max(window.lowerBound, time)))
        dismiss()
    }

    func choose(_ row: HistoryJourneyRow, dismiss: () -> Void) {
        history.scrub(pointAt: row.start)
        dismiss()
    }
}

private struct HistoryGoToMonth: View {
    let days: [HistoryGoToDay]
    let leadingDays: Int
    let bounds: HistoryGoToCalendar
    let metric: Bool
    let select: (Date) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .body) private var dayHeight: CGFloat = 52

    private var weekdays: [String] {
        var calendar = bounds.calendar
        calendar.locale = locale
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize { dayList }
            else {
                ViewThatFits(in: .horizontal) {
                    grid
                    dayList
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 44), spacing: 0), count: 7), spacing: 2) {
            ForEach(0..<7, id: \.self) { index in
                Text(weekdays[index])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            ForEach(0..<leadingDays, id: \.self) { _ in Color.clear.accessibilityHidden(true) }
            ForEach(days) { day in
                dayButton(day) {
                    VStack(spacing: 2) {
                        Text(bounds.title(for: day.day, template: "d", locale: locale))
                            .font(.body.weight(day.today ? .bold : .regular))
                            .foregroundStyle(day.today ? Color.accentColor : Color.primary)
                            .frame(minWidth: 32, minHeight: 30)
                            .overlay { if day.viewing { Capsule().strokeBorder(.tint, lineWidth: 2) } }
                        marker(day).frame(height: 14)
                    }
                    .frame(maxWidth: .infinity, minHeight: max(44, dayHeight))
                }
            }
        }
        .frame(minWidth: 7 * 44)
    }

    private var dayList: some View {
        VStack(spacing: 2) {
            ForEach(days.filter(\.enabled)) { day in
                dayButton(day) {
                    HStack {
                        Text(bounds.title(for: day.day, template: "EEEEd", locale: locale))
                            .fontWeight(day.today ? .bold : .regular)
                        Spacer(minLength: 8)
                        if day.viewing { Text("Viewing").font(.caption).foregroundStyle(.tint) }
                        marker(day)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        }
    }

    private func dayButton<Label: View>(_ day: HistoryGoToDay, @ViewBuilder label: () -> Label) -> some View {
        Button { select(day.day) } label: {
            label()
                .background(day.selected ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .opacity(day.enabled ? 1 : 0.35)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!day.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bounds.title(for: day.day, template: "EEEEyMMMMd", locale: locale))
        .accessibilityValue(day.accessibilityValue(metric: metric))
        .accessibilityHint("Show stops and movements for this day")
        .accessibilityAddTraits(day.selected ? .isSelected : [])
        .accessibilityIdentifier("wherewolf.history.day.\(Int(day.day.timeIntervalSince1970))")
    }

    @ViewBuilder private func marker(_ day: HistoryGoToDay) -> some View {
        if day.notDownloaded {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                .foregroundStyle(.tint)
                .frame(width: day.markerSize, height: day.markerSize)
        } else if day.summary != nil {
            Circle()
                .fill(.tint.opacity(0.4 + 0.6 * Double((day.markerSize - 4) / 8)))
                .frame(width: day.markerSize, height: day.markerSize)
        } else { Color.clear.frame(width: 4, height: 4) }
    }
}

private struct HistoryGoToDayHeader: View {
    let day: HistoryJourneyDay
    let metric: Bool
    var summary: HistoryDaySummary? = nil

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day.id) { return "Today" }
        if calendar.isDateInYesterday(day.id) { return "Yesterday" }
        return day.id.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }

    private var detail: String {
        if summary?.state == .notDownloaded { return "Not downloaded" }
        let stops = day.rows.filter(\.isStop).count
        let distance = summary?.distance ?? day.rows.compactMap(\.distance).reduce(0, +)
        let count = stops == 1 ? "1 stop" : "\(stops) stops"
        return distance > 0 ? "\(count) · \(ReplayStatus.distanceText(distance, metric: metric))" : count
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 8)
                Text(detail).monospacedDigit().textCase(nil)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).monospacedDigit().textCase(nil)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryGoToRow: View {
    let row: HistoryJourneyRow
    let metric: Bool
    let viewing: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
            SettingsIcon(symbol: row.symbol, color: WifiPlace.tint(for: row.color))
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { description; statistics }
            } else {
                description
                Spacer(minLength: 8)
                statistics
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(viewing ? .isSelected : [])
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 2) {
            if dynamicTypeSize.isAccessibilitySize {
                title
                viewingBadge
            } else {
                HStack(spacing: 6) { title; viewingBadge }
            }
            Text(row.timeRange)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var title: some View {
        Text(row.title).font(.body.weight(.medium)).foregroundStyle(.primary)
    }

    @ViewBuilder private var viewingBadge: some View {
        if viewing {
            Text("Viewing")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.15), in: Capsule())
        }
    }

    private var statistics: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
            Text(ReplayActivity.format(row.endTime.timeIntervalSince(row.startTime)))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
            if let distance = row.distance {
                Text(ReplayStatus.distanceText(distance, metric: metric))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
