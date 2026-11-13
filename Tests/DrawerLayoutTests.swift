import Observation
import MapKit
import SwiftUI
import UIKit
import XCTest
@testable import WhereWolf

@MainActor
final class DrawerLayoutTests: XCTestCase {
    func testTabControlsMatchFindMyOpenAndClosed() async throws {
        try await withDrawer(tabs: AnyView(DrawerTabStrip(selection: 0, onSelect: { _ in }))) { panel, _ in
            @MainActor func findTabs(_ view: UIView) -> UIView? {
                if view.accessibilityIdentifier == "wherewolf.panel.tabs" { return view }
                return view.subviews.lazy.compactMap(findTabs).first
            }
            let tabs = try XCTUnwrap(findTabs(panel.view))
            let grabber = try XCTUnwrap(self.findView(in: panel.view, label: "Controls panel"))
            for expanded in [true, false, true] {
                if expanded { grabber.accessibilityIncrement() } else { grabber.accessibilityDecrement() }
                try await waitForLayout(panel)
                let bottom = tabs.convert(tabs.bounds, to: panel.view).maxY
                let safe = panel.view.bounds.maxY - panel.view.safeAreaInsets.bottom
                XCTAssertLessThanOrEqual(bottom, panel.view.bounds.maxY - 14)
                if panel.view.safeAreaInsets.bottom >= 28 {
                    // Closed, the capsule clears the home indicator and the unscaled strip sits
                    // 3.2 points above its bottom, below the grabber mark. Open, the strip sits lower.
                    XCTAssertEqual(bottom, expanded ? safe + 13.5 : safe + 2.8, accuracy: 1)
                    if !expanded {
                        let sheet = tabs.superview!.convert(tabs.superview!.bounds, to: panel.view)
                        XCTAssertEqual(panel.view.bounds.maxY - sheet.maxY, 28, accuracy: 1)
                        XCTAssertEqual(sheet.height, 76, accuracy: 1)
                        XCTAssertEqual(sheet.width, (panel.view.bounds.width * 0.86).rounded(), accuracy: 1)
                    }
                }
            }
        }
    }
    func testDrawerCellsLandOnSystemItemsWithAnEvenSelectionGap() {
        // The measured iOS 27 bar: three 94-point items, 86 apart and overlapping by 8, inside a 274-point platter.
        let platter = DrawerBarGeometry(frame: CGRect(x: 64, y: 780, width: 274, height: 62), radius: 31)
        let items = (0..<3).map { CGRect(x: 68 + CGFloat($0) * 86, y: 784, width: 94, height: 54) }
        let inset = SystemTabBarGeometry.stripInset(for: platter, items: items)
        XCTAssertEqual(inset, SystemTabBarGeometry.defaultStripInset, accuracy: 0.01)
        let pitch = (platter.frame.width - inset * 2 - DrawerTabStrip.sideInset * 2) / CGFloat(items.count)
        for (index, item) in items.enumerated() {
            let center = platter.frame.minX + inset + DrawerTabStrip.sideInset + pitch * (CGFloat(index) + 0.5)
            XCTAssertEqual(center, item.midX, accuracy: 0.01)
        }
        XCTAssertEqual(DrawerTabStrip.sideInset - DrawerTabStrip.contentInset, DrawerTabStrip.contentInset,
                       "The end selections keep the same gap from the capsule as above and below them.")
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

    func testDetailsCloseShrinksAfterBrowsingFrameFitAndHistoryPublication() async throws {
        try await withDrawer(controls: { AnyView(DrawerBrowsingControls(state: $0)) }) { panel, state in
            state.browsing = true
            state.historyFrame = "Week"
            try await self.waitForBrowsingLayout(panel, state: state)
            let compactTop = panel.currentGeometry().top
            let controlsInset = state.visibleMarker.convert(state.visibleMarker.bounds, to: panel.view).minY - compactTop

            state.expanded = true
            try await self.waitForBrowsingLayout(panel, state: state)
            let detailsTop = panel.currentGeometry().top
            XCTAssertLessThan(detailsTop, compactTop - 100)

            // A frame fit can end a coast and publish queued server history while the Details
            // view disappears. Keep the presentation frozen until that interaction releases it.
            panel.setContentInteracting(true)
            state.expanded = false
            state.historyFrame = "Month"
            state.publication += 1
            try await self.waitForFrames("The collapsed controls rendered the pending history") {
                state.visibleMarker.accessibilityValue == "false"
                    && state.visibleMarker.accessibilityHint == state.renderedRevision
            }
            XCTAssertEqual(panel.currentGeometry().top, detailsTop, accuracy: 0.5)
            XCTAssertEqual(state.visibleMarker.convert(state.visibleMarker.bounds, to: panel.view).minY - detailsTop,
                           controlsInset, accuracy: 0.5)

            panel.setContentInteracting(false)
            state.publication += 1
            try await self.waitForBrowsingLayout(panel, state: state)
            XCTAssertEqual(panel.currentGeometry().top, compactTop, accuracy: 0.5)
            try self.assertCompactControls(panel, state: state)

            state.historyFrame = "Year"
            state.publication += 1
            try await self.waitForBrowsingLayout(panel, state: state)
            XCTAssertEqual(panel.currentGeometry().top, compactTop, accuracy: 0.5)
            try self.assertCompactControls(panel, state: state)
        }
    }

    func testNaturalDetailsCloseRetargetsExpansionAcrossBrowsingChange() async throws {
        try await withDrawer(controls: { AnyView(DrawerBrowsingControls(state: $0)) }) { panel, state in
            let compactTop = panel.currentGeometry().top
            state.expanded = true
            try await self.waitForFrames("The natural Details content has begun opening") {
                panel.currentGeometry().top < compactTop - 1 && !panel.isLayoutSettled
            }
            let openingTop = panel.currentGeometry().top

            state.expanded = false
            state.browsing = true
            state.historyFrame = "Week"
            state.publication += 1
            try await self.waitForFrames("The pending expansion is retargeted to the compact browsing controls") {
                panel.currentGeometry().top > openingTop + 1
            }
            try await self.waitForBrowsingLayout(panel, state: state)
            XCTAssertEqual(panel.currentGeometry().top, compactTop, accuracy: 0.5)
            try self.assertCompactControls(panel, state: state)
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

    func testTabSwitchFadesTheOutgoingControlsOverTheNewOnes() async throws {
        try await withDrawer { panel, _ in
            let scroll = try XCTUnwrap(self.contentScroll(in: panel.view))
            let host = try XCTUnwrap(self.findView(in: scroll, identifier: "wherewolf.panel.controls"))
            panel.update(controls: AnyView(Text("Trip").frame(height: 80)),
                         tabs: AnyView(Text("Tabs").frame(height: 60)), crossfade: true)
            let outgoing = try XCTUnwrap(self.findView(in: scroll, identifier: "wherewolf.panel.outgoing-controls"))
            XCTAssertFalse(outgoing.isUserInteractionEnabled)
            XCTAssertGreaterThan(try XCTUnwrap(scroll.subviews.firstIndex(of: outgoing)),
                                 try XCTUnwrap(scroll.subviews.firstIndex(of: host)),
                                 "The outgoing controls fade over the incoming ones.")
            XCTAssertEqual(host.alpha, 1, "The incoming controls animate to full opacity.")
            try await waitForFrames("Both halves of the crossfade finished") {
                outgoing.superview == nil && host.layer.animation(forKey: "opacity") == nil
            }
            try await waitForLayout(panel)

            let grabber = try XCTUnwrap(self.findView(in: panel.view, label: "Controls panel"))
            grabber.accessibilityDecrement()
            try await waitForLayout(panel)
            panel.update(controls: AnyView(Text("Tracker").frame(height: 80)),
                         tabs: AnyView(Text("Tabs").frame(height: 60)), crossfade: true)
            XCTAssertNil(self.findView(in: scroll, identifier: "wherewolf.panel.outgoing-controls"),
                         "A closed drawer shows no controls to fade.")
            XCTAssertEqual(host.alpha, 1)
            XCTAssertNil(host.layer.animation(forKey: "opacity"))
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
        let rows = rowBackgrounds(in: window)
        XCTAssertFalse(rows.isEmpty, "Trip Settings rows should use the sheet's row background.")
        XCTAssertTrue(rows.allSatisfy { $0.solid < 0.05 }, "Rows over the glass should be translucent: \(rows.map(\.solid))")

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
        XCTAssertTrue(rowBackgrounds(in: window).allSatisfy { $0.solid > 0.99 },
                      "Rows should be solid once the sheet is: \(rowBackgrounds(in: window).map(\.solid))")
        XCTAssertGreaterThan(recorder.samples.filter { $0 > 0.05 && $0 < 0.95 }.count, 3,
                             "The backdrop should fade during expansion, not switch at the endpoint. Samples: \(recorder.samples)")
        backdrop.followForTransition()
        sheet.animateChanges { sheet.selectedDetentIdentifier = .medium }
        try await waitForFrames("The sheet transition and backdrop have settled") {
            !backdrop.isFollowing && root.presentedViewController?.transitionCoordinator == nil
        }
        XCTAssertLessThan(backdrop.solidOpacity, 0.05)
        XCTAssertTrue(rowBackgrounds(in: window).allSatisfy { $0.solid < 0.05 })
        XCTAssertFalse(backdrop.isFollowing)
        backdrop.setNeedsLayout()
        backdrop.layoutIfNeeded()
        XCTAssertFalse(backdrop.isFollowing, "An unchanged layout must not restart settled frame updates.")
    }

    private func rowBackgrounds(in view: UIView) -> [ExpandingSheetRowBackgroundView] {
        (view as? ExpandingSheetRowBackgroundView).map { [$0] } ?? view.subviews.flatMap { rowBackgrounds(in: $0) }
    }

    private func sheetBackground(in view: UIView) -> ExpandingSheetBackgroundView? {
        if let backdrop = view as? ExpandingSheetBackgroundView { return backdrop }
        return view.subviews.lazy.compactMap { self.sheetBackground(in: $0) }.first
    }

    private func withDrawer(tabs: AnyView = AnyView(Text("Tabs").frame(height: 60)),
                            controls: ((DrawerLayoutState) -> AnyView)? = nil,
                            _ run: (MapControlPanelController, DrawerLayoutState) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = DrawerLayoutState()
        let panel = MapControlPanelController(
            controls: controls?(state) ?? AnyView(DrawerLayoutControls(state: state, marker: state.marker)),
            tabs: tabs
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

    private func waitForBrowsingLayout(_ panel: MapControlPanelController, state: DrawerLayoutState) async throws {
        try await waitForFrames("Browsing content and drawer sizing agree") {
            guard panel.isLayoutSettled, state.visibleMarker.accessibilityValue == String(state.expanded),
                  state.visibleMarker.accessibilityHint == state.renderedRevision else { return false }
            guard !state.expanded,
                  let tabs = self.findView(in: panel.view, identifier: "wherewolf.panel.tabs") else { return true }
            let controlsBottom = state.visibleMarker.convert(state.visibleMarker.bounds, to: panel.view).maxY
            return abs(tabs.convert(tabs.bounds, to: panel.view).minY - controlsBottom - 6) < 1
        }
    }

    private func assertCompactControls(_ panel: MapControlPanelController, state: DrawerLayoutState,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let tabs = try XCTUnwrap(findView(in: panel.view, identifier: "wherewolf.panel.tabs"), file: file, line: line)
        let scroll = try XCTUnwrap(contentScroll(in: panel.view), file: file, line: line)
        let controlsBottom = state.visibleMarker.convert(state.visibleMarker.bounds, to: panel.view).maxY
        let tabsTop = tabs.convert(tabs.bounds, to: panel.view).minY
        XCTAssertEqual(tabsTop - controlsBottom, 6, accuracy: 1,
                       "Only the drawer's bottom content padding remains below the collapsed Details row.",
                       file: file, line: line)
        XCTAssertFalse(scroll.isScrollEnabled, file: file, line: line)
        XCTAssertFalse(scroll.bounces, file: file, line: line)
        XCTAssertEqual(scroll.contentOffset, .zero, file: file, line: line)
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

    private func findView(in view: UIView, label: String) -> UIView? {
        if view.accessibilityLabel == label { return view }
        return view.subviews.lazy.compactMap { self.findView(in: $0, label: label) }.first
    }

    private func findView(in view: UIView, identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        return view.subviews.lazy.compactMap { self.findView(in: $0, identifier: identifier) }.first
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
    var browsing = false
    var historyFrame = "Day"
    var publication = 0
    let marker = UIView()
    let browsingMarker = UIView()

    var renderedRevision: String { "\(browsing)-\(historyFrame)-\(publication)" }
    var visibleMarker: UIView { browsing ? browsingMarker : marker }
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
    var revision: String? = nil

    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ view: UIView, context: Context) {
        view.accessibilityValue = String(expanded)
        view.accessibilityHint = revision
    }
}

// Match the drawer's natural VStack/Spacer sizing and live-to-browsing replacement. The
// Details card has no fixed height: wrapping and incoming record data determine its size.
private struct DrawerBrowsingControls: View {
    @Bindable var state: DrawerLayoutState

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                Text("Day · \(state.historyFrame) · All").frame(height: 44)
                Text("History ruler").frame(height: 56)
                Text("October 19 at 5:45 AM").font(.caption).frame(height: 18)
            }
            if state.browsing {
                controls(title: "Play", subject: "point", marker: state.browsingMarker)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else {
                controls(title: "Tracking", subject: "location", marker: state.marker)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.3), value: state.browsing)
    }

    private func controls(title: String, subject: String, marker: UIView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer(minLength: 0)
                DrawerDetailsButton(expanded: $state.expanded, subject: subject)
            }
            .frame(minHeight: 44)
            .background(DrawerLayoutMarker(view: marker, expanded: state.expanded,
                                           revision: state.renderedRevision))
            .padding(.horizontal, 16)
            if state.expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Location details").font(.headline)
                    Text("A retained location with its original time, coordinates and recorded accuracies.")
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(["Speed", "Altitude", "Accuracy", "Device"], id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer(minLength: 0)
                            Text("Record \(state.publication + 1)").monospacedDigit()
                        }
                    }
                }
                .padding(16)
            }
        }
    }
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

@MainActor
final class WhereWolfTabRoutingTests: XCTestCase {
    func testExternalSelectionRoutesBetweenBothMapTabsAndSettings() async throws {
        try await withShell(settleDrawer: false) { shell, _, map in
            var callbacks: [Int] = []
            shell.onSelect = { callbacks.append($0) }
            for selection in [2, 0, 1, 2, 1, 0] {
                self.update(shell, selection: selection, map: map)
                XCTAssertEqual(shell.selectedIndex, selection)
                XCTAssertEqual(shell.drawerTabs.selection, selection)
                XCTAssertEqual(shell.selectedViewController === shell.viewControllers?[2], selection == 2)
            }
            XCTAssertTrue(callbacks.isEmpty, "External selection must not feed back into selectTab.")
        }
    }

    func testBothBarsRouteThroughSelectTabIncludingReselection() async throws {
        try await withShell(settleDrawer: false) { shell, _, map in
            var requests: [Int] = []
            let selectTab: (Int) -> Void = { requests.append($0) }
            shell.onSelect = selectTab
            self.update(shell, selection: 1, map: map)
            shell.drawerTabs.onSelect(2)
            XCTAssertEqual(requests, [2])
            XCTAssertEqual(shell.selectedIndex, 1, "The root owns drawer selection.")
            self.update(shell, selection: 2, activation: requests.count, map: map)

            let settings = try XCTUnwrap(shell.viewControllers?[2])
            shell.tabBarController(shell, didSelect: settings)
            XCTAssertEqual(requests, [2, 2], "Native reselection must reach selectTab to reset Settings navigation.")
            let tracker = try XCTUnwrap(shell.viewControllers?.first)
            shell.selectedViewController = tracker
            shell.tabBarController(shell, didSelect: tracker)
            XCTAssertEqual(requests, [2, 2, 0])
            self.update(shell, selection: 0, activation: requests.count, map: map)
            shell.drawerTabs.onSelect(0)
            XCTAssertEqual(requests, [2, 2, 0, 0], "Drawer reselection must reach selectTab to reopen it.")
        }
    }

    func testSharedMapHostAndMapSurviveEveryTabChange() async throws {
        try await withShell { shell, _, map in
            let host = try XCTUnwrap(self.mapChildren(shell).compactMap { $0 as? FullScreenMapHost }.first)
            let container = try XCTUnwrap(host.parent)
            XCTAssertTrue(shell.currentMap() === map)
            for selection in [1, 2, 0, 2, 1, 0] {
                self.update(shell, selection: selection, map: map)
                shell.view.layoutIfNeeded()
                XCTAssertEqual(self.mapChildren(shell).compactMap { $0 as? FullScreenMapHost }.count, 1)
                XCTAssertTrue(self.mapChildren(shell).contains { $0 === host })
                XCTAssertTrue(shell.currentMap() === map)
                XCTAssertTrue(host.parent === container)
            }
        }
    }

    func testSystemBarAndDrawerVisibilityFollowTheSelectedTab() async throws {
        try await withShell(settleDrawer: false) { shell, panel, map in
            for selection in [0, 2, 1, 2, 0] {
                self.update(shell, selection: selection, map: map)
                if #available(iOS 18.0, *) {
                    XCTAssertEqual(shell.isTabBarHidden, selection < 2)
                } else {
                    XCTAssertEqual(shell.tabBar.isHidden, selection < 2)
                }
                XCTAssertEqual(panel.view.isHidden, selection == 2)
                XCTAssertEqual(shell.currentDrawerGeometry() == nil, selection == 2)
                let settings = try XCTUnwrap(shell.viewControllers?[2])
                XCTAssertEqual(settings.additionalSafeAreaInsets, .zero)
            }
            XCTAssertEqual(shell.tabBar.items?.map(\.title), ["Tracker", "Trip", "Settings"])
            XCTAssertEqual(shell.tabBar.items?.map(\.tag), [0, 1, 2])
        }
    }

    func testOnlySwitchesBetweenMapTabsFadeTheDrawerControls() async throws {
        try await withShell { shell, panel, map in
            self.update(shell, selection: 1, map: map)
            XCTAssertNotNil(self.outgoingControls(in: panel.view), "Tracker to Trip fades the controls.")
            self.update(shell, selection: 2, map: map)
            self.update(shell, selection: 0, map: map)
            XCTAssertNil(self.outgoingControls(in: panel.view),
                         "Settings returns through the bar handoff's own fade, without a lingering snapshot.")
        }
    }

    func testSettingsStopsAnUnfinishedDrawerSpring() async throws {
        try await withShell { shell, panel, _ in
            let grabber = try XCTUnwrap(self.findGrabber(in: panel.view))
            grabber.accessibilityDecrement()
            XCTAssertTrue(panel.isAnimating)
            self.update(shell, selection: 2, completeTransition: false)
            panel.advanceAnimation(at: 1_000)
            XCTAssertTrue(panel.view.isHidden)
            XCTAssertFalse(panel.isAnimating)
            shell.view.layoutIfNeeded()
            panel.view.setNeedsLayout()
            panel.view.layoutIfNeeded()
            XCTAssertFalse(panel.isAnimating)
            self.update(shell, selection: 0)
            XCTAssertFalse(panel.view.isHidden)
            XCTAssertEqual(grabber.accessibilityValue, "Collapsed")
        }
    }

    func testCurrentMapTabActivationReopensCollapsedDrawer() async throws {
        try await withShell { shell, panel, _ in
            let grabber = try XCTUnwrap(self.findGrabber(in: panel.view))
            grabber.accessibilityDecrement()
            try await self.waitForLayout(panel)
            XCTAssertEqual(grabber.accessibilityValue, "Collapsed")
            var activation = 0
            shell.onSelect = { _ in activation += 1 }
            self.update(shell, selection: 1)
            grabber.accessibilityDecrement()
            try await self.waitForLayout(panel)
            shell.drawerTabs.onSelect(1)
            self.update(shell, selection: 1, activation: activation)
            try await self.waitForLayout(panel)
            XCTAssertEqual(grabber.accessibilityValue, "Expanded")
        }
    }

    func testBarHandoffReservesSettingsSafeAreaAndReturnsClosed() async throws {
        try await withShell(settleDrawer: false) { shell, panel, map in
            shell.view.layoutIfNeeded()
            panel.animationClock = { 0 }
            self.update(shell, selection: 2, map: map, completeTransition: false)
            let settings = try XCTUnwrap(shell.viewControllers?[2])
            let safeBottom = settings.view.safeAreaInsets.bottom
            if !UIAccessibility.isReduceMotionEnabled {
                XCTAssertTrue(panel.isBarTransitioning)
                XCTAssertFalse(panel.view.isHidden)
                XCTAssertEqual(shell.tabBar.alpha, 0)
                XCTAssertTrue(shell.tabBar.accessibilityElementsHidden)
                if #available(iOS 18.0, *) { XCTAssertFalse(shell.isTabBarHidden) }
                shell.tabBar.alpha = 1
                shell.view.setNeedsLayout()
                shell.view.layoutIfNeeded()
                XCTAssertEqual(shell.tabBar.alpha, 0)
                shell.tabBar.alpha = 1
                panel.advanceAnimation(at: 0.04)
                XCTAssertEqual(shell.tabBar.alpha, 0)
            }
            panel.advanceAnimation(at: 100)
            XCTAssertTrue(panel.view.isHidden)
            XCTAssertFalse(panel.isAnimating)
            XCTAssertEqual(shell.tabBar.alpha, 1)
            XCTAssertEqual(settings.additionalSafeAreaInsets, .zero)
            XCTAssertEqual(settings.view.safeAreaInsets.bottom, safeBottom, accuracy: 0.5)
            let platter = try XCTUnwrap(shell.systemPlatterGeometry)
            self.assertGeometry(panel.currentBarGeometry(), equals: platter)
            XCTAssertNil(panel.view.hitTest(CGPoint(x: platter.frame.midX, y: platter.frame.midY), with: nil))

            self.update(shell, selection: 0, map: map, completeTransition: false)
            if !UIAccessibility.isReduceMotionEnabled {
                XCTAssertFalse(panel.view.isHidden)
                XCTAssertEqual(shell.tabBar.alpha, 0)
                self.assertGeometry(panel.currentBarGeometry(), equals: platter)
            }
            panel.advanceAnimation(at: 100)
            XCTAssertFalse(panel.view.isHidden)
            XCTAssertFalse(panel.isAnimating)
            self.assertGeometry(panel.currentBarGeometry(), equals: panel.closedBarGeometry())
            let grabber = try XCTUnwrap(self.findGrabber(in: panel.view))
            XCTAssertEqual(grabber.accessibilityValue, "Collapsed")
            if #available(iOS 18.0, *) { XCTAssertTrue(shell.isTabBarHidden) }
            else { XCTAssertTrue(shell.tabBar.isHidden) }
        }
    }

    func testBarInterruptionRetargetsTheCurrentFrame() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { throw XCTSkip("Reduce Motion swaps bars immediately.") }
        try await withShell(settleDrawer: false) { shell, panel, map in
            shell.view.layoutIfNeeded()
            panel.animationClock = { 0 }
            self.update(shell, selection: 2, map: map, completeTransition: false)
            panel.advanceAnimation(at: 0.04)
            let presented = panel.currentBarGeometry()
            self.update(shell, selection: 1, map: map, completeTransition: false)
            self.assertGeometry(panel.currentBarGeometry(), equals: presented)
            XCTAssertTrue(panel.isBarTransitioning)
            XCTAssertFalse(panel.view.isHidden)
            XCTAssertEqual(shell.tabBar.alpha, 0)
            panel.advanceAnimation(at: 100)
            self.assertGeometry(panel.currentBarGeometry(), equals: panel.closedBarGeometry())
            XCTAssertFalse(panel.isAnimating)
        }
    }

    func testReturnFromCompletedSettingsHandoffUsesFreshPlatterAfterReselection() async throws {
        try await withShell(settleDrawer: false) { shell, panel, map in
            shell.view.layoutIfNeeded()
            panel.animationClock = { 0 }
            self.update(shell, selection: 2, activation: 1, map: map)
            let platter = SystemTabBarGeometry.measure(shell.tabBar, in: shell.view)
            self.assertGeometry(panel.currentBarGeometry(), equals: platter)
            XCTAssertFalse(panel.isAnimating)
            let completedRevision = panel.barTransitionRevision

            let settings = try XCTUnwrap(shell.viewControllers?[2])
            shell.tabBarController(shell, didSelect: settings)
            self.update(shell, selection: 2, activation: 2, map: map)
            self.update(shell, selection: 2, activation: 2, map: map)
            panel.transitionBar(toSystem: true, systemGeometry: platter, animated: true)
            shell.view.setNeedsLayout()
            shell.view.layoutIfNeeded()
            XCTAssertEqual(panel.barTransitionRevision, completedRevision)
            XCTAssertFalse(panel.isAnimating)
            XCTAssertTrue(panel.view.isHidden)
            XCTAssertEqual(shell.tabBar.alpha, 1)

            let tracker = try XCTUnwrap(shell.viewControllers?.first)
            shell.tabBarController(shell, didSelect: tracker)
            self.assertGeometry(try XCTUnwrap(shell.systemPlatterGeometry), equals: platter)
            if !UIAccessibility.isReduceMotionEnabled {
                self.assertGeometry(panel.currentBarGeometry(), equals: platter)
            }
            let returnRevision = panel.barTransitionRevision
            // Replay the old SwiftUI render between native selection and its acknowledgement.
            self.update(shell, selection: 2, activation: 2, map: map, completeTransition: false)
            XCTAssertEqual(shell.selectedIndex, 0)
            XCTAssertEqual(panel.barTransitionRevision, returnRevision)
            if !UIAccessibility.isReduceMotionEnabled {
                self.assertGeometry(panel.currentBarGeometry(), equals: platter)
                XCTAssertEqual(shell.tabBar.alpha, 0)
            }
            panel.advanceAnimation(at: 100)
            self.assertGeometry(panel.currentBarGeometry(), equals: panel.closedBarGeometry())
            XCTAssertFalse(panel.isAnimating)
            // A delayed acknowledgement must not reopen the just-arrived closed capsule.
            self.update(shell, selection: 0, activation: 3, map: map, completeTransition: false)
            XCTAssertEqual(panel.barTransitionRevision, returnRevision)
            self.assertGeometry(panel.currentBarGeometry(), equals: panel.closedBarGeometry())
            XCTAssertFalse(panel.isAnimating)
            self.update(shell, selection: 2, activation: 2, map: map, completeTransition: false)
            XCTAssertEqual(shell.selectedIndex, 0)
            XCTAssertEqual(panel.barTransitionRevision, returnRevision)
            XCTAssertFalse(panel.isAnimating)

            let trip = try XCTUnwrap(shell.viewControllers?[1])
            shell.tabBarController(shell, didSelect: trip)
            // A newer external tab activation can replace an unacknowledged native request.
            self.update(shell, selection: 2, activation: 5, map: map)
            XCTAssertEqual(shell.selectedIndex, 2)
            XCTAssertTrue(panel.view.isHidden)
            XCTAssertEqual(shell.tabBar.alpha, 1)
            XCTAssertFalse(panel.isAnimating)
        }
    }

    func testRetargetDuringAdvanceOrLandingCannotCompleteTheReplacedHandoff() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { throw XCTSkip("Reduce Motion swaps bars immediately.") }
        for trigger in [1, 2] {
            try await withShell(settleDrawer: false) { shell, panel, _ in
                shell.view.layoutIfNeeded()
                panel.animationClock = { 0 }
                let platter = DrawerBarGeometry(frame: CGRect(x: 64, y: 791, width: 274, height: 62), radius: 31)
                let originalFrame = panel.onBarTransitionFrame
                let originalCompletion = panel.onBarTransitionCompletion
                defer {
                    panel.onBarTransitionFrame = originalFrame
                    panel.onBarTransitionCompletion = originalCompletion
                }
                var completions: [Bool] = []
                panel.onBarTransitionCompletion = { completions.append($0) }
                panel.transitionBar(toSystem: true, systemGeometry: platter, animated: true)
                var frames = 0
                panel.onBarTransitionFrame = {
                    originalFrame?()
                    frames += 1
                    if frames == trigger {
                        panel.transitionBar(toSystem: false, systemGeometry: platter, animated: true)
                    }
                }
                panel.advanceAnimation(at: 100)
                XCTAssertTrue(panel.isBarTransitioning)
                XCTAssertFalse(panel.view.isHidden)
                XCTAssertTrue(completions.isEmpty)
                panel.advanceAnimation(at: 100)
                XCTAssertEqual(completions, [false])
                self.assertGeometry(panel.currentBarGeometry(), equals: panel.closedBarGeometry())
                XCTAssertFalse(panel.isAnimating)
            }
        }
    }

    func testDrawerSettleCannotCancelTheBarTransitionStartedDuringItsLayout() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { throw XCTSkip("Reduce Motion swaps bars immediately.") }
        try await withShell { shell, panel, _ in
            panel.animationClock = { 0 }
            let platter = DrawerBarGeometry(frame: CGRect(x: 64, y: 791, width: 274, height: 62), radius: 31)
            let originalTop = panel.onPresentedTopChange
            let originalCompletion = panel.onBarTransitionCompletion
            defer {
                panel.onPresentedTopChange = originalTop
                panel.onBarTransitionCompletion = originalCompletion
            }
            var startedBar = false
            var completions: [Bool] = []
            panel.onBarTransitionCompletion = { completions.append($0) }
            let grabber = try XCTUnwrap(self.findGrabber(in: panel.view))
            grabber.accessibilityDecrement()
            panel.onPresentedTopChange = { top in
                originalTop?(top)
                guard !startedBar else { return }
                startedBar = true
                panel.transitionBar(toSystem: true, systemGeometry: platter, animated: true)
            }
            panel.advanceAnimation(at: 100)
            XCTAssertTrue(startedBar)
            XCTAssertTrue(panel.isBarTransitioning)
            XCTAssertFalse(panel.view.isHidden)
            XCTAssertTrue(completions.isEmpty)
            panel.advanceAnimation(at: 100)
            XCTAssertEqual(completions, [true])
            self.assertGeometry(panel.currentBarGeometry(), equals: platter)
            XCTAssertTrue(panel.view.isHidden)
            XCTAssertFalse(panel.isAnimating)
        }
    }

    func testInsightsUsesTheSameNativeHandoffAndStableSettingsIdentity() async throws {
        try await withShell { shell, panel, map in
            self.updateInsights(shell, selection: 0, available: true)
            XCTAssertEqual(shell.tabBar.items?.map(\.tag), [0, 1, 3, 2])
            XCTAssertEqual(shell.tabBar.items?.map(\.title), ["Tracker", "Trip", "Insights", "Settings"])
            let host = try XCTUnwrap(self.mapChildren(shell).compactMap { $0 as? FullScreenMapHost }.first)
            panel.animationClock = { 0 }
            self.updateInsights(shell, selection: 3, available: true, completeTransition: false)
            let insights = try XCTUnwrap(shell.viewControllers?[2])
            let safeBottom = insights.view.safeAreaInsets.bottom
            XCTAssertEqual(insights.tabBarItem.tag, 3)
            XCTAssertTrue(host.view.isHidden)
            XCTAssertNil(shell.currentDrawerGeometry())
            if !UIAccessibility.isReduceMotionEnabled {
                XCTAssertTrue(panel.isBarTransitioning)
                XCTAssertEqual(shell.tabBar.alpha, 0)
            }
            panel.advanceAnimation(at: 100)
            XCTAssertTrue(panel.view.isHidden)
            XCTAssertEqual(shell.tabBar.alpha, 1)
            XCTAssertEqual(insights.additionalSafeAreaInsets, .zero)
            XCTAssertEqual(insights.view.safeAreaInsets.bottom, safeBottom, accuracy: 0.5)
            self.updateInsights(shell, selection: 2, available: true)
            XCTAssertEqual(shell.selectedIndex, 3)
            XCTAssertEqual(shell.selectedViewController?.tabBarItem.tag, 2)
            XCTAssertFalse(panel.isBarTransitioning)
            self.updateInsights(shell, selection: 0, available: true)
            XCTAssertTrue(shell.currentMap() === map)
            XCTAssertFalse(host.view.isHidden)
            let grabber = try XCTUnwrap(self.findGrabber(in: panel.view))
            XCTAssertEqual(grabber.accessibilityValue, "Collapsed")
        }
    }

    func testInsightsRemovalDuringHandoffFinishesWithoutAStaleSpring() async throws {
        try await withShell { shell, panel, _ in
            self.updateInsights(shell, selection: 0, available: true)
            panel.animationClock = { 0 }
            self.updateInsights(shell, selection: 3, available: true, completeTransition: false)
            panel.advanceAnimation(at: 0.04)
            self.updateInsights(shell, selection: 3, available: false, completeTransition: false)
            XCTAssertEqual(shell.selectedViewController?.tabBarItem.tag, 2)
            XCTAssertEqual(shell.drawerTabs.selection, 2)
            XCTAssertEqual(shell.tabBar.items?.map(\.tag), [0, 1, 2])
            XCTAssertFalse(panel.isBarTransitioning)
            XCTAssertTrue(panel.view.isHidden)
            XCTAssertEqual(shell.tabBar.alpha, 1)
            panel.advanceAnimation(at: 100)
            XCTAssertTrue(panel.view.isHidden)
            XCTAssertEqual(shell.tabBar.alpha, 1)
        }
    }

    func testOptionalTabKeepsEagerNativeSelectionAheadOfStaleSwiftUI() async throws {
        try await withShell { shell, panel, _ in
            self.updateInsights(shell, selection: 2, available: true)
            var requested: Int?
            shell.onSelect = { requested = $0 }
            let insights = try XCTUnwrap(shell.viewControllers?[2])
            shell.selectedViewController = insights
            shell.tabBarController(shell, didSelect: insights)
            XCTAssertEqual(requested, 3)
            XCTAssertEqual(shell.drawerTabs.selection, 3)
            self.updateInsights(shell, selection: 2, available: true, activation: 0)
            XCTAssertEqual(shell.selectedViewController?.tabBarItem.tag, 3)
            self.updateInsights(shell, selection: 3, available: true, activation: 1)
            let tracker = try XCTUnwrap(shell.viewControllers?.first)
            shell.selectedViewController = tracker
            shell.tabBarController(shell, didSelect: tracker)
            self.updateInsights(shell, selection: 3, available: true, activation: 1)
            XCTAssertEqual(shell.selectedViewController?.tabBarItem.tag, 0)
            XCTAssertEqual(shell.drawerTabs.selection, 0)
            self.updateInsights(shell, selection: 0, available: true, activation: 2)
            panel.advanceAnimation(at: 100)
            XCTAssertFalse(panel.view.isHidden)
        }
    }

    func testAddingInsightsPreservesCollapsedMapAndRemovingItPreservesSettings() async throws {
        try await withShell { shell, panel, _ in
            let grabber = try XCTUnwrap(self.findGrabber(in: panel.view))
            grabber.accessibilityDecrement()
            try await self.waitForLayout(panel)
            self.updateInsights(shell, selection: 0, available: true)
            XCTAssertEqual(grabber.accessibilityValue, "Collapsed")
            XCTAssertEqual(shell.selectedIndex, 0)
            self.updateInsights(shell, selection: 2, available: true)
            self.updateInsights(shell, selection: 2, available: false)
            XCTAssertEqual(shell.selectedIndex, 2)
            XCTAssertEqual(shell.drawerTabs.selection, 2)
            XCTAssertTrue(panel.view.isHidden)
        }
    }

    private func updateInsights(_ shell: WhereWolfShellController, selection: Int, available: Bool,
                                activation: Int = 0, completeTransition: Bool = true) {
        let map = shell.currentMap() ?? MKMapView()
        shell.update(map: AnyView(ShellTestMap(map: map)), controls: AnyView(Text("Controls").frame(height: 100)),
                     settings: AnyView(NavigationStack { Text("Settings") }), selection: selection,
                     activation: activation, controlsID: selection < 2 ? selection : 0, contentInteracting: false,
                     insights: available ? AnyView(NavigationStack { Text("Insights").navigationTitle("Insights") }) : nil)
        if completeTransition { panelController(in: shell)?.advanceAnimation(at: 1_000) }
    }

    private func update(_ shell: WhereWolfShellController, selection: Int, activation: Int = 0, map: MKMapView? = nil,
                        completeTransition: Bool = true) {
        let map = map ?? shell.currentMap() ?? MKMapView()
        shell.update(map: AnyView(ShellTestMap(map: map)), controls: AnyView(Text("Controls").frame(height: 100)),
                     settings: AnyView(NavigationStack { Text("Settings") }), selection: selection,
                     activation: activation, controlsID: selection < 2 ? selection : shell.drawerTabs.selection,
                     contentInteracting: false)
        if completeTransition {
            panelController(in: shell)?.advanceAnimation(at: 1_000)
        }
    }

    private func withShell(settleDrawer: Bool = true,
                           _ run: (WhereWolfShellController, MapControlPanelController, MKMapView) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let map = MKMapView()
        let shell = WhereWolfShellController(
            map: AnyView(ShellTestMap(map: map)), controls: AnyView(Text("Controls").frame(height: 100)),
            settings: AnyView(NavigationStack { Text("Settings") }), selection: 0, controlsID: 0, onSelect: { _ in }
        )
        let panel = try XCTUnwrap(panelController(in: shell))
        XCTAssertTrue(panel.view.superview === shell.view)
        let clock = DrawerAnimationClock()
        panel.animationClock = { clock.timestamp }
        clock.start()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = shell
        window.makeKeyAndVisible()
        defer {
            clock.stop()
            panel.setVisible(false)
            window.isHidden = true
            previous?.makeKey()
        }
        if settleDrawer {
            try await waitForLayout(panel) { shell.currentMap() === map }
        }
        try await run(shell, panel, map)
    }

    private func waitForLayout(_ panel: MapControlPanelController, ready: @escaping () -> Bool = { true }) async throws {
        let settled = expectation(description: "Drawer layout settled")
        let observer = LayoutFrameObserver {
            panel.advanceAnimation(at: 1_000)
            if panel.isLayoutSettled && ready() { settled.fulfill(); return true }
            return false
        }
        observer.start()
        defer { observer.stop() }
        await fulfillment(of: [settled], timeout: 15)
        guard observer.completed else { throw NSError(domain: "WhereWolfTabRoutingTests", code: 1) }
    }

    private func assertGeometry(_ actual: DrawerBarGeometry, equals expected: DrawerBarGeometry,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.frame.minX, expected.frame.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.frame.minY, expected.frame.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.frame.width, expected.frame.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.frame.height, expected.frame.height, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.radius, expected.radius, accuracy: 1, file: file, line: line)
    }

    private func panelController(in shell: WhereWolfShellController) -> MapControlPanelController? {
        shell.view.subviews.lazy.compactMap { $0.next as? MapControlPanelController }.first
    }

    private func mapChildren(_ shell: WhereWolfShellController) -> [UIViewController] {
        var visited: Set<ObjectIdentifier> = []
        var result: [UIViewController] = []
        @MainActor func visit(_ controller: UIViewController) {
            guard visited.insert(ObjectIdentifier(controller)).inserted else { return }
            result.append(controller)
            controller.children.forEach { visit($0) }
        }
        visit(shell)
        shell.viewControllers?.forEach { visit($0) }
        return result
    }

    private func findGrabber(in view: UIView) -> UIView? {
        if view.accessibilityLabel == "Controls panel" { return view }
        return view.subviews.lazy.compactMap { self.findGrabber(in: $0) }.first
    }

    private func outgoingControls(in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == "wherewolf.panel.outgoing-controls" { return view }
        return view.subviews.lazy.compactMap { self.outgoingControls(in: $0) }.first
    }
}

private struct ShellTestMap: UIViewRepresentable {
    let map: MKMapView
    func makeUIView(context: Context) -> MKMapView { map }
    func updateUIView(_ view: MKMapView, context: Context) { }
}

@MainActor
final class DrawerBarTransitionTests: XCTestCase {
    private let expanded = DrawerBarGeometry(frame: CGRect(x: 10, y: 480, width: 382, height: 386), radius: 46)
    private let system = DrawerBarGeometry(frame: CGRect(x: 36, y: 780, width: 330, height: 62), radius: 31)
    private let closed = DrawerBarGeometry(frame: CGRect(x: 28, y: 770, width: 346, height: 76), radius: 38)

    func testGeometryBlendIncludesEveryComponentAndBothEnds() {
        let tween = DrawerBarTween(from: expanded, to: system, toSystem: true)
        XCTAssertEqual(tween.geometry(at: 0), expanded)
        XCTAssertEqual(tween.geometry(at: 1), system)
        let middle = tween.geometry(at: 0.5)
        XCTAssertEqual(middle.frame, CGRect(x: 23, y: 630, width: 356, height: 224))
        XCTAssertEqual(middle.radius, 38.5)
    }

    func testRetargetPreservesGeometryAndOpacity() {
        let tween = DrawerBarTween(from: expanded, to: system, toSystem: true, initialContentOpacity: 1)
        let retargeted = tween.retarget(to: closed, toSystem: false, at: 0.8)
        XCTAssertEqual(retargeted.geometry(at: 0), tween.geometry(at: 0.8))
        XCTAssertEqual(retargeted.opacity(at: 0), tween.opacity(at: 0.8))
        XCTAssertEqual(retargeted.opacity(at: 0, content: true), tween.opacity(at: 0.8, content: true))
        XCTAssertEqual(retargeted.geometry(at: 1), closed)
        XCTAssertEqual(retargeted.opacity(at: 1), 1)
    }

    func testOvershootKeepsEveryGeometryComponentWithinThreePoints() {
        let tween = DrawerBarTween(from: expanded, to: system, toSystem: true)
        let overshot = tween.geometry(at: 1 + tween.overshoot)
        XCTAssertEqual(overshot.frame.minX, system.frame.minX, accuracy: 3.001)
        XCTAssertEqual(overshot.frame.minY, system.frame.minY, accuracy: 3.001)
        XCTAssertEqual(overshot.frame.width, system.frame.width, accuracy: 3.001)
        XCTAssertEqual(overshot.frame.height, system.frame.height, accuracy: 3.001)
        XCTAssertEqual(overshot.radius, system.radius, accuracy: 3.001)
    }

    func testContentAndTabsFadeOutOnlyNearTheSystemEnd() {
        let tween = DrawerBarTween(from: expanded, to: system, toSystem: true, initialContentOpacity: 1)
        XCTAssertEqual(tween.opacity(at: 0.7), 1)
        XCTAssertEqual(tween.opacity(at: 0.7, content: true), 1)
        XCTAssertLessThan(tween.opacity(at: 0.85), 1)
        XCTAssertGreaterThan(tween.opacity(at: 0.85), 0)
        XCTAssertEqual(tween.opacity(at: 1), 0)
        XCTAssertEqual(tween.opacity(at: 1, content: true), 0)
    }

    func testPlatterMeasurementUsesThreeItemControlsWhileBarIsTransparent() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let bar = UIView(frame: CGRect(x: 0, y: 791, width: 402, height: 83))
        container.addSubview(bar)
        bar.alpha = 0
        for x in [68.0, 154.0, 240.0] {
            let item = UIControl(frame: CGRect(x: x, y: 4, width: 94, height: 54))
            bar.addSubview(item)
        }
        let measured = SystemTabBarGeometry.measure(bar, in: container)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(measured, DrawerBarGeometry(frame: CGRect(x: 64, y: 791, width: 274, height: 62), radius: 31))
        } else {
            XCTAssertEqual(measured, DrawerBarGeometry(frame: bar.frame, radius: 0))
        }
    }

    func testPlatterMeasurementIncludesButtonTraitsAndNestedCoordinates() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let bar = UIView(frame: CGRect(x: 0, y: 791, width: 402, height: 83))
        container.addSubview(bar)
        let items = UIView(frame: CGRect(x: 8, y: 4, width: 386, height: 54))
        bar.addSubview(items)
        for x in [60.0, 146.0, 232.0] {
            let item = UIView(frame: CGRect(x: x, y: 0, width: 94, height: 54))
            item.accessibilityTraits = .button
            items.addSubview(item)
        }
        items.addSubview(UIControl(frame: .zero))
        let hidden = UIControl(frame: bar.bounds)
        hidden.isHidden = true
        bar.addSubview(hidden)
        let measured = SystemTabBarGeometry.measure(bar, in: container)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(measured, DrawerBarGeometry(frame: CGRect(x: 64, y: 791, width: 274, height: 62), radius: 31))
        } else {
            XCTAssertEqual(measured, DrawerBarGeometry(frame: bar.frame, radius: 0))
        }
    }

    func testPlatterMeasurementIgnoresNativePressAndCompensatingButtonTransforms() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let bar = UIView(frame: CGRect(x: 0, y: 791, width: 402, height: 83))
        container.addSubview(bar)
        for x in [68.0, 154.0, 240.0] {
            let item = UIControl(frame: CGRect(x: x, y: 4, width: 94, height: 54))
            item.transform = CGAffineTransform(scaleX: 1.16, y: 1.16)
            let button = UIView(frame: item.bounds)
            button.accessibilityTraits = .button
            button.transform = CGAffineTransform(scaleX: 1 / 1.16, y: 1 / 1.16)
            item.addSubview(button)
            bar.addSubview(item)
        }
        let measured = SystemTabBarGeometry.measure(bar, in: container)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(measured, DrawerBarGeometry(frame: CGRect(x: 64, y: 791, width: 274, height: 62), radius: 31))
        } else {
            XCTAssertEqual(measured, DrawerBarGeometry(frame: bar.frame, radius: 0))
        }
    }

    func testPlatterMeasurementFallsBackToTheContainerWithoutItems() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let bar = UIView(frame: CGRect(x: 0, y: 791, width: 402, height: 83))
        container.addSubview(bar)
        bar.addSubview(UIControl(frame: .zero))
        let measured = SystemTabBarGeometry.measure(bar, in: container)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(measured, DrawerBarGeometry(frame: bar.frame, radius: 41.5))
        } else {
            XCTAssertEqual(measured, DrawerBarGeometry(frame: bar.frame, radius: 0))
        }
    }
}
