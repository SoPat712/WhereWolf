import SwiftUI
import UIKit

struct DrawerBarGeometry: Equatable {
    var frame: CGRect
    var radius: CGFloat

    func blended(to other: Self, progress: CGFloat) -> Self {
        if progress == 0 { return self }
        if progress == 1 { return other }
        func blend(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        let frame = CGRect(x: blend(self.frame.minX, other.frame.minX), y: blend(self.frame.minY, other.frame.minY),
                           width: max(1, blend(self.frame.width, other.frame.width)),
                           height: max(1, blend(self.frame.height, other.frame.height)))
        return Self(frame: frame, radius: min(min(frame.width, frame.height) / 2, max(0, blend(radius, other.radius))))
    }
}

struct DrawerBarTween {
    let from: DrawerBarGeometry
    let to: DrawerBarGeometry
    let toSystem: Bool
    var initialTabsOpacity: CGFloat = 1
    var initialContentOpacity: CGFloat = 0

    var overshoot: CGFloat {
        let delta = [abs(to.frame.minX - from.frame.minX), abs(to.frame.minY - from.frame.minY),
                     abs(to.frame.width - from.frame.width), abs(to.frame.height - from.frame.height),
                     abs(to.radius - from.radius)].reduce(CGFloat(1)) { max($0, $1) }
        return min(0.02, 3 / delta)
    }

    func geometry(at progress: CGFloat) -> DrawerBarGeometry { from.blended(to: to, progress: progress) }

    func opacity(at progress: CGFloat, content: Bool = false) -> CGFloat {
        let initial = content ? initialContentOpacity : initialTabsOpacity
        let t = toSystem ? (progress - 0.7) / 0.3 : progress / 0.7
        let clamped = min(1, max(0, t))
        let eased = clamped * clamped * (3 - 2 * clamped)
        let target: CGFloat = toSystem || content ? 0 : 1
        return initial + (target - initial) * eased
    }

    func retarget(to geometry: DrawerBarGeometry, toSystem: Bool, at progress: CGFloat,
                  opacityProgress: CGFloat? = nil) -> Self {
        let phase = opacityProgress ?? progress
        return Self(from: self.geometry(at: progress), to: geometry, toSystem: toSystem,
                    initialTabsOpacity: opacity(at: phase), initialContentOpacity: opacity(at: phase, content: true))
    }
}

// A Find My style drawer: one glass sheet whose bottom holds the tab strip. Collapsed, the
// sheet is just the tab capsule; expanded, the tabs float in their own capsule under the content.
final class MapControlPanelController: UIViewController, UIGestureRecognizerDelegate, UIScrollViewDelegate {
    static let sheetIdentifier = "wherewolf.panel.sheet"
    var onCollapsedTopChange: ((CGFloat) -> Void)?
    var onPresentedTopChange: ((CGFloat) -> Void)?
    var animationClock: (() -> CFTimeInterval)?
    var onBarTransitionCompletion: ((Bool) -> Void)?
    var onBarTransitionFrame: (() -> Void)?
#if targetEnvironment(simulator)
    var barAuditMetadata: (() -> [String: Double])?
    private(set) var barTransitionAudits: [[String: Any]] = []
#endif
    enum Position: String {
        case collapsed = "Collapsed"
        case expanded = "Expanded"
    }

    private let effectView: UIVisualEffectView
    private let grabber = AdjustablePanelGrabber(frame: .zero)
    private let grabberMark = UIView(frame: .zero)
    private let scrollView = UIScrollView(frame: .zero)
    private let tabsContainer = UIView(frame: .zero)
    private let tabsBackground = UIVisualEffectView(effect: nil)
    private let controlsHost: UIHostingController<AnyView>
    private var hostContentHeightConstraint: NSLayoutConstraint!
    private let tabsHost: UIHostingController<AnyView>
    private var panelCenterConstraint: NSLayoutConstraint!
    private var panelBottomConstraint: NSLayoutConstraint!
    private var panelHeightConstraint: NSLayoutConstraint!
    private var panelWidthConstraint: NSLayoutConstraint!
    private var grabberHeightConstraint: NSLayoutConstraint!
    private var controlsHeightConstraint: NSLayoutConstraint!
    private var controlsWidthConstraint: NSLayoutConstraint!
    private var tabsHeightConstraint: NSLayoutConstraint!
    private var tabsTopConstraint: NSLayoutConstraint!
    private var tabsBottomConstraint: NSLayoutConstraint!
    private var tabsLeadingConstraint: NSLayoutConstraint!
    private var tabsTrailingConstraint: NSLayoutConstraint!
    private var drawerPan: UIPanGestureRecognizer!
    private struct Settle {
        let start: CFTimeInterval
        let height: CGFloat
        let velocity: CGFloat
        let target: CGFloat
        let frequency: CGFloat
        let damping: CGFloat
        let resizesContent: Bool
        var bar: DrawerBarTween? = nil
        var barRevision: Int = 0
    }
    private var spring: Settle?
    private var barGeometry: DrawerBarGeometry?
    // The system bar this transition leaves or reaches, and the strip inset that puts our items on its items.
    private var systemBar: (geometry: DrawerBarGeometry, tabsInset: CGFloat, toSystem: Bool)?
    private(set) var barTransitionRevision = 0
    private var finishingBarTransition = false
    private var systemHandoffComplete = false
    private var barProgress: CGFloat = 0
    private var barOpacityProgress: CGFloat = 0
    private var tabsWidthConstraint: NSLayoutConstraint!
    private var measurementScheduled = false
    private var measurementNeeded = true
    private var measuredWidth: CGFloat = 0
    private var dragOriginHeight: CGFloat = 0
    private var dragOriginOffset: CGFloat = 0
    private var dragStartsInScroll = false
    private var updatingDrag = false
    private var drawerOwnsDrag = false
#if targetEnvironment(simulator)
    private var dragSamples: [[String: Double]] = []
    private var settleSamples: [[String: Double]] = []
    private let usesAuditClock = ProcessInfo.processInfo.environment["WHEREWOLF_UI_AUDIT"] == "1"
    private var auditTime: CFTimeInterval = 0
#endif
    private var isDragging = false
    private var contentInteracting = false
    private var position = Position.expanded
    private var controlsRevision = 0
    private var outgoingControls: UIView?
    private var controlsContentHeight: CGFloat = 0
    private var measuredContentHeight: CGFloat = 0
    private var measuredTabsHeight: CGFloat = 60
    private var topDisplayLink: CADisplayLink?
    private var lastPresentedTop: CGFloat = -.greatestFiniteMagnitude
    private var lastReportedTop: CGFloat = -.greatestFiniteMagnitude

    private let grabberHeight: CGFloat = 12
    private let minimumTopClearance: CGFloat = 24
    private let maximumWidth: CGFloat = 620
    private let collapsedWidthRatio: CGFloat = 0.86
    private let expandedWidthRatio: CGFloat = 0.95
    // Measured from Find My on a 402-point iPhone. The tab strip is never scaled: its items keep
    // the system tab bar's size and only the spacing between them follows the drawer's width.
    private let closedTabsInset: CGFloat = 17
    private let openTabsInset: CGFloat = 15
    // The closed capsule stays about 76 points tall around the 62-point strip, with room above
    // it for the grabber mark.
    private let closedTabsTopMargin: CGFloat = 10.6
    private let closedTabsBottomMargin: CGFloat = 3.2
    private let openTabsBottomInset: CGFloat = 12.5
    private let grabberMarkInset: CGFloat = 4.6
    private let expandedCornerRadius: CGFloat = 46
    private let contentTopPadding: CGFloat = 4
    private let contentBottomPadding: CGFloat = 6

    init(controls: AnyView, tabs: AnyView) {
        controlsHost = UIHostingController(rootView: AnyView(EmptyView()))
        tabsHost = UIHostingController(rootView: tabs)
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            effectView = UIVisualEffectView(effect: glass)
        } else {
            effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        }
        super.init(nibName: nil, bundle: nil)
#if targetEnvironment(simulator)
        if usesAuditClock { animationClock = { [weak self] in self?.auditTime ?? 0 } }
#endif
        setControls(controls)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = PanelPassthroughView(frame: .zero)
        view.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configurePanel()
        configureHost(controlsHost, in: scrollView)
        controlsHost.view.accessibilityIdentifier = "wherewolf.panel.controls"
        configureTabs()
#if targetEnvironment(simulator)
        let audit = PanelGeometryAuditView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        audit.isAccessibilityElement = true
        audit.accessibilityLabel = "Drawer geometry"
        audit.isUserInteractionEnabled = false
        audit.value = { [weak self] in self?.geometryAuditValue() ?? "" }
        view.addSubview(audit)
#endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !view.isHidden, barGeometry == nil else { return }
        let waitingForMeasurement = measurementScheduled && measuredWidth > 0
        if !isDragging && spring == nil && !contentInteracting && !waitingForMeasurement,
           measurementNeeded || abs(measuredWidth - view.bounds.width) > 0.5 {
            updateMeasuredHeights()
        }
        updatePanelMetrics(preservePresentedHeight: isDragging || spring != nil || contentInteracting || waitingForMeasurement)
        reportCollapsedTop()
        reportPanelTop()
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        guard container === controlsHost || container === tabsHost else { return }
        scheduleMeasurement()
    }

    // `slide` moves the new controls in from the left (-1) or right (1) instead of fading them.
    func update(controls: AnyView, tabs: AnyView, crossfade: Bool = false, slide: CGFloat? = nil) {
        loadViewIfNeeded()
        let outgoing = controlsSnapshot(crossfade: crossfade || slide != nil)
        if barGeometry == nil { _ = freezePresentationGeometry() }
        isDragging = false
        contentInteracting = false
        scrollView.setContentOffset(.zero, animated: false)
        setControls(controls)
        updateTabs(tabs)
        controlsHost.view.setNeedsLayout()
        scheduleMeasurement()
        controlsHost.view.layoutIfNeeded()
        if let outgoing {
            if let slide, !UIAccessibility.isReduceMotionEnabled { slideControls(from: outgoing, side: slide) }
            else { crossfadeControls(from: outgoing) }
        }
    }

    func updateTabs(_ tabs: AnyView) { tabsHost.rootView = tabs }

    func expand() {
        loadViewIfNeeded()
        guard barGeometry == nil, !view.isHidden, position != .expanded || spring != nil || isDragging else { return }
        settle(to: .expanded)
    }

    func collapse() {
        loadViewIfNeeded()
        guard barGeometry == nil, !view.isHidden, position != .collapsed || spring != nil || isDragging else { return }
        settle(to: .collapsed)
    }

    func setVisible(_ visible: Bool) {
        loadViewIfNeeded()
        guard view.isHidden == visible else { return }
        _ = freezePresentationGeometry()
        barTransitionRevision += 1
        finishingBarTransition = false
        systemHandoffComplete = false
        barGeometry = nil
        systemBar = nil
        barProgress = 0
        barOpacityProgress = 0
        isDragging = false
        contentInteracting = false
        view.isHidden = !visible
        drawerPan.isEnabled = visible
        grabber.isEnabled = visible
        grabber.isAccessibilityElement = visible
        scrollView.isUserInteractionEnabled = visible
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        if visible {
            position = .expanded
            grabber.accessibilityValue = position.rawValue
            UIView.performWithoutAnimation {
                updateMeasuredHeights()
                updatePanelMetrics(preservePresentedHeight: false)
                view.layoutIfNeeded()
            }
        }
    }

    func setContentInteracting(_ interacting: Bool) {
        guard interacting != contentInteracting else { return }
        contentInteracting = interacting
        guard barGeometry == nil else { return }
        guard !isViewLoaded || !view.isHidden else { return }
        if interacting {
            _ = freezePresentationGeometry()
            return
        }
        guard !isDragging, spring == nil, view.bounds.width > 0 else {
            scheduleMeasurement()
            return
        }
        updateMeasuredHeights()
        let values = detents()
        let target = position == .expanded ? values.expanded : values.collapsed
        if abs(panelHeightConstraint.constant - target) > 0.5 {
            settle(to: position, force: true, resizesContent: position == .expanded)
        } else {
            view.setNeedsLayout()
        }
    }

    // MARK: - Tab crossfade

    // The previous tab's controls fade out over the next tab's while the drawer resizes, so the
    // swap is not a cut. The scroll view clips the snapshot to the drawer as it shrinks.
    private func controlsSnapshot(crossfade: Bool) -> UIView? {
        let shown = CGFloat(controlsHost.view.layer.presentation()?.opacity ?? 1)
        endControlsCrossfade()
        guard crossfade, barGeometry == nil, !view.isHidden, view.window != nil, scrollView.alpha > 0.01,
              let snapshot = controlsHost.view.snapshotView(afterScreenUpdates: false) else { return nil }
        snapshot.frame = controlsHost.view.frame.offsetBy(dx: 0, dy: -scrollView.contentOffset.y)
        snapshot.alpha = shown
        snapshot.isUserInteractionEnabled = false
        snapshot.accessibilityIdentifier = "wherewolf.panel.outgoing-controls"
        return snapshot
    }

    private func crossfadeControls(from outgoing: UIView) {
        scrollView.addSubview(outgoing)
        outgoingControls = outgoing
        controlsHost.view.alpha = 0
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
            outgoing.alpha = 0
        } completion: { [weak self, weak outgoing] _ in
            outgoing?.removeFromSuperview()
            if let self, outgoingControls === outgoing { outgoingControls = nil }
        }
        UIView.animate(withDuration: 0.3, delay: 0.05, options: [.curveEaseInOut, .allowUserInteraction]) {
            self.controlsHost.view.alpha = 1
        }
    }

    // Opening a trip slides the Trip controls away and the Tracker's in, like turning to the next tab.
    // Only the incoming layer's presentation moves, so the drawer's layout of the controls is untouched.
    private func slideControls(from outgoing: UIView, side: CGFloat) {
        scrollView.addSubview(outgoing)
        outgoingControls = outgoing
        let width = scrollView.bounds.width
        let incoming = CABasicAnimation(keyPath: "transform.translation.x")
        incoming.fromValue = side * width
        incoming.toValue = 0
        incoming.duration = 0.38
        incoming.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        controlsHost.view.layer.add(incoming, forKey: "slide")
        UIView.animate(withDuration: 0.38, delay: 0, options: [.curveEaseInOut]) {
            outgoing.transform = CGAffineTransform(translationX: -side * width, y: 0)
        } completion: { [weak self, weak outgoing] _ in
            outgoing?.removeFromSuperview()
            if let self, outgoingControls === outgoing { outgoingControls = nil }
        }
    }

    private func endControlsCrossfade() {
        outgoingControls?.removeFromSuperview()
        outgoingControls = nil
        controlsHost.view.layer.removeAnimation(forKey: "opacity")
        controlsHost.view.layer.removeAnimation(forKey: "slide")
        controlsHost.view.alpha = 1
    }

    // MARK: - Layout

    private func setControls(_ controls: AnyView) {
        controlsRevision += 1
        let revision = controlsRevision
        controlsHost.rootView = AnyView(
            controls
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    ceil(proxy.size.height)
                } action: { [weak self] height in
                    guard let self, revision == controlsRevision, height.isFinite, height > 0,
                          abs(height - controlsContentHeight) > 0.5 else { return }
                    controlsContentHeight = height
                    scheduleMeasurement()
                }
                // Keep the controls at the top even before UIKit adopts their new height.
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        )
    }

    private func configurePanel() {
        effectView.accessibilityIdentifier = Self.sheetIdentifier
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.clipsToBounds = true
        effectView.layer.cornerCurve = .continuous
        view.addSubview(effectView)
        (view as? PanelPassthroughView)?.sheet = effectView
        (view as? PanelPassthroughView)?.grabber = grabber

        panelCenterConstraint = effectView.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        panelBottomConstraint = effectView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        panelHeightConstraint = effectView.heightAnchor.constraint(equalToConstant: 300)
        panelWidthConstraint = effectView.widthAnchor.constraint(equalToConstant: 360)
        NSLayoutConstraint.activate([
            panelCenterConstraint,
            panelBottomConstraint,
            panelHeightConstraint,
            panelWidthConstraint,
        ])

        let content = effectView.contentView
        grabber.translatesAutoresizingMaskIntoConstraints = false
        grabber.isAccessibilityElement = true
        grabber.accessibilityLabel = "Controls panel"
        grabber.accessibilityHint = "Swipe up or down to resize."
        grabber.accessibilityIdentifier = "wherewolf.panel.grabber"
        grabber.accessibilityTraits = [.adjustable, .button]
        grabber.accessibilityValue = position.rawValue
        grabber.onIncrement = { [weak self] in self?.settle(to: .expanded) }
        grabber.onDecrement = { [weak self] in self?.settle(to: .collapsed) }
        grabber.addAction(UIAction { [weak self] _ in self?.toggle() }, for: .touchUpInside)
        content.addSubview(grabber)

        grabberMark.translatesAutoresizingMaskIntoConstraints = false
        grabberMark.backgroundColor = .tertiaryLabel
        grabberMark.layer.cornerRadius = 2.5
        grabberMark.isUserInteractionEnabled = false
        grabberMark.accessibilityIdentifier = "wherewolf.panel.grabber-mark"
        grabber.addSubview(grabberMark)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.bounces = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator = true
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        content.addSubview(scrollView)

        tabsContainer.translatesAutoresizingMaskIntoConstraints = false
        tabsContainer.accessibilityIdentifier = "wherewolf.panel.tabs"
        content.addSubview(tabsContainer)

        grabberHeightConstraint = grabber.heightAnchor.constraint(equalToConstant: grabberHeight)
        controlsHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 0)
        tabsHeightConstraint = tabsContainer.heightAnchor.constraint(equalToConstant: measuredTabsHeight)
        tabsTopConstraint = tabsContainer.topAnchor.constraint(equalTo: scrollView.bottomAnchor)
        tabsBottomConstraint = tabsContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                                                    constant: -closedTabsBottomMargin)
        tabsLeadingConstraint = tabsContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: closedTabsInset)
        tabsTrailingConstraint = tabsContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -closedTabsInset)
        NSLayoutConstraint.activate([
            grabber.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            grabber.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            grabber.topAnchor.constraint(equalTo: content.topAnchor),
            grabberHeightConstraint,

            grabberMark.centerXAnchor.constraint(equalTo: grabber.centerXAnchor),
            grabberMark.topAnchor.constraint(equalTo: grabber.topAnchor, constant: grabberMarkInset),
            grabberMark.widthAnchor.constraint(equalToConstant: 52),
            grabberMark.heightAnchor.constraint(equalToConstant: 5),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: grabber.bottomAnchor),
            controlsHeightConstraint,

            tabsLeadingConstraint,
            tabsTrailingConstraint,
            tabsTopConstraint,
            tabsBottomConstraint,
            tabsHeightConstraint,
        ])

        drawerPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        drawerPan.delegate = self
        effectView.addGestureRecognizer(drawerPan)
    }

    private func configureTabs() {
        tabsBackground.translatesAutoresizingMaskIntoConstraints = false
        tabsBackground.clipsToBounds = true
        tabsBackground.layer.cornerCurve = .continuous
        tabsBackground.isUserInteractionEnabled = false
        tabsContainer.addSubview(tabsBackground)
        NSLayoutConstraint.activate([
            tabsBackground.leadingAnchor.constraint(equalTo: tabsContainer.leadingAnchor),
            tabsBackground.trailingAnchor.constraint(equalTo: tabsContainer.trailingAnchor),
            tabsBackground.topAnchor.constraint(equalTo: tabsContainer.topAnchor),
            tabsBackground.bottomAnchor.constraint(equalTo: tabsContainer.bottomAnchor),
        ])

        tabsHost.safeAreaRegions = []
        tabsHost.sizingOptions = [.preferredContentSize]
        addChild(tabsHost)
        tabsHost.view.translatesAutoresizingMaskIntoConstraints = false
        tabsHost.view.backgroundColor = .clear
        tabsHost.view.isOpaque = false
        tabsContainer.addSubview(tabsHost.view)
        tabsWidthConstraint = tabsHost.view.widthAnchor.constraint(equalToConstant: 320)
        NSLayoutConstraint.activate([
            tabsHost.view.centerXAnchor.constraint(equalTo: tabsContainer.centerXAnchor),
            tabsWidthConstraint,
            tabsHost.view.topAnchor.constraint(equalTo: tabsContainer.topAnchor),
            tabsHost.view.bottomAnchor.constraint(equalTo: tabsContainer.bottomAnchor),
        ])
        tabsHost.didMove(toParent: self)
        if #available(iOS 26.0, *) {
            tabsBackground.effect = UIGlassEffect(style: .regular)
        } else {
            tabsBackground.effect = UIBlurEffect(style: .systemThinMaterial)
        }
    }

    private func configureHost(_ host: UIHostingController<AnyView>, in scrollView: UIScrollView) {
        host.safeAreaRegions = []
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        host.sizingOptions = []
        scrollView.addSubview(host.view)
        controlsWidthConstraint = host.view.widthAnchor.constraint(equalToConstant: maximumWidth)
        hostContentHeightConstraint = host.view.heightAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor,
                                           constant: contentTopPadding),
            host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                                              constant: -contentBottomPadding),
            controlsWidthConstraint,
            hostContentHeightConstraint,
            scrollView.contentLayoutGuide.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func scheduleMeasurement() {
        measurementNeeded = true
        guard barGeometry == nil, !measurementScheduled, !isDragging, !contentInteracting,
              viewIfLoaded?.isHidden != true else { return }
        measurementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            measurementScheduled = false
            guard !view.isHidden, barGeometry == nil else { return }
            if !isDragging, !contentInteracting, measuredWidth > 0 {
                updateMeasuredHeights()
                let values = detents()
                let target = position == .expanded ? values.expanded : values.collapsed
                // Repeated measurements must not restart a spring already heading to this target.
                if abs((spring?.target ?? panelHeightConstraint.constant) - target) > 0.5 {
                    settle(to: position, force: true, resizesContent: position == .expanded)
                    return
                }
            }
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }

    private func updateMeasuredHeights() {
        guard view.bounds.width > 0 else { return }
        measurementNeeded = false
        measuredWidth = view.bounds.width
        let width = expandedWidth()
        controlsWidthConstraint.constant = width
        hostContentHeightConstraint.constant = max(1, controlsContentHeight)
        let height = controlsContentHeight + contentTopPadding + contentBottomPadding
        if height.isFinite, abs(height - measuredContentHeight) > 0.5 { measuredContentHeight = height }

        let tabs = tabsHost.sizeThatFits(in: CGSize(width: max(1, expandedWidth() - openTabsInset * 2),
                                                    height: .greatestFiniteMagnitude))
        let tabsHeight = ceil(tabs.height)
        if tabsHeight.isFinite, tabsHeight > 0, abs(tabsHeight - measuredTabsHeight) > 0.5 {
            measuredTabsHeight = tabsHeight
            tabsHeightConstraint.constant = tabsHeight
        }
        tabsBackground.layer.cornerRadius = measuredTabsHeight / 2
    }

    // With a 34-point safe area, the closed capsule clears the home indicator at 28 points and the
    // open sheet reaches down to 8.
    private func closedBottomInset() -> CGFloat {
        let safeBottom = view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
        return safeBottom > 0 ? max(12, safeBottom - 6) : 8
    }

    private func openBottomInset() -> CGFloat {
        let safeBottom = view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
        return safeBottom > 0 ? max(8, safeBottom - 26) : 8
    }

    private func expandedWidth() -> CGFloat {
        max(1, min(maximumWidth, (view.bounds.width * expandedWidthRatio).rounded()))
    }

    private func collapsedWidth() -> CGFloat {
        min(expandedWidth(), (view.bounds.width * collapsedWidthRatio).rounded())
    }

    // The drawer widens with the drag, from a compact tab capsule to a near full-width sheet.
    private func width(for height: CGFloat,
                       detents: (collapsed: CGFloat, expanded: CGFloat, content: CGFloat)) -> CGFloat {
        let fraction = detents.content > 0 ? progress(for: height, detents: detents) : 0
        return collapsedWidth() + (expandedWidth() - collapsedWidth()) * fraction
    }

    private func detents() -> (collapsed: CGFloat, expanded: CGFloat, content: CGFloat) {
        let collapsed = measuredTabsHeight + closedTabsTopMargin + closedTabsBottomMargin
        let openChrome = grabberHeight + measuredTabsHeight + openTabsBottomInset
        let capacity = max(
            0,
            view.bounds.height - openBottomInset() - view.safeAreaInsets.top - minimumTopClearance - openChrome
        )
        let content = min(measuredContentHeight, capacity)
        return (collapsed, content > 0 ? openChrome + content : collapsed, content)
    }

    private func progress(for height: CGFloat,
                          detents: (collapsed: CGFloat, expanded: CGFloat, content: CGFloat)) -> CGFloat {
        let travel = max(1, detents.expanded - detents.collapsed)
        return (height - detents.collapsed) / travel
    }

    private func cornerRadius(for height: CGFloat,
                              detents: (collapsed: CGFloat, expanded: CGFloat, content: CGFloat)) -> CGFloat {
        let collapsedRadius = detents.collapsed / 2
        let fraction = detents.content > 0 ? progress(for: height, detents: detents) : 0
        return collapsedRadius + (expandedCornerRadius - collapsedRadius) * fraction
    }

    private func updatePanelMetrics(preservePresentedHeight: Bool) {
        guard view.bounds.width > 0, panelHeightConstraint != nil else { return }
        let values = detents()
        let overflows = measuredContentHeight > values.content + 0.5
        scrollView.isScrollEnabled = position == .expanded && overflows
        scrollView.showsVerticalScrollIndicator = scrollView.isScrollEnabled
        if !scrollView.isScrollEnabled, scrollView.contentOffset != .zero {
            scrollView.setContentOffset(.zero, animated: false)
        }
        scrollView.accessibilityElementsHidden = position == .collapsed
        if !preservePresentedHeight {
            panelHeightConstraint.constant = position == .expanded ? values.expanded : values.collapsed
        }
        applyProgress(height: panelHeightConstraint.constant, detents: values)
    }

    private func applyProgress(height: CGFloat,
                               detents: (collapsed: CGFloat, expanded: CGFloat, content: CGFloat)) {
        panelCenterConstraint.constant = 0
        tabsContainer.alpha = 1
        grabber.alpha = 1
        let fraction = detents.content > 0 ? progress(for: height, detents: detents) : 0
        let resizesContent = spring?.resizesContent == true
        let alpha = resizesContent ? 1 : min(1, max(0, fraction))
        panelHeightConstraint.constant = height
        panelWidthConstraint.constant = resizesContent ? expandedWidth() : width(for: height, detents: detents)
        // Each state has its own spacing, as in Find My, so the drawer blends between them as it moves.
        func blend(_ closed: CGFloat, _ open: CGFloat) -> CGFloat { closed + (open - closed) * alpha }
        let top = blend(closedTabsTopMargin, grabberHeight)
        let bottom = blend(closedTabsBottomMargin, openTabsBottomInset)
        let room = height - top - measuredTabsHeight - bottom
        grabberHeightConstraint.constant = top
        tabsBottomConstraint.constant = -bottom
        controlsHeightConstraint.constant = max(0, room)
        tabsTopConstraint.constant = min(0, room)
        panelBottomConstraint.constant = -blend(closedBottomInset(), openBottomInset())
        let inset = blend(closedTabsInset, openTabsInset)
        tabsLeadingConstraint.constant = inset
        tabsTrailingConstraint.constant = -inset
        effectView.layer.cornerRadius = resizesContent ? expandedCornerRadius : cornerRadius(for: height, detents: detents)
        tabsBackground.alpha = alpha
        scrollView.alpha = alpha
        tabsWidthConstraint.constant = max(1, panelWidthConstraint.constant - inset * 2)
    }

    // MARK: - Dragging

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !view.isHidden, barGeometry == nil else { return }
        let values = detents()
        switch gesture.state {
        case .began:
            isDragging = true
            let displayed = freezePresentationGeometry()
            dragOriginHeight = displayed
            drawerOwnsDrag = dragOriginHeight < values.expanded - 0.5
#if targetEnvironment(simulator)
            dragSamples.removeAll(keepingCapacity: true)
#endif
            updateDrag()
        case .changed:
            updateDrag()
        case .ended, .cancelled, .failed:
            updateDrag()
            isDragging = false
            if !drawerOwnsDrag {
                position = .expanded
                grabber.accessibilityValue = position.rawValue
                updatePanelMetrics(preservePresentedHeight: false)
                return
            }
            let velocity = gesture.velocity(in: view).y
            let target: Position
            if abs(velocity) > 500 {
                target = velocity < 0 ? .expanded : .collapsed
            } else {
                target = panelHeightConstraint.constant >= (values.collapsed + values.expanded) / 2
                    ? .expanded : .collapsed
            }
            settle(to: target, force: true, velocity: -velocity)
        default:
            break
        }
    }

    private func updateDrag() {
        guard isDragging, !updatingDrag else { return }
        updatingDrag = true
        defer { updatingDrag = false }
        let values = detents()
        let translation = drawerPan.translation(in: view).y
        // A single travel budget crosses the scroll top without resetting either pan.
        let travel = dragOriginHeight - values.expanded
            + (dragStartsInScroll ? dragOriginOffset : 0) - translation
        let height = min(max(values.expanded, dragOriginHeight),
                         max(min(values.collapsed, dragOriginHeight), values.expanded + travel))
        drawerOwnsDrag = height < values.expanded - 0.5
        if abs(panelHeightConstraint.constant - height) > 0.01 {
            applyInteractiveHeight(height, detents: values)
        }
        if dragStartsInScroll || drawerOwnsDrag {
            let top = -scrollView.adjustedContentInset.top
            let maxOffset = scrollView.isScrollEnabled
                ? max(0, scrollView.contentSize.height - scrollView.bounds.height) : 0
            let offset = dragStartsInScroll ? min(maxOffset, max(0, travel)) : 0
            if abs(scrollView.contentOffset.y - (top + offset)) > 0.01 {
                scrollView.contentOffset.y = top + offset
            }
        }
#if targetEnvironment(simulator)
        let now = CACurrentMediaTime()
        if now - (dragSamples.last?["time"] ?? 0) >= 0.025 {
            dragSamples.append(["time": now, "height": height,
                                "offset": scrollView.contentOffset.y, "translation": translation,
                                "width": panelWidthConstraint.constant])
            if dragSamples.count > 400 { dragSamples.removeFirst() }
        }
#endif
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if isDragging { updateDrag() }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if drawerOwnsDrag {
            targetContentOffset.pointee.y = -scrollView.adjustedContentInset.top
        }
    }

    private func applyInteractiveHeight(
        _ height: CGFloat,
        detents: (collapsed: CGFloat, expanded: CGFloat, content: CGFloat)
    ) {
        UIView.performWithoutAnimation {
            applyProgress(height: height, detents: detents)
            view.layoutIfNeeded()
        }
        reportPanelTop()
    }

    private func toggle() {
        settle(to: position == .collapsed ? .expanded : .collapsed)
    }

    var isBarTransitioning: Bool { barGeometry != nil && !finishingBarTransition }
    var isAnimating: Bool { spring != nil || topDisplayLink != nil }

    func currentBarGeometry() -> DrawerBarGeometry {
        DrawerBarGeometry(frame: effectView.convert(effectView.bounds, to: view), radius: effectView.layer.cornerRadius)
    }

    private func presentedBarGeometry() -> DrawerBarGeometry {
        let layer = effectView.layer.presentation() ?? effectView.layer
        return DrawerBarGeometry(frame: layer.convert(layer.bounds, to: view.layer.presentation() ?? view.layer),
                                 radius: layer.cornerRadius)
    }

    func closedBarGeometry() -> DrawerBarGeometry {
        let height = detents().collapsed
        let width = collapsedWidth()
        return DrawerBarGeometry(frame: CGRect(x: (view.bounds.width - width) / 2,
                                                y: view.bounds.height - closedBottomInset() - height,
                                                width: width, height: height), radius: height / 2)
    }

    func transitionBar(toSystem: Bool, systemGeometry: DrawerBarGeometry, systemTabsInset: CGFloat = SystemTabBarGeometry.defaultStripInset,
                       animated: Bool, fromSystem: Bool = false) {
        loadViewIfNeeded()
        if toSystem, systemHandoffComplete, spring?.bar == nil { return }
        let proposedTarget = toSystem ? systemGeometry : closedBarGeometry()
        if !fromSystem, let previous = spring?.bar, previous.toSystem == toSystem, previous.to == proposedTarget { return }
        let previous = spring?.bar
        let previousProgress = barProgress
        let previousOpacity = barOpacityProgress
        let startsAtSystem = fromSystem || systemHandoffComplete || view.isHidden
        let previousRevision = barTransitionRevision
        barTransitionRevision += 1
        let revision = barTransitionRevision
        finishingBarTransition = false
        systemHandoffComplete = false
#if targetEnvironment(simulator)
        if let index = barTransitionAudits.indices.last,
           barTransitionAudits[index]["revision"] as? Int == previousRevision,
           barTransitionAudits[index]["completed"] as? Bool == false {
            barTransitionAudits[index]["interrupted"] = true
        }
#endif
        if view.isHidden { updateMeasuredHeights() }
        guard revision == barTransitionRevision else { return }
        let target = toSystem ? systemGeometry : closedBarGeometry()
        let tween: DrawerBarTween
        if startsAtSystem {
            tween = DrawerBarTween(from: systemGeometry, to: target, toSystem: toSystem,
                                   initialTabsOpacity: 0, initialContentOpacity: 0)
        } else if let previous {
            tween = previous.retarget(to: target, toSystem: toSystem, at: previousProgress,
                                      opacityProgress: previousOpacity)
        } else {
            tween = DrawerBarTween(from: barGeometry ?? presentedBarGeometry(), to: target, toSystem: toSystem,
                                   initialTabsOpacity: tabsContainer.alpha, initialContentOpacity: scrollView.alpha)
        }
        _ = freezePresentationGeometry()
        isDragging = false
        contentInteracting = false
        barProgress = 0
        barOpacityProgress = 0
        barGeometry = tween.from
        systemBar = (systemGeometry, systemTabsInset, toSystem)
        view.isHidden = false
        drawerPan.isEnabled = false
        grabber.isEnabled = false
        grabber.isAccessibilityElement = false
        scrollView.isUserInteractionEnabled = false
        scrollView.accessibilityElementsHidden = true
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        applyBarGeometry(tween.from, tabsOpacity: tween.initialTabsOpacity, contentOpacity: tween.initialContentOpacity)
        guard revision == barTransitionRevision else { return }
        var frequency: CGFloat = 22
#if targetEnvironment(simulator)
        if usesAuditClock { frequency = 4.5 }
        if usesAuditClock {
            barTransitionAudits.append(["revision": revision, "toSystem": toSystem,
                                        "from": Self.auditGeometry(tween.from), "to": Self.auditGeometry(tween.to),
                                        "samples": [[String: Double]](), "completed": false, "interrupted": false])
            if barTransitionAudits.count > 12 { barTransitionAudits.removeFirst() }
        }
#endif
        spring = Settle(start: animationClock?() ?? CACurrentMediaTime(), height: 0, velocity: 0, target: 1,
                        frequency: frequency, damping: 0.8, resizesContent: false, bar: tween, barRevision: revision)
#if targetEnvironment(simulator)
        sampleBarTransition(revision: revision)
#endif
        guard revision == barTransitionRevision else { return }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            startTrackingTop()
        } else {
            finishBarTransition(tween, revision: revision)
        }
    }

    private func applyBarGeometry(_ geometry: DrawerBarGeometry, tabsOpacity: CGFloat, contentOpacity: CGFloat) {
        barGeometry = geometry
        UIView.performWithoutAnimation {
            let values = detents()
            applyProgress(height: geometry.frame.height, detents: values)
            panelCenterConstraint.constant = geometry.frame.midX - view.bounds.midX
            panelBottomConstraint.constant = geometry.frame.maxY - view.bounds.maxY
            panelWidthConstraint.constant = geometry.frame.width
            effectView.layer.cornerRadius = geometry.radius
            // Past the closed capsule the strip settles into the system bar: the side insets and
            // margins shrink to the system's while the items keep their size.
            if let system = systemBar {
                let closedWidth = collapsedWidth()
                if geometry.frame.width < closedWidth {
                    let span = max(1, closedWidth - system.geometry.frame.width)
                    let t = min(1, max(0, (closedWidth - geometry.frame.width) / span))
                    let start = tabsLeadingConstraint.constant
                    let inset = start + (max(0, system.tabsInset) - start) * t
                    tabsLeadingConstraint.constant = inset
                    tabsTrailingConstraint.constant = -inset
                }
                if geometry.frame.height < values.collapsed {
                    let room = max(0, geometry.frame.height - measuredTabsHeight)
                    let share = closedTabsTopMargin / (closedTabsTopMargin + closedTabsBottomMargin)
                    grabberHeightConstraint.constant = room * share
                    tabsBottomConstraint.constant = -room * (1 - share)
                    controlsHeightConstraint.constant = 0
                    tabsTopConstraint.constant = 0
                }
            }
            tabsWidthConstraint.constant = max(1, geometry.frame.width - tabsLeadingConstraint.constant * 2)
            // The items match the system bar's, so they stay opaque through the handoff.
            tabsContainer.alpha = 1
            grabber.alpha = systemBar?.toSystem == false ? tabsOpacity : min(tabsOpacity, contentOpacity)
            scrollView.alpha = contentOpacity
            view.layoutIfNeeded()
            onBarTransitionFrame?()
        }
        reportPanelTop()
    }

    private func finishBarTransition(_ tween: DrawerBarTween, revision: Int) {
        guard revision == barTransitionRevision, spring?.barRevision == revision else { return }
        finishingBarTransition = true
        barProgress = 1
        barOpacityProgress = 1
        applyBarGeometry(tween.to, tabsOpacity: tween.toSystem ? 0 : 1, contentOpacity: 0)
        // Layout and hosting callbacks can synchronously replace the transition we just advanced.
        guard revision == barTransitionRevision else { return }
        spring = nil
        stopTrackingTop()
        barGeometry = nil
        systemBar = nil
        barProgress = 0
        barOpacityProgress = 0
        systemHandoffComplete = tween.toSystem
        finishingBarTransition = false
        position = .collapsed
        grabber.accessibilityValue = position.rawValue
        drawerPan.isEnabled = !tween.toSystem
        grabber.isEnabled = !tween.toSystem
        grabber.isAccessibilityElement = !tween.toSystem
        scrollView.isUserInteractionEnabled = !tween.toSystem
        view.isHidden = tween.toSystem
        if !tween.toSystem {
            UIView.performWithoutAnimation {
                updatePanelMetrics(preservePresentedHeight: false)
                view.layoutIfNeeded()
            }
        }
        guard revision == barTransitionRevision else { return }
        onBarTransitionCompletion?(tween.toSystem)
        guard revision == barTransitionRevision else { return }
#if targetEnvironment(simulator)
        sampleBarTransition(revision: revision, completed: true)
        guard revision == barTransitionRevision else { return }
        if usesAuditClock, let index = barTransitionAudits.indices.last,
           barTransitionAudits[index]["revision"] as? Int == revision {
            barTransitionAudits[index]["completed"] = true
        }
#endif
        if measurementNeeded, !tween.toSystem { scheduleMeasurement() }
    }

#if targetEnvironment(simulator)
    private static func auditGeometry(_ geometry: DrawerBarGeometry) -> [String: Double] {
        ["x": geometry.frame.minX, "y": geometry.frame.minY, "width": geometry.frame.width,
         "height": geometry.frame.height, "radius": geometry.radius]
    }

    private func sampleBarTransition(revision: Int, completed: Bool = false) {
        guard usesAuditClock, let index = barTransitionAudits.indices.last,
              barTransitionAudits[index]["revision"] as? Int == revision else { return }
        var samples = barTransitionAudits[index]["samples"] as? [[String: Double]] ?? []
        let geometry = barGeometry ?? DrawerBarGeometry(frame: effectView.convert(effectView.bounds, to: view),
                                                        radius: effectView.layer.cornerRadius)
        var sample = Self.auditGeometry(geometry)
        sample["progress"] = completed ? 1 : barProgress
        sample["opacityProgress"] = completed ? 1 : barOpacityProgress
        sample["tabsOpacity"] = tabsContainer.alpha
        sample["drawerHidden"] = view.isHidden ? 1 : 0
        func collectIcons(_ candidate: UIView) {
            if let identifier = candidate.accessibilityIdentifier, identifier.hasPrefix("wherewolf.drawer.icon.") {
                let frame = candidate.convert(candidate.bounds, to: view)
                sample[identifier + ".x"] = frame.midX
                sample[identifier + ".y"] = frame.midY
                sample[identifier + ".w"] = frame.width
                sample[identifier + ".h"] = frame.height
            }
            for child in candidate.subviews { collectIcons(child) }
        }
        collectIcons(tabsHost.view)
        sample.merge(barAuditMetadata?() ?? [:]) { _, value in value }
        guard revision == barTransitionRevision,
              barTransitionAudits[index]["revision"] as? Int == revision else { return }
        samples.append(sample)
        if samples.count > 600 { samples.removeFirst() }
        barTransitionAudits[index]["samples"] = samples
    }
#endif

    private func settle(to newPosition: Position, force: Bool = false,
                        velocity: CGFloat = 0, resizesContent: Bool = false) {
        guard !view.isHidden, barGeometry == nil else { return }
        guard force || newPosition != position || spring != nil || isDragging else { return }
        let height = freezePresentationGeometry()
        isDragging = false
        position = newPosition
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            grabber.accessibilityValue = position.rawValue
            return
        }
        let values = detents()
        let target = newPosition == .expanded ? values.expanded : values.collapsed
        var frequency: CGFloat = 22
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["WHEREWOLF_UI_AUDIT"] == "1" { frequency = 4.5 }
        settleSamples.removeAll(keepingCapacity: true)
#endif
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let releaseVelocity = reduceMotion ? 0 : velocity
        spring = Settle(start: animationClock?() ?? CACurrentMediaTime(), height: height, velocity: releaseVelocity,
                        target: target, frequency: frequency, damping: reduceMotion ? 1 : 0.8,
                        resizesContent: resizesContent)
        UIView.performWithoutAnimation {
            updatePanelMetrics(preservePresentedHeight: true)
            view.layoutIfNeeded()
        }
#if targetEnvironment(simulator)
        sampleSettle()
#endif
        startTrackingTop()
    }

    private func freezePresentationGeometry() -> CGFloat {
        // Every displayed frame is also the model state, including an interrupted spring.
        spring = nil
        stopTrackingTop()
        return panelHeightConstraint.constant
    }

    @objc private func advanceSpring(_ link: CADisplayLink) {
        guard spring != nil else { return }
#if targetEnvironment(simulator)
        // CPU guarding must not skip the audit's interaction window between delivered frames.
        if usesAuditClock { auditTime += link.duration > 0 ? link.duration : 1.0 / 60 }
#endif
        advanceAnimation(at: animationClock?() ?? link.targetTimestamp)
    }

    func advanceAnimation(at timestamp: CFTimeInterval) {
        guard let spring else { return }
        let revision = barTransitionRevision
        let t = max(0, CGFloat(timestamp - spring.start))
        let w = spring.frequency
        let x = spring.height - spring.target
        let v = spring.velocity
        let displacement: CGFloat
        if spring.damping == 1 {
            displacement = (x + (v + w * x) * t) * exp(-w * t)
        } else {
            let decay = spring.damping * w
            let oscillation = w * sqrt(1 - spring.damping * spring.damping)
            displacement = exp(-decay * t) * (x * cos(oscillation * t)
                + (v + decay * x) / oscillation * sin(oscillation * t))
        }
        if let bar = spring.bar {
            guard spring.barRevision == barTransitionRevision, !finishingBarTransition else { return }
            if UIAccessibility.isReduceMotionEnabled { finishBarTransition(bar, revision: spring.barRevision); return }
            barProgress = min(1 + bar.overshoot, max(0, 1 + displacement))
            // Keep the labels until the settling tail, rather than clearing them at the first overshoot.
            barOpacityProgress = bar.toSystem ? min(1, t * w / 12) : barProgress
            applyBarGeometry(bar.geometry(at: barProgress), tabsOpacity: bar.opacity(at: barOpacityProgress),
                             contentOpacity: bar.opacity(at: barOpacityProgress, content: true))
            guard spring.barRevision == barTransitionRevision else { return }
#if targetEnvironment(simulator)
            sampleBarTransition(revision: spring.barRevision)
#endif
            if t * w >= 12, abs(displacement) < 0.0001 { finishBarTransition(bar, revision: spring.barRevision) }
            return
        }
        let values = detents()
        let overshoot: CGFloat = spring.damping == 1 ? 0 : 3
        let maximum = spring.resizesContent ? max(values.expanded, spring.height) : values.expanded
        let minimum = spring.resizesContent ? min(values.collapsed, spring.height) : values.collapsed
        let height = min(maximum + overshoot, max(minimum - overshoot, spring.target + displacement))
        applyInteractiveHeight(height, detents: values)
        guard revision == barTransitionRevision else { return }
#if targetEnvironment(simulator)
        sampleSettle()
#endif
        if t * w >= 12, abs(displacement) < 0.1 {
            self.spring = nil
            stopTrackingTop()
            if measurementNeeded { scheduleMeasurement() }
            UIView.performWithoutAnimation {
                updatePanelMetrics(preservePresentedHeight: false)
                view.layoutIfNeeded()
            }
            guard revision == barTransitionRevision else { return }
            reportPanelTop()
            grabber.accessibilityValue = position.rawValue
#if targetEnvironment(simulator)
            sampleSettle()
#endif
            if !spring.resizesContent {
                UIAccessibility.post(notification: .layoutChanged, argument: grabber)
            }
        }
    }

    private func startTrackingTop() {
        guard topDisplayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(advanceSpring(_:)))
        let maximum = maximumFrameRate
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maximum),
                                                       maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        topDisplayLink = link
    }

    private var maximumFrameRate: Float {
        Float(view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
    }

    private func stopTrackingTop() {
        topDisplayLink?.invalidate()
        topDisplayLink = nil
    }

    func currentGeometry() -> (top: CGFloat, collapsedTop: CGFloat) {
        let sheet = effectView.layer.presentation() ?? effectView.layer
        let frame = sheet.convert(sheet.bounds, to: view.layer.presentation() ?? view.layer)
        return (frame.minY, view.bounds.height - closedBottomInset() - detents().collapsed)
    }

    var isLayoutSettled: Bool {
        measuredWidth > 0 && !measurementNeeded && !measurementScheduled && spring == nil
    }

    @objc private func reportPanelTop() {
        guard view.bounds.height > 0, panelHeightConstraint != nil else { return }
        let modelTop = view.bounds.height + panelBottomConstraint.constant - panelHeightConstraint.constant
        let top = modelTop
        guard top.isFinite, top > 0, abs(top - lastPresentedTop) > 0.5 else { return }
        lastPresentedTop = top
        onPresentedTopChange?(top)
    }

    private func reportCollapsedTop() {
        guard view.bounds.height > 0, panelHeightConstraint != nil else { return }
        let top = view.bounds.height - closedBottomInset() - detents().collapsed
        guard top.isFinite, top > 0, abs(top - lastReportedTop) > 0.5 else { return }
        lastReportedTop = top
        onCollapsedTopChange?(top)
    }

#if targetEnvironment(simulator)
    private func sampleSettle() {
        let frame = effectView.convert(effectView.bounds, to: view)
        var sample: [String: Double] = [
            "time": CACurrentMediaTime(), "height": frame.height, "width": frame.width,
            "radius": effectView.layer.cornerRadius, "materialAlpha": tabsBackground.alpha,
            "contentAlpha": scrollView.alpha,
        ]
        func collect(_ candidate: UIView) {
            if let identifier = candidate.accessibilityIdentifier,
               identifier.hasPrefix("wherewolf.drawer.icon.") {
                let frame = candidate.convert(candidate.bounds, to: view)
                sample[identifier] = frame.midX
            }
            for child in candidate.subviews { collect(child) }
        }
        collect(tabsHost.view)
        settleSamples.append(sample)
        if settleSamples.count > 600 { settleSamples.removeFirst() }
    }

    private func geometryAuditValue() -> String {
        let sheet = effectView.layer.presentation() ?? effectView.layer
        let container = view.layer.presentation() ?? view.layer
        let frame = sheet.convert(sheet.bounds, to: container)
        let tabs = tabsContainer.layer.presentation() ?? tabsContainer.layer
        let tabFrame = tabs.convert(tabs.bounds, to: container)
        let safeBottom = view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
        let values: [String: Any] = [
            "sheetX": frame.minX, "sheetY": frame.minY,
            "sheetWidth": frame.width, "sheetHeight": frame.height,
            "sheetBottom": frame.maxY, "safeBottomY": view.bounds.maxY - safeBottom,
            "safeBottom": safeBottom, "screenHeight": view.bounds.height,
            "tabsBottom": tabFrame.maxY, "tabHeight": tabFrame.height,
            "drawerHidden": view.isHidden,
            "scrollOffset": scrollView.contentOffset.y,
            "contentHeight": scrollView.contentSize.height,
            "scrollHeight": scrollView.bounds.height,
            "expandedHeight": detents().expanded,
            "collapsedHeight": detents().collapsed,
            "dragging": isDragging,
            "samples": dragSamples,
            "settleSamples": settleSamples,
            "reduceMotion": UIAccessibility.isReduceMotionEnabled,
            "maximumFramesPerSecond": maximumFrameRate,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
#endif

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !view.isHidden, barGeometry == nil else { return false }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        dragStartsInScroll = scrollView.isScrollEnabled && scrollView.bounds.contains(pan.location(in: scrollView))
        dragOriginOffset = max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        return abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === drawerPan
            && (otherGestureRecognizer === scrollView.panGestureRecognizer
                || otherGestureRecognizer.view?.isDescendant(of: tabsHost.view) == true)
    }
}

private final class PanelPassthroughView: UIView {
    weak var sheet: UIVisualEffectView?
    weak var grabber: AdjustablePanelGrabber?

    private func hitsGrabber(_ point: CGPoint) -> Bool {
        guard let grabber, grabber.isEnabled, grabber.alpha > 0.01 else { return false }
        return grabber.point(inside: grabber.convert(point, from: self), with: nil)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        if hitsGrabber(point) { return true }
        guard let sheet, !sheet.isHidden, sheet.alpha > 0.01 else { return false }
        let layer = sheet.layer.presentation() ?? sheet.layer
        let local = layer.convert(point, from: self.layer.presentation() ?? self.layer)
        return UIBezierPath(roundedRect: layer.bounds, cornerRadius: layer.cornerRadius).contains(local)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        if hitsGrabber(point) { return grabber }
        guard self.point(inside: point, with: event), let sheet else { return nil }
        for child in sheet.contentView.subviews.reversed() {
            guard let local = presentedPoint(point, in: child) else { continue }
            if let scroll = child as? UIScrollView {
                for content in scroll.subviews.reversed() {
                    guard let local = presentedPoint(point, in: content) else { continue }
                    if let target = content.hitTest(local, with: event) { return target }
                }
                return scroll
            }
            if let target = child.hitTest(local, with: event) { return target }
        }
        return sheet.contentView
    }

    private func presentedPoint(_ point: CGPoint, in view: UIView) -> CGPoint? {
        guard view.isUserInteractionEnabled, !view.isHidden, view.alpha > 0.01 else { return nil }
        let displayed = view.layer.presentation() ?? view.layer
        let local = displayed.convert(point, from: layer.presentation() ?? layer)
        guard displayed.bounds.contains(local) else { return nil }
        return CGPoint(
            x: view.bounds.minX + (local.x - displayed.bounds.minX) * view.bounds.width / max(1, displayed.bounds.width),
            y: view.bounds.minY + (local.y - displayed.bounds.minY) * view.bounds.height / max(1, displayed.bounds.height)
        )
    }
}

private final class AdjustablePanelGrabber: UIControl {
    var onIncrement: (() -> Void)?
    var onDecrement: (() -> Void)?

    private var touchBounds: CGRect {
        CGRect(x: 0, y: min(0, bounds.height - 44), width: bounds.width, height: max(44, bounds.height))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        touchBounds.contains(point)
    }

    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(touchBounds, in: self) }
        set { }
    }

    override func accessibilityIncrement() {
        onIncrement?()
    }

    override func accessibilityDecrement() {
        onDecrement?()
    }
}

#if targetEnvironment(simulator)
private final class PanelGeometryAuditView: UIView {
    var value: (() -> String)?
    override var accessibilityValue: String? {
        get { value?() }
        set { }
    }
}
#endif
