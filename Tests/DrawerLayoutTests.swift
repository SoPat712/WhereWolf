import Observation
import SwiftUI
import UIKit
import XCTest
@testable import Where

@MainActor
final class DrawerLayoutTests: XCTestCase {
    func testTabControlsMatchFindMyOpenAndClosed() async throws {
        try await withDrawer { panel, _ in
            @MainActor func findTabs(_ view: UIView) -> UIView? {
                if view.accessibilityIdentifier == "overland.panel.tabs" { return view }
                return view.subviews.lazy.compactMap(findTabs).first
            }
            let tabs = try XCTUnwrap(findTabs(panel.view))
            for enabled in [true, false, true] {
                panel.setContentEnabled(enabled)
                try await waitForLayout(panel)
                let bottom = tabs.convert(tabs.bounds, to: panel.view).maxY
                let safe = panel.view.bounds.maxY - panel.view.safeAreaInsets.bottom
                XCTAssertLessThanOrEqual(bottom, panel.view.bounds.maxY - 14)
                if panel.view.safeAreaInsets.bottom >= 28 {
                    // Closed, the capsule clears the home indicator. Open, the strip sits lower.
                    XCTAssertEqual(bottom, enabled ? safe + 13.5 : safe - 2, accuracy: 1)
                    if !enabled {
                        let sheet = tabs.superview!.convert(tabs.superview!.bounds, to: panel.view)
                        XCTAssertEqual(panel.view.bounds.maxY - sheet.maxY, 28, accuracy: 1)
                        XCTAssertEqual(sheet.height, 76, accuracy: 1)
                        XCTAssertEqual(sheet.width, (panel.view.bounds.width * 0.86).rounded(), accuracy: 1)
                    }
                }
            }
        }
    }
    func testControlsRemainAtDrawerTopWhileHeightMeasurementIsDeferred() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = DrawerLayoutState()
        let marker = state.marker
        let panel = MapControlPanelController(
            controls: AnyView(DrawerLayoutControls(state: state, marker: marker)),
            tabs: AnyView(Text("Tracker").frame(height: 60))
        )
        let clock = DrawerAnimationClock()
        panel.animationClock = { clock.timestamp }
        clock.start()
        defer { clock.stop() }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = panel
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previous?.makeKey()
        }
        try await waitForLayout(panel, state: state)
        XCTAssertNotNil(marker.window)
        let inset = marker.convert(marker.bounds, to: panel.view).minY - panel.currentGeometry().top
        let collapsedDetailsTop = panel.currentGeometry().top

        for expanded in [true, false] {
            panel.setContentInteracting(true)
            let frozenTop = panel.currentGeometry().top
            state.expanded = expanded
            try await waitForFrames("SwiftUI rendered the changed controls") {
                marker.accessibilityValue == String(expanded)
            }
            XCTAssertEqual(panel.currentGeometry().top, frozenTop, accuracy: 0.5)
            XCTAssertEqual(marker.convert(marker.bounds, to: panel.view).minY - frozenTop,
                           inset, accuracy: 0.5)

            panel.setContentInteracting(false)
            try await waitForLayout(panel, state: state)
            XCTAssertEqual(marker.convert(marker.bounds, to: panel.view).minY - panel.currentGeometry().top,
                           inset, accuracy: 0.5)
            if expanded {
                XCTAssertLessThan(panel.currentGeometry().top, collapsedDetailsTop - 100)
            } else {
                XCTAssertEqual(panel.currentGeometry().top, collapsedDetailsTop, accuracy: 0.5)
            }
        }
    }

    func testContentShrinkRetargetsAnUnfinishedExpansion() async throws {
        try await withDrawer { panel, state in
            let closedTop = panel.currentGeometry().top
            state.expanded = true
            try await waitForFrames("Expansion has begun") {
                panel.currentGeometry().top < closedTop - 1 && !panel.isLayoutSettled
            }
            let openingTop = panel.currentGeometry().top
            XCTAssertLessThan(openingTop, closedTop - 1)

            state.expanded = false
            try await waitForFrames("The drawer has reversed direction") {
                panel.currentGeometry().top > openingTop + 1
            }
            XCTAssertGreaterThan(panel.currentGeometry().top, openingTop + 1)
            try await waitForLayout(panel, state: state)
            XCTAssertEqual(panel.currentGeometry().top, closedTop, accuracy: 0.5)
        }
    }

    func testTabReplacementReleasesPreviousInteractionAndKeepsFittingContentFlat() async throws {
        try await withDrawer { panel, _ in
            let previousTop = panel.currentGeometry().top
            panel.setContentInteracting(true)
            panel.update(controls: AnyView(Text("Trip").frame(height: 80)),
                         tabs: AnyView(Text("Tabs").frame(height: 60)))
            panel.expand()
            try await waitForLayout(panel)
            XCTAssertGreaterThan(panel.currentGeometry().top, previousTop + 20)

            let scroll = try XCTUnwrap(self.contentScroll(in: panel.view))
            XCTAssertFalse(scroll.isScrollEnabled)
            XCTAssertFalse(scroll.bounces)
            XCTAssertEqual(scroll.contentOffset, .zero)

            panel.update(controls: AnyView(Text("Large text details").frame(height: 2000)),
                         tabs: AnyView(Text("Tabs").frame(height: 60)))
            try await waitForLayout(panel)
            XCTAssertTrue(scroll.isScrollEnabled)
            XCTAssertFalse(scroll.bounces)
        }
    }

    func testSettingsCardsStayDistinctFromTheExpandedSheetInBothAppearances() {
        let backdrop = ExpandingSheetBackgroundView()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let background = backdrop.solidColor.resolvedColor(with: traits)
            let row = UIColor(Color.settingsRow).resolvedColor(with: traits)
            XCTAssertGreaterThan(luminance(row) - luminance(background), 0.008,
                                 "Settings cards must remain lighter than the grouped background in \(style).")
            XCTAssertEqual(row.cgColor.alpha, 1, accuracy: 0.001)
        }
    }

    private func luminance(_ color: UIColor) -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        let values = [Double(red), Double(green), Double(blue)].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]
    }

    func testTripSettingsBackgroundFadesWithSheetHeightInBothDirections() async throws {
        guard !UIAccessibility.isReduceTransparencyEnabled else {
            throw XCTSkip("Reduce Transparency keeps the sheet opaque.")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIHostingController(rootView: Color.blue.sheet(isPresented: .constant(true)) {
            TripSettingsSheet(onDone: {})
        })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.dismiss(animated: false)
            window.isHidden = true
            previous?.makeKey()
        }
        try await waitForFrames("The sheet is presented and its backdrop has settled") {
            guard let backdrop = self.sheetBackground(in: window) else { return false }
            return root.presentedViewController?.isBeingPresented == false && !backdrop.isFollowing
        }
        let backdrop = try XCTUnwrap(sheetBackground(in: window))
        let sheet = try XCTUnwrap(root.presentedViewController?.sheetPresentationController)
        XCTAssertLessThan(backdrop.solidOpacity, 0.05,
                          "Background \(backdrop.bounds.height), presented \(sheet.presentedView?.bounds.height ?? 0), frame \(sheet.frameOfPresentedViewInContainerView)")

        let recorder = SheetOpacityRecorder(backdrop: backdrop)
        defer { recorder.stop() }
        recorder.start()
        backdrop.followForTransition()
        sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        try await waitForFrames("The sheet transition and backdrop have settled") {
            !backdrop.isFollowing && root.presentedViewController?.transitionCoordinator == nil
        }
        recorder.stop()
        XCTAssertGreaterThan(backdrop.solidOpacity, 0.99)
        XCTAssertGreaterThan(recorder.samples.filter { $0 > 0.05 && $0 < 0.95 }.count, 3,
                             "The backdrop should fade during expansion, not switch at the endpoint. Samples: \(recorder.samples)")
        backdrop.followForTransition()
        sheet.animateChanges { sheet.selectedDetentIdentifier = .medium }
        try await waitForFrames("The sheet transition and backdrop have settled") {
            !backdrop.isFollowing && root.presentedViewController?.transitionCoordinator == nil
        }
        XCTAssertLessThan(backdrop.solidOpacity, 0.05)
        XCTAssertFalse(backdrop.isFollowing)
        backdrop.setNeedsLayout()
        backdrop.layoutIfNeeded()
        XCTAssertFalse(backdrop.isFollowing, "An unchanged layout must not restart settled frame updates.")
    }

    private func sheetBackground(in view: UIView) -> ExpandingSheetBackgroundView? {
        if let backdrop = view as? ExpandingSheetBackgroundView { return backdrop }
        return view.subviews.lazy.compactMap { self.sheetBackground(in: $0) }.first
    }

    private func withDrawer(_ run: (MapControlPanelController, DrawerLayoutState) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = DrawerLayoutState()
        let panel = MapControlPanelController(
            controls: AnyView(DrawerLayoutControls(state: state, marker: state.marker)),
            tabs: AnyView(Text("Tabs").frame(height: 60))
        )
        let clock = DrawerAnimationClock()
        panel.animationClock = { clock.timestamp }
        clock.start()
        defer { clock.stop() }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = panel
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previous?.makeKey()
        }
        try await waitForLayout(panel, state: state)
        try await run(panel, state)
    }

    private func waitForLayout(_ panel: MapControlPanelController, state: DrawerLayoutState? = nil) async throws {
        try await waitForFrames("Drawer content measurement and spring completed") {
            panel.isLayoutSettled && (state.map { $0.marker.accessibilityValue == String($0.expanded) } ?? true)
        }
    }

    private func waitForFrames(_ description: String, until predicate: @escaping () -> Bool) async throws {
        let ready = expectation(description: description)
        let observer = LayoutFrameObserver {
            if predicate() { ready.fulfill(); return true }
            return false
        }
        observer.start()
        defer { observer.stop() }
        await fulfillment(of: [ready], timeout: 15)
        guard observer.completed else {
            throw NSError(domain: "DrawerLayoutTests", code: 1)
        }
    }

    private func contentScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.contentScroll(in: $0) }.first
    }
}

@MainActor
private final class SheetOpacityRecorder: NSObject {
    private let backdrop: ExpandingSheetBackgroundView
    private var displayLink: CADisplayLink?
    private(set) var samples: [CGFloat] = []

    init(backdrop: ExpandingSheetBackgroundView) { self.backdrop = backdrop }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func frame() { samples.append(backdrop.solidOpacity) }
}

@Observable @MainActor
private final class DrawerLayoutState {
    var expanded = false
    let marker = UIView()
}

private struct DrawerLayoutControls: View {
    @Bindable var state: DrawerLayoutState
    let marker: UIView

    var body: some View {
        VStack(spacing: 8) {
            Text("Timeline").frame(height: 74)
            HStack {
                Text("Tracking")
                Spacer()
                DrawerDetailsButton(expanded: $state.expanded, subject: "location")
            }
            .frame(height: 44)
            .background(DrawerLayoutMarker(view: marker, expanded: state.expanded))
            if state.expanded { Text("Location details").frame(height: 164) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DrawerLayoutMarker: UIViewRepresentable {
    let view: UIView
    let expanded: Bool

    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ view: UIView, context: Context) { view.accessibilityValue = String(expanded) }
}

@MainActor
private final class LayoutFrameObserver: NSObject {
    private var displayLink: CADisplayLink?
    private let inspect: () -> Bool
    private(set) var completed = false

    init(inspect: @escaping () -> Bool) { self.inspect = inspect }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func frame() {
        if inspect() { completed = true; stop() }
    }
}

@MainActor
private final class DrawerAnimationClock: NSObject {
    private var displayLink: CADisplayLink?
    private(set) var timestamp: CFTimeInterval = 0

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // A suspended simulator must not skip the unfinished spring this fixture tests.
    @objc private func frame() { timestamp += 1.0 / 60 }
}
