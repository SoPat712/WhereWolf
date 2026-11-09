import SwiftUI
import CoreLocation

struct WifiPlace: Identifiable, Equatable {
    enum Recording: String, CaseIterable, Identifiable {
        case point, nothing
        var id: Self { self }
        var label: String { self == .point ? "Place’s Point" : "Nothing" }
        var footer: String {
            self == .point
                ? "The place’s point is saved when you arrive and every 5 minutes while you stay, so indoor GPS can’t wander around the building."
                : "No points are saved while you’re connected here, within about \(WifiPlace.distanceLabel(GLWifiPlaceMatchDistance)) of the pin. Recording carries on once you leave."
        }
    }

    struct Symbol: Identifiable {
        let id: String
        let label: String
    }

    static let symbols: [Symbol] = [
        .init(id: "house.fill", label: "House"),
        .init(id: "building.2.fill", label: "Office"),
        .init(id: "briefcase.fill", label: "Briefcase"),
        .init(id: "graduationcap.fill", label: "School"),
        .init(id: "cup.and.saucer.fill", label: "Café"),
        .init(id: "dumbbell.fill", label: "Gym"),
        .init(id: "cart.fill", label: "Shop"),
        .init(id: "fork.knife", label: "Restaurant"),
        .init(id: "bed.double.fill", label: "Hotel"),
        .init(id: "heart.fill", label: "Family"),
        .init(id: "tree.fill", label: "Park"),
        .init(id: "airplane", label: "Travel"),
        .init(id: "car.fill", label: "Car"),
        .init(id: "books.vertical.fill", label: "Library"),
        .init(id: "cross.case.fill", label: "Medical"),
        .init(id: "star.fill", label: "Star"),
        .init(id: "mappin", label: "Pin"),
        .init(id: "wifi", label: "Wi-Fi")
    ]
    // Spectrum order, gray last.
    static let colors = ["red", "orange", "green", "teal", "blue", "purple", "pink", "gray"]

    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var networks: [String]
    var symbol: String
    var color: String
    var record: Recording
    var symbolChosen: Bool

    init(id: String = UUID().uuidString, name: String = "", latitude: Double = 0,
         longitude: Double = 0, networks: [String] = [],
         symbol: String? = nil, color: String = "blue", record: Recording = .point,
         symbolChosen: Bool = false) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.networks = networks
        self.symbol = symbol ?? Self.autoSymbol(for: name)
        self.color = color
        self.record = record
        self.symbolChosen = symbolChosen
    }

    init?(_ dictionary: [String: Any]) {
        guard let values = GLManager.validatedWifiPlaces([dictionary]), values.count == 1,
              let value = values.first,
              let id = value["id"] as? String,
              let name = value["name"] as? String,
              let latitude = value["latitude"] as? NSNumber,
              let longitude = value["longitude"] as? NSNumber,
              let networks = value["networks"] as? [String],
              let symbol = value["symbol"] as? String,
              let color = value["color"] as? String,
              let record = Recording(rawValue: value["record"] as? String ?? "point") else { return nil }
        self.init(id: id, name: name, latitude: latitude.doubleValue,
                  longitude: longitude.doubleValue,
                  networks: networks, symbol: symbol, color: color, record: record,
                  symbolChosen: value["symbolChosen"] as? Bool ?? false)
    }

    var dictionary: [String: Any] {
        ["id": id, "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
         "latitude": latitude, "longitude": longitude,
         "networks": networks, "symbol": symbol, "color": color,
         "record": record.rawValue, "symbolChosen": symbolChosen]
    }

    var isValid: Bool { Self(dictionary) != nil }
    var coordinate: CLLocationCoordinate2D {
        get { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
        set { latitude = newValue.latitude; longitude = newValue.longitude }
    }
    var tint: Color { Self.tint(for: color) }

    static func autoSymbol(for name: String) -> String {
        GLManager.autoWifiPlaceSymbol(for: name)
    }

    mutating func rename(to name: String) {
        self.name = name
        if !symbolChosen { symbol = Self.autoSymbol(for: name) }
    }

    static func tint(for color: String) -> Color {
        switch color {
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "purple": .purple
        case "pink": .pink
        case "teal": .teal
        case "gray": .gray
        default: .blue
        }
    }

    static func distanceLabel(_ meters: Double) -> String {
        guard meters.isFinite else { return "–" }
        if meters < 1000 { return "\(Int(meters.rounded())) m" }
        return "\((meters / 1000).formatted(.number.precision(.fractionLength(0...1)))) km"
    }
}

struct WifiObservedNetwork: Identifiable, Equatable {
    let name: String
    let lastSeen: Date?
    let latitude: Double?
    let longitude: Double?
    let connectedSeconds: Double
    var id: String { name }

    init?(name: String, lastSeen: Date? = nil, latitude: Double? = nil,
          longitude: Double? = nil, connectedSeconds: Double = 0) {
        guard !name.isEmpty, name.utf8.count <= 32 else { return nil }
        self.name = name
        self.lastSeen = lastSeen
        self.latitude = latitude
        self.longitude = longitude
        self.connectedSeconds = connectedSeconds
    }

    init?(_ dictionary: [String: Any]) {
        let seconds = (dictionary["lastSeen"] as? NSNumber)?.doubleValue
        self.init(name: dictionary["name"] as? String ?? "",
                  lastSeen: seconds.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                  latitude: (dictionary["latitude"] as? NSNumber)?.doubleValue,
                  longitude: (dictionary["longitude"] as? NSNumber)?.doubleValue,
                  connectedSeconds: (dictionary["connectedSeconds"] as? NSNumber)?.doubleValue ?? 0)
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    var seenLabel: String {
        guard let lastSeen else { return "Not seen yet" }
        if Calendar.current.isDateInToday(lastSeen) { return "Seen today" }
        if Calendar.current.isDateInYesterday(lastSeen) { return "Seen yesterday" }
        return "Seen \(lastSeen.formatted(.dateTime.month(.abbreviated).day()))"
    }

    var timeThisWeekLabel: String {
        let hours = max(1, Int((connectedSeconds / 3600).rounded()))
        return "About \(hours) \(hours == 1 ? "hour" : "hours") this week"
    }
}

struct WifiPlaceIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size >= 80 ? 48 : size * 0.6, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}
