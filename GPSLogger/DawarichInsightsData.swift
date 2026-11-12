import Foundation

// Only the presentation fields are decoded; server coordinates never enter replay or uploads here.
enum DawarichInsights {
    struct TrackedYear: Decodable { let year: Int; let months: [String] }
    struct Overview: Decodable {
        let year: Int
        let availableYears: [Int]?
        let totals: Totals?
        let activityHeatmap: Heatmap?
        struct Totals: Decodable {
            let totalDistance: Double?
            let distanceUnit: String?
            let countriesCount: Int?
            let citiesCount: Int?
            let countriesList: [String]?
            let daysTraveling: Double?
        }
        struct Heatmap: Decodable {
            let dailyData: [String: Double]?
            let activeDays: Int?
            let currentStreak: Int?
            let longestStreak: Int?
        }
        var stats: [Stat] {
            var result: [Stat] = []
            if let distance = totals?.totalDistance, distance > 0 {
                result.append(Stat(title: "Distance", value: distanceText(distance, unit: totals?.distanceUnit ?? "km")))
            }
            result += [Stat.count("Active Days", activityHeatmap?.activeDays),
                       Stat.count("Countries", totals?.countriesCount), Stat.count("Cities", totals?.citiesCount),
                       Stat.count("Longest Streak", activityHeatmap?.longestStreak, suffix: " days"),
                       Stat.count("Current Streak", activityHeatmap?.currentStreak, suffix: " days")].compactMap { $0 }
            if let days = totals?.daysTraveling, days > 0 {
                result.append(Stat(title: "Days Traveling", value: number(days)))
            }
            return result
        }
        var months: [Month] {
            var totals: [Int: Double] = [:]
            for (day, meters) in activityHeatmap?.dailyData ?? [:] where meters.isFinite && meters >= 0 {
                let parts = day.split(separator: "-")
                guard parts.count == 3, Int(parts[0]) == year, let month = Int(parts[1]),
                      (1...12).contains(month) else { continue }
                totals[month, default: 0] += meters
            }
            guard totals.values.contains(where: { $0 > 0 }) else { return [] }
            return totals.keys.sorted().map { Month(year: year, month: $0, meters: totals[$0]!) }
        }
    }
    struct Details: Decodable {
        let year: Int
        let comparison: Comparison?
        let travelPatterns: Patterns?
    }
    struct Comparison: Decodable {
        let previousYear: Int?
        let distanceChangePercent: Double?
        let countriesChange: Int?
        let citiesChange: Int?
        let daysChange: Double?
        var stats: [Stat] {
            var result: [Stat] = []
            if let value = distanceChangePercent {
                result.append(Stat(title: "Distance Change", value: signed(value) + "%"))
            }
            if let value = countriesChange { result.append(Stat(title: "Countries Change", value: signed(Double(value)))) }
            if let value = citiesChange { result.append(Stat(title: "Cities Change", value: signed(Double(value)))) }
            if let value = daysChange { result.append(Stat(title: "Days Traveling Change", value: signed(value))) }
            return result
        }
    }
    struct Patterns: Decodable {
        let timeOfDay: Value?
        let dayOfWeek: [Double]?
        let seasonality: Value?
        let activityBreakdown: Value?
        let topVisitedLocations: [TopLocation]?
        struct TopLocation: Decodable {
            let name: String
            let visitCount: Int?
            let totalDuration: Double?
        }
        var weekdayStats: [Stat] {
            guard let values = dayOfWeek, values.count == 7, values.contains(where: { $0 > 0 }) else { return [] }
            let names = Calendar.current.weekdaySymbols
            return values.enumerated().map {
                Stat(title: names[($0.offset + 1) % 7], value: DawarichInsights.distanceText($0.element / 1_000))
            }
        }
        var isEmpty: Bool {
            (timeOfDay?.rows.isEmpty ?? true) && (seasonality?.rows.isEmpty ?? true)
                && (activityBreakdown?.rows.isEmpty ?? true) && weekdayStats.isEmpty
        }
    }
    struct Countries: Decodable {
        let countries: [Country]
        struct Country: Decodable, Identifiable {
            let iso_a3: String
            let name: String
            var id: String { iso_a3 }
            var flag: String { DawarichInsights.flag(iso_a3) }
        }
    }
    struct Cities: Decodable {
        let data: [Country]
        struct Country: Decodable {
            let country: String
            let cities: [City]
        }
        struct City: Decodable {
            let city: String
            let points: Int?
            let timestamp: Double?
            let stayed_for: Double?
        }
    }
    struct Residency: Decodable {
        let year: Int?
        let countries: [Country]
        let available_years: [Int]?
        struct Country: Decodable {
            let country_name: String
            let country_code: String?
            let days: Int
        }
    }
    struct Place: Decodable, Identifiable {
        let id: Int
        let name: String
        let archived: Bool?
        let visits_count: Int?
    }
    struct Visit: Decodable, Identifiable {
        let id: Int
        let name: String
        let display_name: String?
        let place_id: Int?
        let status: String
        let started_at: String
        let ended_at: String
        let duration: Double
        let place: Reference?
        struct Reference: Decodable { let id: Int?; let name: String? }
        var date: Date? { parseDate(started_at) }
        var title: String { display_name ?? name }
    }
    struct Photo: Decodable, Identifiable {
        let id: String
        let source: String
        let localDateTime: String
        let capturedAt: String?
        let city: String?
        let country: String?
        let type: String?
        var identity: String { source + ":" + id }
        var date: Date? { capturedAt.flatMap(parseDate) ?? parseDate(localDateTime) }
        var day: String { String(localDateTime.prefix(10)) }
        var title: String { [city, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }
        var accessibilityLabel: String {
            let when = date?.formatted(date: .abbreviated, time: .shortened) ?? day
            return "\(type == "video" ? "Video" : "Photo"), \(title.isEmpty ? when : title + ", " + when)"
        }
    }
    struct DigestList: Decodable {
        let digests: [Entry]
        let availableYears: [Int]?
        struct Entry: Decodable {
            let year: Int
            let distance: Value?
            let countriesCount: Int?
            let citiesCount: Int?
        }
    }
    struct Digest: Decodable {
        let year: Int
        let distance: Distance?
        let toponyms: Toponyms?
        let monthlyDistances: [String: Double]?
        let timeSpentByLocation: Value?
        let firstTimeVisits: Value?
        let yearOverYear: Comparison?
        let allTimeStats: AllTime?
        let travelPatterns: Patterns?
        let createdAt: String?
        struct Distance: Decodable { let meters: Double?; let converted: Double?; let unit: String?; let comparisonText: String? }
        struct Toponyms: Decodable {
            let countriesCount: Int?
            let citiesCount: Int?
            let countries: [Country]?
            struct Country: Decodable { let country: String; let cities: [String]? }
        }
        struct AllTime: Decodable {
            let totalCountries: Int?
            let totalCities: Int?
            let totalDistance: String?
            var stats: [Stat] {
                var result = [Stat.count("Countries", totalCountries), Stat.count("Cities", totalCities)].compactMap { $0 }
                if let text = totalDistance, let meters = Double(text), meters.isFinite, meters > 0 {
                    result.append(Stat(title: "Distance", value: DawarichInsights.distanceText(meters / 1_000)))
                }
                return result
            }
        }
        var months: [Month] {
            let names = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
            guard monthlyDistances?.values.contains(where: { $0 > 0 }) == true else { return [] }
            return names.enumerated().compactMap { index, name in
                guard let meters = monthlyDistances?[name], meters.isFinite, meters >= 0 else { return nil }
                return Month(year: year, month: index + 1, meters: meters)
            }
        }
        var stats: [Stat] {
            var result: [Stat] = []
            if let meters = distance?.meters, meters > 0 { result.append(Stat(title: "Distance", value: distanceText(meters / 1_000))) }
            result += [Stat.count("Countries", toponyms?.countriesCount), Stat.count("Cities", toponyms?.citiesCount)].compactMap { $0 }
            return result
        }
    }

    // These objects are intentionally open in the spec. Keep their hierarchy and literal units.
    enum Value: Decodable {
        case number(Double), string(String), bool(Bool), array([Value]), object([String: Value]), null
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let v = try? value.decode(Double.self) { self = .number(v) }
            else if let v = try? value.decode(String.self) { self = .string(v) }
            else if let v = try? value.decode(Bool.self) { self = .bool(v) }
            else if let v = try? value.decode([Value].self) { self = .array(v) }
            else { self = .object(try value.decode([String: Value].self)) }
        }
        var rows: [Stat] { rows(prefix: "", percentages: false) }
        var percentageRows: [Stat] { rows(prefix: "", percentages: true) }
        private func rows(prefix: String, percentages: Bool) -> [Stat] {
            switch self {
            case .null: return []
            case .number(let n):
                guard n.isFinite, n != 0 else { return [] }
                let field = prefix.lowercased()
                let text: String
                if field.hasSuffix("minutes") { text = DawarichInsights.duration(n) }
                else if field.hasSuffix("duration") { text = DawarichInsights.duration(n / 60) }
                else if field.hasSuffix("distance") { text = DawarichInsights.distanceText(n / 1_000) }
                else { text = DawarichInsights.number(n) + (percentages || field.hasSuffix("percentage") ? "%" : "") }
                return [Stat(title: prefix, value: text)]
            case .string(let text): return text.isEmpty ? [] : [Stat(title: prefix, value: text)]
            case .bool(let value): return [Stat(title: prefix, value: value ? "Yes" : "No")]
            case .array(let values):
                let names = values.compactMap { if case .string(let name) = $0 { return name }; return String?.none }
                if names.count == values.count { return names.isEmpty ? [] : [Stat(title: prefix, value: names.joined(separator: ", "))] }
                return values.enumerated().flatMap { $0.element.rows(prefix: prefix + " \($0.offset + 1)", percentages: percentages) }
            case .object(let values):
                if let nameValue = values["name"], case .string(let name) = nameValue,
                   let timeValue = values["minutes"], case .number(let minutes) = timeValue {
                    return [Stat(title: name, value: DawarichInsights.duration(minutes))]
                }
                return values.keys.sorted().flatMap { key in
                    let title = key.replacingOccurrences(of: "_", with: " ").capitalized
                    return values[key]!.rows(prefix: prefix.isEmpty ? title : prefix + " · " + title, percentages: percentages)
                }
            }
        }
    }
    struct Stat: Identifiable {
        let title: String
        let value: String
        var id: String { title }
        var accessibilityLabel: String { title + ", " + value }
        static func count(_ title: String, _ value: Int?, suffix: String = "") -> Stat? {
            guard let value, value > 0 else { return nil }
            return Stat(title: title, value: value.formatted() + suffix)
        }
    }
    struct Month: Identifiable {
        let year: Int
        let month: Int
        let meters: Double
        var id: Int { month }
        var date: Date { Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: 1))! }
        var title: String { date.formatted(.dateTime.month(.wide).year()) }
        var accessibilityLabel: String { title + ", " + distanceText(meters / 1_000) }
    }
    struct TopPlace: Identifiable {
        let id: String
        let name: String
        let minutes: Double
        let visits: Int
    }
    struct Snapshot {
        var overview: Overview?
        var details: Details?
        var countries: Countries?
        var cities: Cities?
        var residency: Residency?
        var places: [Place] = []
        var visits: [Visit] = []
        var photos: [Photo] = []
        var digest: Digest?
        var updated: Date?
        var offline = false
        private var preparedTopPlaces: [TopPlace]?

        init() { }
        mutating func prepare() { preparedTopPlaces = topPlaces }
        var months: [Month] {
            let recorded = overview?.months ?? []
            return recorded.isEmpty ? digest?.months ?? [] : recorded
        }
        var topPlaces: [TopPlace] {
            if let preparedTopPlaces { return preparedTopPlaces }
            let names = Dictionary(places.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let groups = Dictionary(grouping: visits.filter { $0.status != "declined" && $0.duration > 0 }) {
                ($0.place_id ?? $0.place?.id).map(String.init) ?? "name:" + $0.title
            }
            return groups.map { key, visits in
                let first = visits[0]
                let name = (first.place_id ?? first.place?.id).flatMap { names[$0] } ?? first.place?.name ?? first.title
                return TopPlace(id: key, name: name, minutes: visits.reduce(0) { $0 + $1.duration }, visits: visits.count)
            }.sorted { $0.minutes == $1.minutes ? $0.id < $1.id : $0.minutes > $1.minutes }
        }
        var sections: Set<String> {
            var result = Set<String>()
            if !(overview?.stats.isEmpty ?? true) || !months.isEmpty { result.insert("year") }
            if !(details?.comparison?.stats.isEmpty ?? true) { result.insert("comparison") }
            if details?.travelPatterns?.isEmpty == false { result.insert("patterns") }
            if !(countries?.countries.isEmpty ?? true) || !(residency?.countries.isEmpty ?? true) { result.insert("countries") }
            if cities?.data.contains(where: { !$0.cities.isEmpty }) == true { result.insert("cities") }
            if !topPlaces.isEmpty { result.insert("places") }
            if visits.contains(where: { $0.status != "declined" }) { result.insert("visits") }
            if !photos.isEmpty { result.insert("photos") }
            if let digest, !digest.stats.isEmpty || !digest.months.isEmpty { result.insert("digest") }
            return result
        }
    }

    static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
    static func signed(_ value: Double) -> String { (value > 0 ? "+" : "") + number(value) }
    static func distanceText(_ value: Double, unit: String = "km") -> String { number(value) + " " + unit }
    static func duration(_ minutes: Double) -> String {
        let value = max(0, minutes)
        if value >= 1_440 { return number(value / 1_440) + " days" }
        if value >= 60 { return number(value / 60) + " hours" }
        return number(value) + " minutes"
    }
    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        // Older photo integrations return a local wall-clock value with no offset.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }
    static func flag(_ code: String) -> String {
        let code = code.uppercased()
        let region = code.count == 3 ? regionCodes[code] : code
        guard let region, region.count == 2, region.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) else { return "" }
        return String(String.UnicodeScalarView(region.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }))
    }
    // ISO alpha-3 aliases from Unicode CLDR; flags need alpha-2 region codes.
    private static let regionCodes: [String: String] = {
        let aliases = "AAA:AA ABW:AW AFG:AF AGO:AO AIA:AI ALA:AX ALB:AL AND:AD ARE:AE ARG:AR ARM:AM ASC:AC ASM:AS ATA:AQ ATF:TF ATG:AG AUS:AU AUT:AT AZE:AZ BDI:BI BEL:BE BEN:BJ BES:BQ BFA:BF BGD:BD BGR:BG BHR:BH BHS:BS BIH:BA BLM:BL BLR:BY BLZ:BZ BMU:BM BOL:BO BRA:BR BRB:BB BRN:BN BTN:BT BUR:MM BVT:BV BWA:BW CAF:CF CAN:CA CCK:CC CHE:CH CHL:CL CHN:CN CIV:CI CMR:CM COD:CD COG:CG COK:CK COL:CO COM:KM CPT:CP CPV:CV CRI:CR CUB:CU CUW:CW CXR:CX CYM:KY CYP:CY CZE:CZ DDR:DE DEU:DE DGA:DG DJI:DJ DMA:DM DNK:DK DOM:DO DZA:DZ ECU:EC EGY:EG ERI:ER ESH:EH ESP:ES EST:EE ETH:ET FIN:FI FJI:FJ FLK:FK FRA:FR FRO:FO FSM:FM FXX:FR GAB:GA GBR:GB GEO:GE GGY:GG GHA:GH GIB:GI GIN:GN GLP:GP GMB:GM GNB:GW GNQ:GQ GRC:GR GRD:GD GRL:GL GTM:GT GUF:GF GUM:GU GUY:GY HKG:HK HMD:HM HND:HN HRV:HR HTI:HT HUN:HU IDN:ID IMN:IM IND:IN IOT:IO IRL:IE IRN:IR IRQ:IQ ISL:IS ISR:IL ITA:IT JAM:JM JEY:JE JOR:JO JPN:JP KAZ:KZ KEN:KE KGZ:KG KHM:KH KIR:KI KNA:KN KOR:KR KWT:KW LAO:LA LBN:LB LBR:LR LBY:LY LCA:LC LIE:LI LKA:LK LSO:LS LTU:LT LUX:LU LVA:LV MAC:MO MAF:MF MAR:MA MCO:MC MDA:MD MDG:MG MDV:MV MEX:MX MHL:MH MKD:MK MLI:ML MLT:MT MMR:MM MNE:ME MNG:MN MNP:MP MOZ:MZ MRT:MR MSR:MS MTQ:MQ MUS:MU MWI:MW MYS:MY MYT:YT NAM:NA NCL:NC NER:NE NFK:NF NGA:NG NIC:NI NIU:NU NLD:NL NOR:NO NPL:NP NRU:NR NZL:NZ OMN:OM PAK:PK PAN:PA PCN:PN PER:PE PHL:PH PLW:PW PNG:PG POL:PL PRI:PR PRK:KP PRT:PT PRY:PY PSE:PS PYF:PF QAT:QA QMM:QM QNN:QN QPP:QP QQQ:QQ QRR:QR QSS:QS QTT:QT QUU:EU QVV:QV QWW:QW QXX:QX QYY:QY QZZ:QZ REU:RE ROU:RO RUS:RU RWA:RW SAU:SA SDN:SD SEN:SN SGP:SG SGS:GS SHN:SH SJM:SJ SLB:SB SLE:SL SLV:SV SMR:SM SOM:SO SPM:PM SRB:RS SSD:SS STP:ST SUR:SR SVK:SK SVN:SI SWE:SE SWZ:SZ SXM:SX SYC:SC SYR:SY TAA:TA TCA:TC TCD:TD TGO:TG THA:TH TJK:TJ TKL:TK TKM:TM TLS:TL TMP:TL TON:TO TTO:TT TUN:TN TUR:TR TUV:TV TWN:TW TZA:TZ UGA:UG UKR:UA UMI:UM URY:UY USA:US UZB:UZ VAT:VA VCT:VC VEN:VE VGB:VG VIR:VI VNM:VN VUT:VU WLF:WF WSM:WS XAA:XA XBB:XB XCC:XC XDD:XD XEE:XE XFF:XF XGG:XG XHH:XH XII:XI XJJ:XJ XKK:XK XLL:XL XMM:XM XNN:XN XOO:XO XPP:XP XQQ:XQ XRR:XR XSS:XS XTT:XT XUU:XU XVV:XV XWW:XW XXX:XX XYY:XY XZZ:XZ YEM:YE YMD:YE ZAF:ZA ZAR:CD ZMB:ZM ZWE:ZW ZZZ:ZZ"
        return Dictionary(uniqueKeysWithValues: aliases.split(separator: " ").map {
            let pair = $0.split(separator: ":"); return (String(pair[0]), String(pair[1]))
        })
    }()

}
