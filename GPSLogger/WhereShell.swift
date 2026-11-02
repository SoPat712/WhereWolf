import SwiftUI
import UIKit
import MapKit

@Observable
final class MapDrawerGeometry {
    var userLocation: CLLocation?
    @ObservationIgnored var read: (() -> (top: CGFloat, collapsedTop: CGFloat)?)?
    @ObservationIgnored var readMap: (() -> MKMapView?)?
}

struct WhereShell: UIViewControllerRepresentable {
    let drawerGeometry: MapDrawerGeometry
    var selection: Int
    var activation: Int
    var controlsID: Int
    var contentInteracting: Bool
    let map: AnyView
    let controls: AnyView
    let tabs: AnyView
    let settings: AnyView

    func makeUIViewController(context: Context) -> WhereShellController {
        let controller = WhereShellController(
            map: map, controls: controls, tabs: tabs, settings: settings,
            selection: selection, controlsID: controlsID
        )
        drawerGeometry.readMap = { [weak controller] in controller?.currentMap() }
        controller.onUserLocation = { [weak geometry = drawerGeometry] in geometry?.userLocation = $0 }
        drawerGeometry.read = { [weak controller] in
            controller?.currentDrawerGeometry()
        }
        return controller
    }

    func updateUIViewController(_ controller: WhereShellController, context: Context) {
        drawerGeometry.readMap = { [weak controller] in controller?.currentMap() }
        controller.onUserLocation = { [weak geometry = drawerGeometry] in geometry?.userLocation = $0 }
        drawerGeometry.read = { [weak controller] in controller?.currentDrawerGeometry() }
        controller.update(map: map, controls: controls, tabs: tabs, settings: settings,
                          selection: selection, activation: activation,
                          controlsID: controlsID, contentInteracting: contentInteracting)
    }
}

// The map and Settings sit under one floating drawer whose bottom capsule holds the tabs,
// matching Find My. Settings hides the map and keeps the drawer collapsed.
final class WhereShellController: UIViewController {
    var onUserLocation: ((CLLocation?) -> Void)? {
        get { mapHost.onUserLocation }
        set { mapHost.onUserLocation = newValue }
    }

    private let mapHost: FullScreenMapHost
    private let settingsHost: UIHostingController<AnyView>
    private let panel: MapControlPanelController
    private var currentSelection = -1
    private var currentActivation = 0
    private var currentControlsID: Int
    private var collapsedTop: CGFloat?

    init(map: AnyView, controls: AnyView, tabs: AnyView, settings: AnyView,
         selection: Int, controlsID: Int) {
        mapHost = FullScreenMapHost(rootView: map)
        settingsHost = UIHostingController(rootView: settings)
        panel = MapControlPanelController(controls: controls, tabs: tabs)
        currentControlsID = controlsID
        super.init(nibName: nil, bundle: nil)
        panel.onCollapsedTopChange = { [weak self] top in
            self?.collapsedTop = top
            self?.updateSettingsInset()
            self?.updateMapClosedTop()
        }
        panel.onPresentedTopChange = { [weak self] top in
            self?.updateMapClearance(top)
        }
        apply(selection: selection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        install(mapHost)
        install(settingsHost)
        install(panel)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSettingsInset()
        updateMapClearance(panel.currentGeometry().top)
    }

    func update(map: AnyView, controls: AnyView, tabs: AnyView, settings: AnyView,
                selection: Int, activation: Int, controlsID: Int, contentInteracting: Bool) {
        mapHost.rootView = map
        if selection != currentSelection || controlsID != currentControlsID {
            currentControlsID = controlsID
            settingsHost.rootView = settings
            panel.update(controls: controls, tabs: tabs)
        }
        panel.setContentInteracting(contentInteracting)
        apply(selection: selection)
        // Tapping the current map tab reopens a collapsed drawer.
        if activation != currentActivation {
            currentActivation = activation
            if currentSelection < 2 { panel.expand() }
        }
    }

    private func apply(selection requested: Int) {
        let index = min(2, max(0, requested))
        guard index != currentSelection else { return }
        let previous = currentSelection
        currentSelection = index
        loadViewIfNeeded()
        mapHost.view.isHidden = index == 2
        settingsHost.view.isHidden = index != 2
        panel.setContentEnabled(index < 2)
        if previous >= 0, previous < 2, index < 2 { panel.expand() }
    }

    func currentMap() -> MKMapView? {
        mapHost.currentMap()
    }

    func currentDrawerGeometry() -> (top: CGFloat, collapsedTop: CGFloat) {
        panel.currentGeometry()
    }

    private func updateMapClosedTop() {
        guard isViewLoaded, let collapsedTop else { return }
        mapHost.setClosedDrawerTop(mapHost.view.convert(CGPoint(x: 0, y: collapsedTop), from: panel.view).y)
    }

    private func updateMapClearance(_ top: CGFloat) {
        guard isViewLoaded, top.isFinite, top > 0 else { return }
        updateMapClosedTop()
        let point = mapHost.view.convert(CGPoint(x: 0, y: top), from: panel.view)
        mapHost.setDrawerTop(point.y)
    }

    private func updateSettingsInset() {
        guard isViewLoaded, let collapsedTop else { return }
        let inset = max(0, view.bounds.height - collapsedTop - view.safeAreaInsets.bottom)
        if abs(settingsHost.additionalSafeAreaInsets.bottom - inset) > 0.5 {
            settingsHost.additionalSafeAreaInsets.bottom = inset
        }
    }

    private func install(_ child: UIViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        child.didMove(toParent: self)
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

    static let tabs = [
        DrawerTab(id: 0, title: "Tracker", symbol: "location.fill"),
        DrawerTab(id: 1, title: "Trip", symbol: "figure.walk"),
        DrawerTab(id: 2, title: "Settings", symbol: "gearshape.fill"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs) { tab in
                VStack(spacing: 3) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 21, weight: .semibold))
                        .frame(height: 24)
#if targetEnvironment(simulator)
                        .background(DrawerIconAuditProbe(index: tab.id))
#endif
                    Text(tab.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(highlighted == tab.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, minHeight: 52)
                .background {
                    if highlighted == tab.id {
                        Capsule()
                            .fill(Color.primary.opacity(pressed == nil ? 0.08 : 0.12))
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
    private static let chromeIdentifiers: Set<String> = ["where.map.controls", "where.map.compass"]
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
private struct DrawerIconAuditProbe: UIViewRepresentable {
    let index: Int

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityIdentifier = "where.drawer.icon.\(index)"
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { }
}
#endif
