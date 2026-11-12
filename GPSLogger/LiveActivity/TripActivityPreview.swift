#if !WHEREWOLF_APP_STORE
import SwiftUI

// All geometry and readings here are invented. The fixture never starts a trip or runs its buttons.
struct TripActivityPreview: View {
    let kind: String
    private let start = Date().addingTimeInterval(-764)

    static func fixture(arguments: [String] = ProcessInfo.processInfo.arguments) -> TripActivityPreview? {
        guard let index = arguments.firstIndex(of: "-WhereWolfTripActivityPreview"),
              arguments.indices.contains(index + 1),
              ["car", "walk", "short"].contains(arguments[index + 1]) else { return nil }
        return TripActivityPreview(kind: arguments[index + 1])
    }

    private var state: TripActivityState {
        let short = kind == "short"
        let walk = kind == "walk"
        let route = short ? [TripRouteSketch.Point(x: 128, y: 128)] : [
            .init(x: 0, y: 43), .init(x: 20, y: 45), .init(x: 40, y: 38),
            .init(x: 60, y: 25), .init(x: 80, y: 27), .init(x: 105, y: 38),
            .init(x: 125, y: 34), .init(x: 145, y: 17), .init(x: 165, y: 6),
            .init(x: 185, y: 10), .init(x: 205, y: 20), .init(x: 230, y: 16),
            .init(x: 255, y: 0)
        ]
        return TripActivityState(mode: walk ? "walk" : "car", distance: short ? 0 : (walk ? 1_018 : 13_550),
            speed: walk ? 1.3 : 15.2, topSpeed: short ? -1 : (walk ? 1.9 : 25.9),
            climb: short ? 0 : (walk ? 24 : 36.6), averageSpeed: short ? nil : (walk ? 1.33 : 13.86),
            route: TripRouteSketch(points: route))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Trail · \(kind)").font(.headline).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 8) {
                    caption("Expanded Island · 371 × 158 pt")
                    VStack(spacing: 8) {
                        HStack(alignment: .top, spacing: 0) {
                            TripExpandedLeading(mode: state.mode)
                            Spacer(minLength: 0)
                            TripExpandedTrailing(start: start)
                        }
                        TripExpandedBottom(state: state)
                    }
                    // The system supplies space outside the content regions, including the top corners.
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .frame(width: 371, height: 158)
                    .background(.black, in: RoundedRectangle(cornerRadius: 46))
                    .environment(\.colorScheme, .dark)
                    .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 8) {
                    caption("Compact and minimal")
                    HStack(spacing: 14) {
                        HStack {
                            TripCompactLeading(mode: state.mode)
                            Spacer()
                            ElapsedTime(start: start).font(.subheadline.weight(.semibold)).frame(width: 70)
                        }
                        .padding(.horizontal, 12)
                        .frame(width: 250, height: 37)
                        .background(.black, in: Capsule())
                        TripMinimalView(mode: state.mode)
                            .frame(width: 37, height: 37)
                            .background(.black, in: Circle())
                    }
                    .environment(\.colorScheme, .dark)
                    .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 8) {
                    caption("Lock Screen")
                    TripLockScreenView(attributes: .init(tripStart: start), state: state)
                        .frame(width: 371)
                        .background(Color(uiColor: .secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 26))
                }
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.10).ignoresSafeArea())
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.white.opacity(0.65))
    }
}
#endif
