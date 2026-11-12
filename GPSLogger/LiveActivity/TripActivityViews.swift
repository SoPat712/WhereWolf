//
//  TripActivityViews.swift
//  WhereWolf
//
//  Shared by the app preview, Live Activity, widgets and controls.
//

import AppIntents
import SwiftUI

extension Image {
    // A trip mode's icon, which may be one of the custom symbols in TripModes.xcassets
    init(tripMode mode: String) {
        let symbol = TripModeStore.symbol(mode)
        if TripModeStore.isCustomSymbol(symbol) {
            self.init(symbol)
        } else {
            self.init(systemName: symbol)
        }
    }
}

struct TripModeIcon: View {
    let mode: String

    var body: some View {
        Image(tripMode: mode)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.green)
    }
}

// Counts up from the trip start without needing updates from the app
struct ElapsedTime: View {
    let start: Date

    var body: some View {
        Text(timerInterval: start...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

struct TripStat: View {
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct TripRecordingDot: View {
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(.red).frame(width: size, height: size)
            .accessibilityLabel("Recording")
    }
}

private struct TripModeHeading: View {
    let mode: String
    var lockScreen = false

    var body: some View {
        HStack(spacing: 8) {
            TripModeIcon(mode: mode)
                .frame(width: 19, height: 19)
                .frame(width: 30, height: 30)
                .background(.green.opacity(0.14), in: Circle())
            Text(TripActivityFormat.modeName(mode) + (lockScreen ? " trip" : ""))
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
            TripRecordingDot()
        }
    }
}

// Keep these insets in the shared regions so the app harness exercises corner clearance too.
struct TripExpandedLeading: View {
    let mode: String

    var body: some View {
        TripModeHeading(mode: mode)
            .padding(.leading, 8)
            .padding(.top, 6)
            .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

struct TripExpandedTrailing: View {
    let start: Date

    var body: some View {
        ElapsedTime(start: start)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 76, height: 30, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.top, 6)
            .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

struct TripExpandedBottom: View {
    let state: TripActivityState

    var body: some View {
        VStack(spacing: 8) {
            TripTrailRow(state: state)
                .frame(height: 52)
            TripActionButtons()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

struct TripCompactLeading: View {
    let mode: String

    var body: some View {
        HStack(spacing: 5) {
            TripModeIcon(mode: mode).frame(width: 20, height: 20)
            TripRecordingDot(size: 5)
        }
    }
}

struct TripMinimalView: View {
    let mode: String

    var body: some View {
        TripModeIcon(mode: mode)
            .frame(width: 19, height: 19)
            .frame(width: 30, height: 30)
            .overlay { Circle().strokeBorder(.red, lineWidth: 2) }
            .accessibilityLabel("\(TripActivityFormat.modeName(mode)), recording")
    }
}

private struct TripTrailRow: View {
    let state: TripActivityState
    var lockScreen = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(TripActivityFormat.distance(state.distance))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(TripActivityFormat.distanceUnit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(TripActivityFormat.summary(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if lockScreen, let climb = state.climb, climb >= 0, climb.isFinite {
                    Text("climb \(TripFormat.climb(climb, metric: TripActivityFormat.usesMetricSystem))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
            TripRouteSketchView(sketch: state.route ?? TripRouteSketch(points: []))
                .frame(maxWidth: .infinity)
                .frame(height: lockScreen ? 68 : 52)
        }
    }
}

struct TripRouteSketchView: View {
    let sketch: TripRouteSketch
    private let blue = Color(uiColor: .systemBlue)

    var body: some View {
        GeometryReader { geometry in
            // The ringed end marker reaches 6.5 points from the route's end.
            let points = sketch.fittedPoints(width: geometry.size.width, height: geometry.size.height, inset: 12)
            ZStack {
                if points.count >= 2, let start = points.first {
                    Path { path in
                        path.move(to: start)
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    Circle().fill(blue.opacity(0.5))
                        .frame(width: 3, height: 3)
                        .position(start)
                }
                if let end = points.last {
                    Circle().fill(blue)
                        .frame(width: 11, height: 11)
                        .overlay { Circle().stroke(.white, lineWidth: 2) }
                        .position(end)
                }
            }
        }
        .background(blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trip route sketch, north up")
    }
}

struct TripLockScreenView: View {
    let attributes: TripActivityAttributes
    let state: TripActivityState

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TripModeHeading(mode: state.mode, lockScreen: true)
                Spacer(minLength: 0)
                ElapsedTime(start: attributes.tripStart)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .frame(width: 96)
            }
            TripTrailRow(state: state, lockScreen: true)
            TripActionButtons()
        }
        .padding(16)
    }
}

struct TripActionButtons: View {
    var body: some View {
        HStack(spacing: 10) {
            Button(intent: SendNowIntent()) {
                Label("Send Now", systemImage: "arrow.up")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.green)

            Button(intent: EndTripIntent()) {
                Label("End Trip", systemImage: "stop.fill")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.red)
        }
        .controlSize(.small)
        .frame(height: 32)
    }
}
