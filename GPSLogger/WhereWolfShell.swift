import SwiftUI
import UIKit
import MapKit

@Observable
final class MapDrawerGeometry {
    var userLocation: CLLocation?
    @ObservationIgnored var read: (() -> (top: CGFloat, collapsedTop: CGFloat)?)?
    @ObservationIgnored var readMap: (() -> MKMapView?)?
}

struct WhereWolfShell: UIViewControllerRepresentable {
    let drawerGeometry: MapDrawerGeometry
    var setupPresented = false
    var selection: Int
    var activation: Int
    var controlsID: Int
    var contentInteracting: Bool
    let map: AnyView
    let controls: AnyView
    let onSelect: (Int) -> Void
    let settings: AnyView

    func makeUIViewController(context: Context) -> WhereWolfShellController {
        let controller = WhereWolfShellController(
            map: map, controls: controls, settings: settings,
            selection: selection, controlsID: controlsID, onSelect: onSelect
        )
        controller.setSetupPresented(setupPresented)
        drawerGeometry.readMap = { [weak controller] in controller?.currentMap() }
        controller.onUserLocation = { [weak geometry = drawerGeometry] in geometry?.userLocation = $0 }
        drawerGeometry.read = { [weak controller] in
            controller?.currentDrawerGeometry()
        }
        return controller
    }

    func updateUIViewController(_ controller: WhereWolfShellController, context: Context) {
        controller.setSetupPresented(setupPresented)
        drawerGeometry.readMap = { [weak controller] in controller?.currentMap() }
        controller.onUserLocation = { [weak geometry = drawerGeometry] in geometry?.userLocation = $0 }
        drawerGeometry.read = { [weak controller] in controller?.currentDrawerGeometry() }
        controller.onSelect = onSelect
        controller.update(map: map, controls: controls, settings: settings,
                          selection: selection, activation: activation,
                          controlsID: controlsID, contentInteracting: contentInteracting)
    }
}

// The map keeps one container across its placeholders. The drawer stays above all tab pages
// while its glass changes into the native Settings bar, whose layout owns the Settings safe area.
final class WhereWolfShellController: UITabBarController, UITabBarControllerDelegate {
    var onSelect: (Int) -> Void
    var onUserLocation: ((CLLocation?) -> Void)? {
        get { mapHost.onUserLocation }
        set { mapHost.onUserLocation = newValue }
    }

    private let mapPage = UIViewController()
    private let mapHost: FullScreenMapHost
    private let settingsHost: UIHostingController<AnyView>
    private let panel: MapControlPanelController
    private var setupPresented = false
    private var currentSelection = -1
    private var renderedSelection: Int
    private var currentActivation = 0
    private var pendingNativeSelection: (index: Int, activation: Int)?
    private var selectingNative = false
    private var currentControlsID: Int
    private var collapsedTop: CGFloat?
    private(set) var systemPlatterGeometry: DrawerBarGeometry?
    private var systemTabsInset = SystemTabBarGeometry.platterPadding
    private var updatingBar = false
    private var suppressSystemBar = true
    private var barLayoutSize = CGSize.zero
#if targetEnvironment(simulator)
    private let tabAudit = ShellTabAuditView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
#endif

    private(set) var drawerTabs: DrawerTabStrip

    init(map: AnyView, controls: AnyView, settings: AnyView,
         selection: Int, controlsID: Int, onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
        mapHost = FullScreenMapHost(rootView: map)
        settingsHost = UIHostingController(rootView: settings)
        let tabs = DrawerTabStrip(selection: selection, onSelect: onSelect)
        drawerTabs = tabs
        panel = MapControlPanelController(controls: controls, tabs: AnyView(tabs.tint(.blue)))
        currentControlsID = controlsID
        renderedSelection = selection
        super.init(nibName: nil, bundle: nil)
        let pages = [UIViewController(), UIViewController(), settingsHost]
        for (page, tab) in zip(pages, DrawerTabStrip.tabs) {
            page.tabBarItem = UITabBarItem(title: tab.title, image: UIImage(systemName: tab.symbol), tag: tab.id)
        }
        panel.onCollapsedTopChange = { [weak self] top in
            self?.collapsedTop = top
            self?.updateMapClosedTop()
        }
        panel.onPresentedTopChange = { [weak self] top in
            self?.updateMapClearance(top)
        }
        panel.onBarTransitionCompletion = { [weak self] toSystem in self?.finishBarTransition(toSystem: toSystem) }
        panel.onBarTransitionFrame = { [weak self] in self?.applySystemBarSuppression() }
#if targetEnvironment(simulator)
        panel.barAuditMetadata = { [weak self] in
            guard let self else { return [:] }
            return ["systemBarVisible": self.systemBarIsVisible ? 1 : 0,
                    "systemBarAlpha": self.tabBar.alpha,
                    "settingsSafeBottom": self.settingsHost.view.safeAreaInsets.bottom]
        }
#endif
        setViewControllers(pages, animated: false)
        delegate = self
        apply(selection: selection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        tabBar.accessibilityIdentifier = "wherewolf.system.tabs"
        install(mapHost, in: mapPage)
        install(panel, in: self)
#if targetEnvironment(simulator)
        tabAudit.isAccessibilityElement = true
        tabAudit.accessibilityLabel = "Tab presentation"
        tabAudit.isUserInteractionEnabled = false
        tabAudit.value = { [weak self] in self?.tabAuditValue() ?? "" }
        view.addSubview(tabAudit)
#endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applySystemBarSuppression()
        view.bringSubviewToFront(panel.view)
#if targetEnvironment(simulator)
        view.bringSubviewToFront(tabAudit)
#endif
        if setupPresented { panel.view.isHidden = true }
        updateMapClearance(panel.currentGeometry().top)
        guard !updatingBar, view.bounds.size != barLayoutSize else { return }
        barLayoutSize = view.bounds.size
        if currentSelection == 2 {
            measureSystemBar()
        }
        if panel.isBarTransitioning, let geometry = systemPlatterGeometry {
            panel.transitionBar(toSystem: currentSelection == 2, systemGeometry: geometry,
                                systemTabsInset: systemTabsInset, animated: true)
        }
    }

    func setSetupPresented(_ presented: Bool) {
        guard setupPresented != presented else { return }
        setupPresented = presented
        mapHost.view.isUserInteractionEnabled = !presented
        panel.view.isHidden = presented || (currentSelection == 2 && !panel.isBarTransitioning)
        applySystemBarSuppression()
    }

    func update(map: AnyView, controls: AnyView, settings: AnyView,
                selection: Int, activation: Int, controlsID: Int, contentInteracting: Bool) {
        // Native selection moves UIKit before SwiftUI publishes the matching selection.
        guard activation >= currentActivation else { return }
        if selectingNative, selection != currentSelection { return }
        if let pending = pendingNativeSelection {
            guard activation >= pending.activation,
                  selection == pending.index || (!selectingNative && activation > pending.activation) else { return }
            pendingNativeSelection = nil
        }
        let previousRenderedSelection = renderedSelection
        mapHost.rootView = map
        if selection != renderedSelection || controlsID != currentControlsID {
            renderedSelection = selection
            currentControlsID = controlsID
            settingsHost.rootView = settings
            drawerTabs = DrawerTabStrip(selection: selection, onSelect: onSelect)
            if selection < 2 {
                panel.update(controls: controls, tabs: AnyView(drawerTabs.tint(.blue)))
            } else {
                panel.updateTabs(AnyView(drawerTabs.tint(.blue)))
            }
        }
        panel.setContentInteracting(contentInteracting)
        apply(selection: selection)
        // Tapping the current map tab reopens a collapsed drawer.
        if activation != currentActivation {
            currentActivation = activation
            if currentSelection < 2, selection == previousRenderedSelection { panel.expand() }
        }
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        guard let index = viewControllers?.firstIndex(of: viewController) else { return }
        // UIKit has already shown the placeholder page; move the map in before SwiftUI's update.
        pendingNativeSelection = (index, currentActivation + 1)
        selectingNative = true
        defer { selectingNative = false }
        apply(selection: index)
        onSelect(index)
    }

    private func apply(selection requested: Int) {
        let index = min(2, max(0, requested))
        guard index != currentSelection else { return }
        let previous = currentSelection
        let fromSystem = previous == 2 && !suppressSystemBar
        currentSelection = index
        loadViewIfNeeded()
        updatingBar = true
        defer { updatingBar = false }
        let showsMap = index < 2
        let crossesSettings = previous >= 0 && ((previous == 2) != (index == 2))
        let continuesTween = panel.isBarTransitioning
        UIView.performWithoutAnimation {
            // Reserve the native bar's final safe area before Settings draws its first frame.
            if index == 2 { setSystemBar(hidden: false, transparent: true) }
            if previous == 2 {
                tabBar.layoutIfNeeded()
                measureSystemBar()
            }
            if showsMap, let page = viewControllers?[index], mapPage.parent !== page {
                if mapPage.parent != nil {
                    mapPage.willMove(toParent: nil)
                    mapPage.view.removeFromSuperview()
                    mapPage.removeFromParent()
                }
                install(mapPage, in: page)
            }
            selectedIndex = index
            mapHost.view.isHidden = !showsMap
            if showsMap { setSystemBar(hidden: true) }
            view.layoutIfNeeded()
            barLayoutSize = view.bounds.size
            if index == 2 {
                tabBar.layoutIfNeeded()
                measureSystemBar()
            }
            if (crossesSettings || continuesTween), let geometry = systemPlatterGeometry {
                panel.transitionBar(toSystem: !showsMap, systemGeometry: geometry, systemTabsInset: systemTabsInset,
                                    animated: !UIAccessibility.isReduceMotionEnabled, fromSystem: fromSystem)
            } else {
                panel.setVisible(showsMap)
                setSystemBar(hidden: showsMap)
                if previous >= 0, previous < 2, showsMap { panel.expand() }
            }
            view.bringSubviewToFront(panel.view)
        }
        view.setNeedsLayout()
    }

    private func measureSystemBar() {
        let geometry = SystemTabBarGeometry.measure(tabBar, in: view)
        systemPlatterGeometry = geometry
        systemTabsInset = SystemTabBarGeometry.stripInset(
            for: geometry, items: SystemTabBarGeometry.itemFrames(in: tabBar, container: view))
    }

    private func setSystemBar(hidden: Bool, transparent: Bool = false) {
        suppressSystemBar = hidden || transparent
        if #available(iOS 18.0, *) {
            setTabBarHidden(hidden, animated: false)
        } else {
            tabBar.isHidden = hidden
        }
        // UIKit's unhide and layout can restore alpha; apply presentation after the native API.
        tabBar.alpha = suppressSystemBar ? 0 : 1
        tabBar.accessibilityElementsHidden = suppressSystemBar
        tabBar.isUserInteractionEnabled = !suppressSystemBar
    }

    private func applySystemBarSuppression() {
        guard suppressSystemBar || setupPresented else { return }
        UIView.performWithoutAnimation {
            if setupPresented { panel.view.isHidden = true }
            tabBar.alpha = 0
            tabBar.accessibilityElementsHidden = true
            tabBar.isUserInteractionEnabled = false
        }
    }

    private func finishBarTransition(toSystem: Bool) {
        guard toSystem == (currentSelection == 2) else { return }
        UIView.performWithoutAnimation { setSystemBar(hidden: !toSystem) }
    }

    private var systemBarIsVisible: Bool {
        tabBar.window != nil && !tabBar.isHidden && tabBar.alpha > 0.01
            && tabBar.convert(tabBar.bounds, to: view).intersects(view.bounds)
    }

    func currentMap() -> MKMapView? {
        mapHost.currentMap()
    }

    func currentDrawerGeometry() -> (top: CGFloat, collapsedTop: CGFloat)? {
        guard currentSelection < 2 else { return nil }
        return panel.currentGeometry()
    }

    private func updateMapClosedTop() {
        guard isViewLoaded, currentSelection >= 0, currentSelection < 2, let collapsedTop else { return }
        mapHost.setClosedDrawerTop(mapHost.view.convert(CGPoint(x: 0, y: collapsedTop), from: panel.view).y)
    }

    private func updateMapClearance(_ top: CGFloat) {
        guard isViewLoaded, currentSelection >= 0, currentSelection < 2, top.isFinite, top > 0 else { return }
        updateMapClosedTop()
        let point = mapHost.view.convert(CGPoint(x: 0, y: top), from: panel.view)
        mapHost.setDrawerTop(point.y)
    }

    private func install(_ child: UIViewController, in parent: UIViewController) {
        parent.addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        parent.view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor),
        ])
        child.didMove(toParent: parent)
    }

#if targetEnvironment(simulator)
    private func auditGeometry(_ geometry: DrawerBarGeometry?) -> [String: Double] {
        guard let geometry else { return [:] }
        return ["x": geometry.frame.minX, "y": geometry.frame.minY, "width": geometry.frame.width,
                "height": geometry.frame.height, "radius": geometry.radius]
    }

    private func tabAuditValue() -> String {
        let barHidden: Bool
        if #available(iOS 18.0, *) { barHidden = isTabBarHidden } else { barHidden = tabBar.isHidden }
        let measuredPlatter = currentSelection == 2 && !panel.isBarTransitioning
            ? SystemTabBarGeometry.measure(tabBar, in: view) : systemPlatterGeometry
        let values: [String: Any] = [
            "selection": currentSelection,
            "systemBarHidden": barHidden,
            "systemBarVisible": systemBarIsVisible,
            "systemBarAlpha": tabBar.alpha,
            "systemBarFloating": SystemTabBarGeometry.isFloating,
            "systemItemFrames": SystemTabBarGeometry.itemFrames(in: tabBar, container: view).map {
                ["x": Double($0.minX), "y": Double($0.minY), "width": Double($0.width), "height": Double($0.height)]
            },
            "systemItemContent": currentSelection == 2 ? SystemTabBarGeometry.itemContent(in: tabBar, container: view) : [],
            "barTransitioning": panel.isBarTransitioning,
            "drawerSettled": panel.isLayoutSettled,
            "reduceMotion": UIAccessibility.isReduceMotionEnabled,
            "barTransitions": panel.barTransitionAudits,
            "systemPlatter": auditGeometry(measuredPlatter),
            "closedDrawer": auditGeometry(panel.closedBarGeometry()),
            "drawerFrame": auditGeometry(panel.currentBarGeometry()),
            "drawerHidden": panel.view.isHidden,
            "mapHidden": mapHost.view.isHidden,
            "mapHost": String(describing: ObjectIdentifier(mapHost)),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
#endif
}

@MainActor
enum SystemTabBarGeometry {
    // On a 402-point iOS 27 phone, the 266 × 54 item union sits in a 274 × 62 platter.
    static let platterPadding: CGFloat = 4

    static var isFloating: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private static func itemLayoutFrame(_ item: UIView, in bar: UIView, container: UIView) -> CGRect? {
        var frame = item.bounds
        var current = item
        // Ignore UIKit's item press transforms, including compensating transforms on nested buttons.
        while current !== bar {
            guard let parent = current.superview else { return nil }
            frame = frame.offsetBy(dx: current.center.x - current.bounds.midX,
                                   dy: current.center.y - current.bounds.midY)
            current = parent
        }
        return bar.convert(frame, to: container)
    }

    static func itemFrames(in bar: UIView, container: UIView) -> [CGRect] {
        var frames: [CGRect] = []
        @MainActor func collect(_ view: UIView) {
            // The bar itself is transparent while UIKit lays out its visible item controls.
            guard view === bar || (!view.isHidden && view.alpha > 0.01) else { return }
            if view !== bar, view is UIControl || view.accessibilityTraits.contains(.button) {
                if let frame = itemLayoutFrame(view, in: bar, container: container),
                   frame.width > 0, frame.height > 0,
                   frame.minX.isFinite, frame.minY.isFinite, frame.maxX.isFinite, frame.maxY.isFinite {
                    frames.append(frame)
                }
            }
            for child in view.subviews { collect(child) }
        }
        collect(bar)
        return frames
    }

#if targetEnvironment(simulator)
    static func itemContent(in bar: UIView, container: UIView) -> [[String: Any]] {
        var items: [[String: Any]] = []
        @MainActor func rect(_ r: CGRect) -> [String: Double] {
            ["x": Double(r.minX), "y": Double(r.minY), "width": Double(r.width), "height": Double(r.height)]
        }
        @MainActor func collect(_ view: UIView, depth: Int) {
            if let label = view as? UILabel, !label.isHidden {
                let weight = (label.font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any])?[.weight]
                items.append(["kind": "label", "text": label.text ?? "", "frame": rect(label.convert(label.bounds, to: container)),
                              "pointSize": Double(label.font.pointSize), "weight": (weight as? CGFloat).map(Double.init) ?? 0,
                              "transformA": Double(label.transform.a)])
            } else if let image = view as? UIImageView, !image.isHidden, image.image != nil {
                let config = image.image?.symbolConfiguration ?? image.preferredSymbolConfiguration
                items.append(["kind": "image", "frame": rect(image.convert(image.bounds, to: container)),
                              "imageSize": ["width": Double(image.image?.size.width ?? 0), "height": Double(image.image?.size.height ?? 0)],
                              "config": config.map { String(describing: $0) } ?? "",
                              "transformA": Double(image.transform.a)])
            }
            for child in view.subviews { collect(child, depth: depth + 1) }
        }
        collect(bar, depth: 0)
        return items
    }
#endif

    // The drawer strip's side inset that puts its equal cells on the system items' centers.
    static func stripInset(for platter: DrawerBarGeometry, items: [CGRect]) -> CGFloat {
        var lefts: [CGFloat] = []
        for x in items.map(\.minX).sorted() where lefts.last.map({ x - $0 > 1 }) ?? true { lefts.append(x) }
        guard lefts.count == DrawerTabStrip.tabs.count, let first = lefts.first, let last = lefts.last else {
            return platterPadding
        }
        let pitch = (last - first) / CGFloat(lefts.count - 1)
        let strip = pitch * CGFloat(lefts.count) + DrawerTabStrip.contentInset * 2
        return max(0, (platter.frame.width - strip) / 2)
    }

    static func measure(_ bar: UIView, in container: UIView) -> DrawerBarGeometry {
        let frame = bar.convert(bar.bounds, to: container)
        guard isFloating else { return DrawerBarGeometry(frame: frame, radius: 0) }
        let items = itemFrames(in: bar, container: container).reduce(CGRect.null) { $0.union($1) }
        let platter = items.isNull ? frame : items.insetBy(dx: -platterPadding, dy: -platterPadding)
        return DrawerBarGeometry(frame: platter, radius: min(platter.width, platter.height) / 2)
    }
}

struct DrawerTab: Identifiable {
    let id: Int
    let title: String
    let symbol: String
}

struct DrawerTabStrip: View {
    var selection: Int
    var onSelect: (Int) -> Void
    @Namespace private var highlight
    @State private var width: CGFloat = 0
    @GestureState private var pressed: Int?

    static let contentInset: CGFloat = 4
    // Items match the system tab bar measured on iOS 27: 54-point cells with a symbol centered 20
    // points down and a 10-point label centered 41 down. UIKit draws its 16-point semibold tab
    // symbols about 1.4 times larger, which a 22.6-point semibold symbol matches. The strip is never
    // scaled, so the bar can hand off to the system one without the items changing size.
    static let cellHeight: CGFloat = 54

    static let tabs = [
        DrawerTab(id: 0, title: "Tracker", symbol: "location.fill"),
        DrawerTab(id: 1, title: "Trip", symbol: "figure.walk"),
        DrawerTab(id: 2, title: "Settings", symbol: "gearshape.fill"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs) { tab in
                VStack(spacing: 0) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 22.6, weight: .semibold))
                        .frame(height: 30)
#if targetEnvironment(simulator)
                        .background(DrawerIconAuditProbe(index: tab.id))
#endif
                    Text(tab.title)
                        .font(.system(size: 10, weight: highlighted == tab.id ? .semibold : .medium))
                        .lineLimit(1)
                        .frame(height: 12)
                }
                .padding(.top, 5)
                .padding(.bottom, Self.cellHeight - 47)
                .foregroundStyle(highlighted == tab.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, minHeight: Self.cellHeight)
                .background {
                    // System items overlap their neighbors by 8 points, and so does their selection.
                    if highlighted == tab.id {
                        Capsule()
                            .fill(Color.primary.opacity(pressed == nil ? 0.08 : 0.12))
                            .padding(.horizontal, -Self.contentInset)
                            .matchedGeometryEffect(id: "selection", in: highlight)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab.id ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { onSelect(tab.id) }
            }
        }
        .padding(Self.contentInset)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // One gesture handles taps and sideways scrubbing, like the system tab bar: the highlight
        // follows the finger and the tab under it is chosen on release. Vertical drags
        // belong to the drawer's simultaneous pan recognizer.
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pressed) { value, state, _ in state = tab(at: value.location.x) }
                .onEnded { value in
                    guard abs(value.translation.height) <= max(8, abs(value.translation.width)) else { return }
                    if let index = tab(at: value.location.x) { onSelect(index) }
                }
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: highlighted)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private var highlighted: Int { pressed ?? selection }

    private func tab(at x: CGFloat) -> Int? {
        guard width > 0 else { return nil }
        return min(Self.tabs.count - 1, max(0, Int(x / (width / CGFloat(Self.tabs.count)))))
    }
}

final class FullScreenMapHost: UIViewController {
    var onUserLocation: ((CLLocation?) -> Void)?
    private let host: UIHostingController<AnyView>
    private weak var observedMap: MKMapView?
    private var locationObservation: NSKeyValueObservation?
    private var drawerTop: CGFloat?
    private var closedDrawerTop: CGFloat?

    var rootView: AnyView {
        get { host.rootView }
        set { host.rootView = newValue }
    }

    init(rootView: AnyView) {
        host = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let surface = FullScreenMapTouchView(frame: .zero)
        surface.onMapFound = { [weak self] in self?.observeLocation(on: $0) }
        view = surface
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        _ = (view as? FullScreenMapTouchView)?.currentMap()
        updateMapClearance()
    }

    func currentMap() -> MKMapView? {
        (view as? FullScreenMapTouchView)?.currentMap()
    }

    func setDrawerTop(_ top: CGFloat) {
        drawerTop = top
        updateMapClearance()
    }

    func setClosedDrawerTop(_ top: CGFloat) {
        closedDrawerTop = top
        updateMapClearance()
    }

    private func updateMapClearance() {
        guard let map = currentMap() else { return }
        if let closedDrawerTop {
            NativeMapSurface.setClosedDrawerTop(map.convert(CGPoint(x: 0, y: closedDrawerTop), from: view).y, on: map)
        }
        if let drawerTop {
            NativeMapSurface.setDrawerTop(map.convert(CGPoint(x: 0, y: drawerTop), from: view).y, on: map)
        }
    }

    private func observeLocation(on map: MKMapView) {
        guard map !== observedMap else { return }
        observedMap = map
        locationObservation = map.userLocation.observe(\.coordinate, options: [.initial, .new]) { [weak self] user, _ in
            guard let location = user.location else { return }
            DispatchQueue.main.async { [weak self] in self?.onUserLocation?(location) }
        }
    }
}

private final class FullScreenMapTouchView: UIView {
    // Chrome drawn over the map takes its own touches; every other touch goes to the map beneath it.
    private static let chromeIdentifiers: Set<String> = ["wherewolf.map.controls", "wherewolf.map.compass"]
    var onMapFound: ((MKMapView) -> Void)?
    private weak var map: MKMapView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
        let hit = super.hitTest(point, with: event)
        let map = currentMap()
        var ancestor = hit
        while let candidate = ancestor, candidate !== self {
            if let identifier = candidate.accessibilityIdentifier, Self.chromeIdentifiers.contains(identifier) { return hit }
            ancestor = candidate.superview
        }
        guard let map else { return hit }
        let local = map.convert(point, from: self)
        return map.hitTest(local, with: event) ?? hit
    }

    func currentMap() -> MKMapView? {
        if map?.window == nil {
            let found = findMap(in: self)
            if found !== map {
                map = found
                if let found { onMapFound?(found) }
            }
        }
        return map
    }

    private func findMap(in view: UIView) -> MKMapView? {
        if let map = view as? MKMapView { return map }
        for child in view.subviews {
            if let map = findMap(in: child) { return map }
        }
        return nil
    }
}

#if targetEnvironment(simulator)
private final class ShellTabAuditView: UIView {
    var value: (() -> String)?
    override var accessibilityValue: String? {
        get { value?() }
        set { }
    }
}

private struct DrawerIconAuditProbe: UIViewRepresentable {
    let index: Int

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityIdentifier = "wherewolf.drawer.icon.\(index)"
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { }
}
#endif
