import SwiftUI

private struct GlassSettingsSheetKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var glassSettingsSheet: Bool {
        get { self[GlassSettingsSheetKey.self] }
        set { self[GlassSettingsSheetKey.self] = newValue }
    }
}

private struct SettingsFormStyle: ViewModifier {
    @Environment(\.glassSettingsSheet) private var glassSheet

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(glassSheet ? .hidden : .visible)
            .clearNavigationBackground(when: glassSheet)
            .toolbarBackground(glassSheet ? .hidden : .automatic, for: .navigationBar)
    }
}

extension View {
    func settingsFormStyle() -> some View {
        modifier(SettingsFormStyle())
    }

    @ViewBuilder
    func clearNavigationBackground(when enabled: Bool = true) -> some View {
        if #available(iOS 18.0, *), enabled {
            self.containerBackground(.clear, for: .navigation)
        } else {
            self
        }
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent).tint(tint)
            } else {
                self.buttonStyle(.glass).tint(tint)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent).tint(tint)
            } else {
                self.buttonStyle(.bordered).tint(tint)
            }
        }
    }

    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular,
                             in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.background(Capsule().fill(.ultraThinMaterial))
        }
    }
}

struct ExpandingSheetBackground: UIViewRepresentable {
    let detent: PresentationDetent

    func makeUIView(context: Context) -> ExpandingSheetBackgroundView {
        ExpandingSheetBackgroundView()
    }

    func updateUIView(_ view: ExpandingSheetBackgroundView, context: Context) {
        view.configure(detent: detent)
    }

    static func dismantleUIView(_ view: ExpandingSheetBackgroundView, coordinator: ()) {
        view.disconnect()
    }
}

final class ExpandingSheetBackgroundView: UIView {
    private let glass: UIVisualEffectView
    private let fill = UIView()
    private var containerSize = CGSize.zero
    private var mediumHeight: CGFloat?
    private weak var sheet: UISheetPresentationController?
    private var displayLink: CADisplayLink?
    private var lastHeight: CGFloat = -1
    private var stableFrames = 0
    private var followUntil: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var targetOpacity: CGFloat = 0
    private var detent: PresentationDetent?
    private let observedPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()

    var solidOpacity: CGFloat { fill.alpha }
    var solidColor: UIColor { fill.backgroundColor ?? .clear }
    var isFollowing: Bool { displayLink != nil }

    init() {
        if #available(iOS 26.0, *) {
            glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        }
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        fill.backgroundColor = .systemGroupedBackground
        fill.alpha = 0
        addSubview(glass)
        addSubview(fill)
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityChanged),
                                               name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stopFollowing),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityChanged),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            mediumHeight = nil
            sheet = nil
            disconnect()
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let resized = glass.frame != bounds
        glass.frame = bounds
        fill.frame = bounds
        updateOpacity()
        observePans()
        if resized || abs(targetOpacity - fill.alpha) > 0.001 { followForTransition() }
    }

    func configure(detent: PresentationDetent) {
        guard detent != self.detent else { return }
        self.detent = detent
        followForTransition()
    }

    func followForTransition() {
        followUntil = CACurrentMediaTime() + 0.9
        stableFrames = 0
        guard window?.windowScene?.activationState == .foregroundActive, displayLink == nil else { return }
        lastFrameTime = 0
        let target = ExpandingSheetFrameTarget(view: self)
        let link = CADisplayLink(target: target, selector: #selector(ExpandingSheetFrameTarget.frame(_:)))
        let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func advanceFrame(at timestamp: CFTimeInterval) {
        guard window?.windowScene?.activationState == .foregroundActive else { stopFollowing(); return }
        let height = updateOpacity()
        let elapsed = lastFrameTime > 0 ? min(0.05, max(0, timestamp - lastFrameTime)) : 1.0 / 60
        lastFrameTime = timestamp
        let difference = targetOpacity - fill.alpha
        // UIKit can commit a detent's layout before its visual transition starts.
        fill.alpha = abs(difference) < 0.001 ? targetOpacity
            : fill.alpha + difference * (1 - exp(-elapsed / 0.07))
        stableFrames = abs(height - lastHeight) < 0.1 ? stableFrames + 1 : 0
        lastHeight = height
        if stableFrames >= 8 && fill.alpha == targetOpacity && CACurrentMediaTime() >= followUntil { stopFollowing() }
    }

    @objc func stopFollowing() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func disconnect() {
        stopFollowing()
        for pan in observedPans.allObjects { pan.removeTarget(self, action: #selector(sheetPanChanged(_:))) }
        observedPans.removeAllObjects()
    }

    private func observePans() {
        guard observedPans.count == 0, let container = sheet?.containerView else { return }
        var pending = [container]
        while let view = pending.popLast() {
            for case let pan as UIPanGestureRecognizer in view.gestureRecognizers ?? [] where !observedPans.contains(pan) {
                pan.addTarget(self, action: #selector(sheetPanChanged(_:)))
                observedPans.add(pan)
            }
            pending.append(contentsOf: view.subviews)
        }
    }

    @objc private func sheetPanChanged(_ pan: UIPanGestureRecognizer) { followForTransition() }

    @discardableResult private func updateOpacity() -> CGFloat {
        guard let window, bounds.height > 0 else { return bounds.height }
        if sheet == nil {
            var owner = window.rootViewController?.presentedViewController
            while let controller = owner {
                if let candidate = controller.sheetPresentationController,
                   let container = candidate.containerView, isDescendant(of: container) {
                    sheet = candidate
                }
                owner = controller.presentedViewController
            }
            observePans()
        }
        let presented = sheet?.presentedView?.layer ?? layer
        let surface = presented.presentation() ?? presented
        let frame = surface.convert(surface.bounds, to: nil)
        let visible = frame.intersection(window.layer.convert(window.layer.bounds, to: nil))
        let height = visible.isNull ? bounds.height : visible.height
        if containerSize != window.bounds.size {
            containerSize = window.bounds.size
            mediumHeight = nil
        }
        let expanded = max(1, window.bounds.height - window.safeAreaInsets.top - 10)
        // The first layout can precede the sheet's medium-detent sizing.
        let medium = mediumHeight ?? min(height, expanded * 0.6)
        mediumHeight = medium
        let progress = min(1, max(0, (height - medium) / max(1, expanded - medium)))
        targetOpacity = progress * progress * (3 - 2 * progress)
        if UIAccessibility.isReduceTransparencyEnabled {
            targetOpacity = 1
            fill.alpha = 1
        }
        return height
    }

    @objc private func accessibilityChanged() { setNeedsLayout() }
}

private final class ExpandingSheetFrameTarget: NSObject {
    weak var view: ExpandingSheetBackgroundView?

    init(view: ExpandingSheetBackgroundView) { self.view = view }

    @objc func frame(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        view.advanceFrame(at: link.timestamp)
    }
}

// Map chrome shares one width so the speedometer and control stack line up.
enum MapChrome {
    static let width: CGFloat = 52
    static let edge: CGFloat = 14
    static let topInset: CGFloat = 6
    static let attributionHeight: CGFloat = 44
    static let attributionGap: CGFloat = 8
    // The replay panel shares the speedometer's row, stopping short of the top-left credit and Legal link.
    static let replayStatusClearance: CGFloat = 112
    static let replayStatusWidth: CGFloat = 280
    // Tall status areas leave free space between the clock and the safe area.
    static func attributionTop(safeTop: CGFloat) -> CGFloat {
        safeTop >= 44 ? safeTop - 14 : safeTop + topInset
    }
    static let buttonHeight: CGFloat = 48
    static let controlsHeight = buttonHeight * 4 + 8
}

struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingsRowLabel: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(symbol: symbol, color: color)
        }
    }
}

struct DrawerHeader<Accessory: View>: View {
    let title: String?
    let subtitle: String
    var indicator: Color? = nil
    @ViewBuilder var accessory: Accessory
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: title == nil ? .center : .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                }
                HStack(spacing: 6) {
                    if let indicator {
                        Circle().fill(indicator).frame(width: 8, height: 8)
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
    }
}

struct DrawerCircleButton: View {
    let symbol: String
    let label: String
    var contentSize: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: contentSize, height: contentSize)
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

struct DrawerDetailsButton: View {
    @Binding var expanded: Bool
    let subject: String

    var body: some View {
        Button { expanded.toggle() } label: {
            Label("Details", systemImage: "info.circle")
                .font(.caption.weight(.semibold))
                .frame(minHeight: 32)
        }
        .glassButtonStyle(tint: expanded ? .blue : nil)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("\(expanded ? "Hide" : "Show") \(subject) details")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

extension View {
    func drawerCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.drawerCard, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.horizontal, 16)
    }
}

extension Color {
    static let settingsRow = Color(uiColor: .secondarySystemGroupedBackground)

    static let drawerCard = Color(uiColor: UIColor { traits in
        UIColor(white: 1, alpha: traits.userInterfaceStyle == .dark ? 0.08 : 0.45)
    })
}
