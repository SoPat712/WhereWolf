//
//  TripActivityViews.swift
//  WhereWolf
//
//  Shared by the app preview, Live Activity, widgets and controls.
//

import AppIntents
import SwiftUI
import UIKit

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
                .frame(width: lockScreen ? 19 : 16, height: lockScreen ? 19 : 16)
                .frame(width: lockScreen ? 30 : 26, height: lockScreen ? 30 : 26)
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
            .frame(width: 76, height: 26, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.top, 6)
            .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

struct TripExpandedBottom: View {
    let state: TripActivityState
    var mapFiles = TripActivityMapFiles()

    var body: some View {
        // The phone cuts the expanded Island's content off about 13 points above its bottom edge, which leaves
        // this region about 82 points under the 26-point heading row.
        TripTrailRow(state: state, mapFiles: mapFiles)
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
    var mapFiles = TripActivityMapFiles()

    var body: some View {
        let presentation: TripActivityMap.Presentation = lockScreen ? .lockScreen : .island
        let size = presentation.size
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(TripActivityFormat.distance(state.distance))
                        .font(.system(size: lockScreen ? 26 : 22, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(TripActivityFormat.distanceUnit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(TripActivityFormat.details(state), id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            TripRouteSketchView(sketch: state.route ?? TripRouteSketch(points: []),
                                map: state.map, presentation: presentation, mapFiles: mapFiles)
                .overlay(alignment: .topLeading) { TripSpeedBadge(speed: state.speed).padding(6) }
                .frame(width: size.width, height: size.height)
            TripActionButtons(diameter: lockScreen ? 40 : 36)
        }
        .frame(height: size.height)
    }
}

struct TripRouteSketchView: View {
    let sketch: TripRouteSketch
    var map: TripActivityMap? = nil
    var presentation: TripActivityMap.Presentation = .island
    var mapFiles = TripActivityMapFiles()
    private let blue = Color(uiColor: .systemBlue)

    var body: some View {
        GeometryReader { geometry in
            let route = map?.route(for: presentation)
            let image = route.flatMap { _ in
                map.flatMap { value in
                    mapFiles.url(for: value.token, presentation: presentation).flatMap { UIImage(contentsOfFile: $0.path) }
                }
            }
            // The ringed end marker reaches 6.5 points from the route's end.
            let points = sketch.displayPoints(size: geometry.size, imageRoute: route, hasImage: image != nil)
            ZStack {
                if let image {
                    Image(uiImage: image).resizable()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
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
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trip route sketch, north up")
    }
}

struct TripLockScreenView: View {
    let attributes: TripActivityAttributes
    let state: TripActivityState
    var mapFiles = TripActivityMapFiles()

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TripModeHeading(mode: state.mode, lockScreen: true)
                Spacer(minLength: 0)
                ElapsedTime(start: attributes.tripStart)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .frame(width: 96)
            }
            TripTrailRow(state: state, lockScreen: true, mapFiles: mapFiles)
        }
        // The Lock Screen truncates a Live Activity taller than 160 points.
        .padding(14)
    }
}

// Round buttons stacked beside the map, as in the system's timer activity.
struct TripActionButtons: View {
    var diameter: CGFloat = 36

    var body: some View {
        VStack(spacing: 6) {
            Button(intent: SendNowIntent()) {
                Image(systemName: "arrow.up")
                    .font(.system(size: diameter * 0.42, weight: .bold))
                    .frame(width: diameter, height: diameter)
                    .background(.green.opacity(0.22), in: Circle())
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send Now")

            Button(intent: EndTripIntent()) {
                Image(systemName: "stop.fill")
                    .font(.system(size: diameter * 0.38, weight: .bold))
                    .frame(width: diameter, height: diameter)
                    .background(.red, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End Trip")
        }
    }
}

// The speed from the latest update, in the map's corner like the app's speedometer.
struct TripSpeedBadge: View {
    let speed: Double

    var body: some View {
        if speed.isFinite, speed >= 0 {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(TripActivityFormat.speed(speed))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(TripActivityFormat.speedUnit)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.6), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Speed")
        }
    }
}
