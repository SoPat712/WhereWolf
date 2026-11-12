#if !WHEREWOLF_APP_STORE
import Foundation

// Invented account data. Structural examples follow swagger/v1/swagger.yaml and the API serializers.
enum DawarichInsightsFixtures {
    static let responses: [String: String] = [
        "trackedMonths": #"[{"year":2025,"months":["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]},{"year":2024,"months":["Nov","Dec"]}]"#,
        "overview": #"{"year":2025,"availableYears":[2025,2024],"totals":{"totalDistance":12482.6,"distanceUnit":"km","countriesCount":3,"citiesCount":8,"countriesList":["Germany","France","Portugal"],"daysTraveling":204},"activityHeatmap":{"dailyData":{"2025-01-14":824000,"2025-02-06":612000,"2025-03-22":1035000,"2025-04-09":940000,"2025-05-18":1242000,"2025-06-11":1780000,"2025-07-04":2135000,"2025-08-19":980000,"2025-09-12":740000,"2025-10-08":620000,"2025-11-22":855000,"2025-12-14":719600},"activeDays":204,"currentStreak":6,"longestStreak":31}}"#,
        "details": #"{"year":2025,"comparison":{"previousYear":2024,"distanceChangePercent":18.4,"countriesChange":1,"citiesChange":3,"daysChange":22},"travelPatterns":{"timeOfDay":{"morning":32,"afternoon":46,"evening":22,"night":0},"dayOfWeek":[1200000,1300000,1400000,1100000,1700000,2900000,2882600],"seasonality":{"winter":17,"spring":26,"summer":39,"fall":18},"activityBreakdown":{"walking":{"duration":54000,"percentage":32},"cycling":{"duration":114000,"percentage":68}},"topVisitedLocations":[{"name":"Example Garden Studio","visitCount":24,"totalDuration":7200}]}}"#,
        "countries": #"{"countries":[{"iso_a3":"DEU","name":"Germany"},{"iso_a3":"FRA","name":"France"},{"iso_a3":"PRT","name":"Portugal"}]}"#,
        "cities": #"{"data":[{"country":"Germany","cities":[{"city":"Berlin","points":4394,"timestamp":1724868369,"stayed_for":24490},{"city":"Munich","points":2156,"timestamp":1724782369,"stayed_for":12450}]},{"country":"France","cities":[{"city":"Paris","points":3267,"timestamp":1724695969,"stayed_for":18720}]}]}"#,
        "residency": #"{"year":2025,"counting_mode":"any_presence","total_tracked_days":204,"available_years":[2025,2024],"countries":[{"country_name":"Germany","country_code":"DE","days":178,"periods":[{"start_date":"2025-01-01","end_date":"2025-01-31","consecutive_days":31}]},{"country_name":"France","country_code":"FR","days":17,"periods":[]},{"country_name":"Portugal","country_code":"PT","days":9,"periods":[]}]}"#,
        "places": #"[{"id":101,"name":"Example Garden Studio","latitude":52.52,"longitude":13.405,"archived":false,"visits_count":24},{"id":102,"name":"Imaginary Canal Café","latitude":52.51,"longitude":13.4,"archived":false,"visits_count":12}]"#,
        "visits": #"[{"id":201,"name":"Example Garden Studio","display_name":"Example Garden Studio","place_id":101,"status":"confirmed","started_at":"2025-12-14T09:00:00Z","ended_at":"2025-12-14T17:00:00Z","duration":480,"center":null,"place":{"id":101,"name":"Example Garden Studio","latitude":52.52,"longitude":13.405}},{"id":202,"name":"Imaginary Canal Café","display_name":"Imaginary Canal Café","place_id":102,"status":"confirmed","started_at":"2025-12-13T12:00:00Z","ended_at":"2025-12-13T13:30:00Z","duration":90,"center":null},{"id":203,"name":"Example Garden Studio","display_name":"Example Garden Studio","place_id":101,"status":"confirmed","started_at":"2025-12-12T09:00:00Z","ended_at":"2025-12-12T16:00:00Z","duration":420,"center":null}]"#,
        "photos": #"[{"id":"sample-garden","latitude":52.52,"longitude":13.405,"localDateTime":"2025-12-14T11:20:00","capturedAt":"2025-12-14T10:20:00Z","originalFileName":"invented-garden.jpg","city":"Example Garden","state":"","country":"Germany","type":"image","orientation":"landscape","source":"immich"},{"id":"sample-river","latitude":52.51,"longitude":13.4,"localDateTime":"2025-12-14T15:10:00","capturedAt":"2025-12-14T14:10:00Z","originalFileName":"invented-river.jpg","city":"Imaginary Canal","state":"","country":"Germany","type":"image","orientation":"landscape","source":"photoprism"},{"id":"sample-trip","latitude":48.85,"longitude":2.35,"localDateTime":"2025-07-04T18:00:00+02:00","originalFileName":"invented-trip.jpg","city":"Sample Day Trip","state":"","country":"France","type":"image","orientation":"landscape","source":"immich"}]"#,
        "digests": #"{"digests":[{"year":2025,"distance":12482600,"countriesCount":3,"citiesCount":8,"createdAt":"2026-01-02T12:00:00Z"}],"availableYears":[2024]}"#,
        "digest": #"{"year":2025,"distance":{"meters":12482600,"converted":12482.6,"unit":"km","comparisonText":"About a third of the way around Earth — an invented example."},"toponyms":{"countriesCount":3,"citiesCount":8,"countries":[{"country":"Germany","cities":["Berlin","Munich"]},{"country":"France","cities":["Paris"]},{"country":"Portugal","cities":["Lisbon"]}]},"monthlyDistances":{"january":824000,"february":612000,"march":1035000,"april":940000,"may":1242000,"june":1780000,"july":2135000,"august":980000,"september":740000,"october":620000,"november":855000,"december":719600},"timeSpentByLocation":{"countries":[{"name":"Germany","minutes":256320},{"name":"France","minutes":24480}]},"firstTimeVisits":{"countries":["Portugal"],"cities":["Lisbon"]},"yearOverYear":{"distanceChangePercent":18.4,"countriesChange":1,"citiesChange":3},"allTimeStats":{"totalCountries":6,"totalCities":24,"totalDistance":"42500000"},"travelPatterns":{"timeOfDay":{},"seasonality":{},"activityBreakdown":{}},"createdAt":"2026-01-02T12:00:00Z","updatedAt":"2026-01-02T12:00:00Z"}"#,
    ]

    static func data(_ name: String, year: Int = 2025) -> Data {
        Data(responses[name]!.replacingOccurrences(of: "2025", with: String(year)).utf8)
    }

    static func snapshot(year: Int = 2025) -> DawarichInsights.Snapshot {
        let decoder = JSONDecoder()
        var result = DawarichInsights.Snapshot()
        result.overview = try? decoder.decode(DawarichInsights.Overview.self, from: data("overview", year: year))
        result.details = try? decoder.decode(DawarichInsights.Details.self, from: data("details", year: year))
        result.countries = try? decoder.decode(DawarichInsights.Countries.self, from: data("countries"))
        result.cities = try? decoder.decode(DawarichInsights.Cities.self, from: data("cities"))
        result.residency = try? decoder.decode(DawarichInsights.Residency.self, from: data("residency", year: year))
        result.places = (try? decoder.decode([DawarichInsights.Place].self, from: data("places"))) ?? []
        result.visits = (try? decoder.decode([DawarichInsights.Visit].self, from: data("visits", year: year))) ?? []
        result.photos = (try? decoder.decode([DawarichInsights.Photo].self, from: data("photos", year: year))) ?? []
        result.digest = try? decoder.decode(DawarichInsights.Digest.self, from: data("digest", year: year))
        result.updated = DawarichInsights.parseDate("2026-01-02T12:00:00Z")
        return result
    }
}
#endif
