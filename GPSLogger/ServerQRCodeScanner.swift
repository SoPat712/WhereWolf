import AVFoundation
import SwiftUI
import UIKit
import VisionKit

struct ServerQRCodeButton: View {
    let current: ServerQRValues
    let ownTracks: Bool
    var setupUsesOwnTracks: Bool? = nil
    let onUse: (ServerQRReview) async -> Bool

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingScanner = false
    @State private var requestingAccess = false
    @State private var feedback: Feedback?

    private enum Feedback {
        case cameraAccess, unavailable
    }

    var body: some View {
        Group {
            if DataScannerViewController.isSupported {
                Button(action: scan) {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                }
                .disabled(requestingAccess)
                .accessibilityIdentifier("wherewolf.scanQRCode")

                if let feedback {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(feedback == .cameraAccess
                             ? "Allow camera access to scan a QR code."
                             : "QR scanning is unavailable right now.")
                            .foregroundStyle(.secondary)
                        if feedback == .cameraAccess {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingScanner) {
            ServerQRCodeSheet(current: current, ownTracks: ownTracks, setupUsesOwnTracks: setupUsesOwnTracks, onUse: onUse)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, feedback == .cameraAccess,
               AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                feedback = nil
            }
        }
    }

    private func scan() {
        feedback = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            presentScanner()
        case .notDetermined:
            requestingAccess = true
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    requestingAccess = false
                    if granted { presentScanner() } else { feedback = .cameraAccess }
                }
            }
        case .denied, .restricted:
            feedback = .cameraAccess
        @unknown default:
            feedback = .unavailable
        }
    }

    private func presentScanner() {
        guard DataScannerViewController.isAvailable else {
            feedback = .unavailable
            return
        }
        showingScanner = true
    }
}

struct ServerQRCodeSheet: View {
    let current: ServerQRValues
    let ownTracks: Bool
    let setupUsesOwnTracks: Bool?
    let onUse: (ServerQRReview) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var review: ServerQRReview?
    @State private var showsReview: Bool
    @State private var scannerID = UUID()
    @State private var closing = false
    @State private var cameraOff: Bool
    @State private var cameraSettled = false
    @State private var tightened = false
    @State private var checkVisible = false
    @State private var checkProgress: CGFloat = 0
    @State private var pulseExpanded = false
    @State private var torchOn = false
    @State private var feedback: Feedback?
    @State private var detent: PresentationDetent
    // The review sits low like the guide's sheets, so iOS draws it as glass over the app; the camera needs the full height.
    private static let reviewDetent = PresentationDetent.fraction(0.7)

    init(current: ServerQRValues, ownTracks: Bool, setupUsesOwnTracks: Bool? = nil, preview: ServerQRReview? = nil,
         onUse: @escaping (ServerQRReview) async -> Bool) {
        self.current = current
        self.ownTracks = ownTracks
        self.setupUsesOwnTracks = setupUsesOwnTracks
        self.onUse = onUse
        _review = State(initialValue: preview)
        _showsReview = State(initialValue: preview != nil)
        _cameraOff = State(initialValue: preview != nil)
        _detent = State(initialValue: preview != nil ? Self.reviewDetent : .large)
    }

    private enum Feedback {
        case invalidCode, unavailable

        var message: String {
            switch self {
            case .invalidCode: "This QR code isn't a server setup code."
            case .unavailable: "QR scanning is unavailable right now."
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if showsReview, let review {
                    ServerQRReviewView(review: review, onUse: {
                        let saved = await onUse(review)
                        if saved { close() }
                        return saved
                    }, onScanAgain: resetScanner)
                } else {
                    scannerScreen
                }
            }
            .navigationTitle(showsReview ? "Review Server" : "Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(showsReview ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if showsReview {
                    ToolbarItem(placement: .cancellationAction) { Button("Close", action: close) }
                }
            }
        }
        .tint(.blue)
        .presentationDetents(showsReview ? [Self.reviewDetent, .large] : [.large], selection: $detent)
        .onChange(of: showsReview) { _, review in detent = review ? Self.reviewDetent : .large }
        .presentationDragIndicator(.hidden)
        .task(id: closing ? nil : review?.id) { await animateFound() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { setTorch(false) } }
        .onDisappear {
            closing = true
            cameraOff = true
            setTorch(false)
        }
    }

    private var scannerScreen: some View {
        ZStack {
            GeometryReader { geometry in
                let square = QRScanFraming.rect(in: geometry.size)
                ZStack {
                    Color(uiColor: .systemGroupedBackground)
                    if !cameraOff {
                        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                            QRScannerCamera(isActive: scenePhase == .active && review == nil && !closing,
                                            onScan: receive, onRejected: { showFeedback(.invalidCode) },
                                            onUnavailable: { showFeedback(.unavailable) })
                                .id(scannerID)
                                .transition(.identity)
                                .accessibilityLabel("QR code camera")
                        } else {
                            Color.black
                        }
                    }
                    QRScanDimmer(cutout: square)
                        .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                        .opacity(cameraSettled ? 0 : 1)
                    Color.black.opacity(cameraOff && !cameraSettled ? 0.55 : 0)
                    Color(uiColor: .systemGroupedBackground).opacity(cameraSettled ? 1 : 0)
                    foundArtwork.position(x: square.midX, y: square.midY)
                    QRScanBrackets()
                        .stroke(tightened ? Color.blue : .white,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        .frame(width: square.width, height: square.height)
                        .scaleEffect(tightened && !reduceMotion ? 0.72 : 1)
                        .position(x: square.midX, y: square.midY)
                }
                .accessibilityHidden(true)
            }
            .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack {
                    cameraButton("Close", symbol: "xmark", action: close)
                        .accessibilityIdentifier("wherewolf.scanQRCode.close")
                    Spacer()
                    if !cameraOff, AVCaptureDevice.default(for: .video)?.hasTorch == true {
                        cameraButton("Flashlight", symbol: torchOn ? "flashlight.on.fill" : "flashlight.off.fill") {
                            setTorch(!torchOn)
                        }
                        .accessibilityValue(torchOn ? "On" : "Off")
                        .disabled(review != nil || feedback == .unavailable)
                        .accessibilityIdentifier("wherewolf.scanQRCode.torch")
                    }
                }
                Spacer(minLength: 0)
                ViewThatFits(in: .vertical) {
                    instructionCapsule.fixedSize(horizontal: false, vertical: true)
                    ScrollView { instructionCapsule }
                        .scrollBounceBehavior(.basedOnSize)
                }
            }
            .foregroundStyle(cameraSettled ? Color.primary : .white)
            .padding(16)
        }
        .onAppear {
            if !DataScannerViewController.isSupported || !DataScannerViewController.isAvailable {
                showFeedback(.unavailable)
            }
        }
    }

    @ViewBuilder private var instructionCapsule: some View {
        if #available(iOS 26, *) {
            instructionContent.glassEffect(.regular, in: .capsule)
        } else {
            instructionContent.background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var instructionContent: some View {
        VStack(spacing: 10) {
            Text(review == nil ? "Scan the QR code from Dawarich's Account page, or a setup link." : "Code found")
                .font(.callout.weight(.medium))
            if let feedback {
                Text(feedback.message)
                    .font(.callout)
                    .accessibilityIdentifier("wherewolf.scanQRCode.message")
                if feedback == .unavailable {
                    Button("Try Again", action: resetScanner)
                        .frame(minHeight: 44)
                        .glassButtonStyle()
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func cameraButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 44, height: 44)
        }
        .buttonBorderShape(.circle)
        .glassButtonStyle()
        .accessibilityLabel(Text(label))
    }

    private var foundArtwork: some View {
        ZStack {
            if !reduceMotion && tightened {
                RoundedRectangle(cornerRadius: 40).stroke(.blue, lineWidth: 3)
                    .scaleEffect(pulseExpanded ? 1.7 : 1).opacity(pulseExpanded ? 0 : 0.9)
            }
            RoundedRectangle(cornerRadius: 40).fill(.blue)
                .overlay {
                    QRScanCheckmark().trim(from: 0, to: checkProgress)
                        .stroke(.white, style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                        .frame(width: 110, height: 110)
                }
                .scaleEffect(reduceMotion || checkVisible ? 1 : 0.4)
                .opacity(checkVisible ? 1 : 0)
        }
        .frame(width: 150, height: 150)
        .accessibilityHidden(true)
    }

    private func receive(_ text: String) -> Bool {
        guard review == nil, !closing,
              let code = DawarichServer.parseQRCode(text, ownTracks: ownTracks) else { return false }
        feedback = nil
        let format: Bool
        if case .setupLink = code { format = setupUsesOwnTracks ?? ownTracks }
        else { format = ownTracks }
        review = ServerQRReview(code: code, current: current, ownTracks: format)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .announcement, argument: "Code found")
        return true
    }

    // Fixed geometry stays mounted: only scale, opacity and the check's stroke animate.
    // Changing the code or closing the sheet cancels every delayed stage.
    private func animateFound() async {
        guard review != nil, !showsReview, !closing else { return }
        do {
            if reduceMotion {
                cameraOff = true
                setTorch(false)
                try await Task.sleep(for: .milliseconds(20))
                try Task.checkCancellation()
                withAnimation(.easeOut(duration: 0.16)) { showsReview = true }
                return
            }
            withAnimation(.spring(duration: 0.34, bounce: 0.18)) { tightened = true }
            try await Task.sleep(for: .seconds(0.32))
            withAnimation(.easeOut(duration: 0.7)) { pulseExpanded = true }
            withAnimation(.spring(duration: 0.45, bounce: 0.22)) { checkVisible = true }
            withAnimation(.easeOut(duration: 0.35)) { checkProgress = 1 }
            try await Task.sleep(for: .seconds(0.66))
            cameraOff = true
            setTorch(false)
            // Give SwiftUI a pass to dismantle the camera before fading the overlay.
            try await Task.sleep(for: .milliseconds(20))
            withAnimation(.easeInOut(duration: 0.5)) { cameraSettled = true }
            try await Task.sleep(for: .seconds(0.55))
            try Task.checkCancellation()
            showsReview = true
        } catch { return }
    }

    private func resetScanner() {
        setTorch(false)
        review = nil
        showsReview = false
        cameraOff = false
        cameraSettled = false
        tightened = false
        checkVisible = false
        checkProgress = 0
        pulseExpanded = false
        feedback = nil
        scannerID = UUID()
    }

    private func close() {
        closing = true
        cameraOff = true
        setTorch(false)
        dismiss()
    }

    private func setTorch(_ enabled: Bool) {
        guard enabled || torchOn else { return }
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { torchOn = false; return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = enabled ? .on : .off
            torchOn = enabled
        } catch { torchOn = false }
    }

    private func showFeedback(_ value: Feedback) {
        guard feedback != value, review == nil, !closing else { return }
        feedback = value
        UIAccessibility.post(notification: .announcement, argument: value.message)
    }
}

private enum QRScanFraming {
    static func rect(in size: CGSize) -> CGRect {
        let side = max(0, min(250, min(size.width - 48, size.height * 0.5)))
        return CGRect(x: (size.width - side) / 2, y: size.height * 0.43 - side / 2, width: side, height: side)
    }
}

private struct QRScanDimmer: Shape {
    let cutout: CGRect
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: cutout, cornerSize: CGSize(width: 34, height: 34))
        return path
    }
}

private struct QRScanBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let arm: CGFloat = 46
        let radius: CGFloat = 30
        for (x, y, dx, dy): (CGFloat, CGFloat, CGFloat, CGFloat) in [
            (rect.minX, rect.minY, 1, 1), (rect.maxX, rect.minY, -1, 1),
            (rect.minX, rect.maxY, 1, -1), (rect.maxX, rect.maxY, -1, -1)
        ] {
            path.move(to: CGPoint(x: x, y: y + dy * arm))
            path.addLine(to: CGPoint(x: x, y: y + dy * radius))
            path.addQuadCurve(to: CGPoint(x: x + dx * radius, y: y), control: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + dx * arm, y: y))
        }
        return path
    }
}

private struct QRScanCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.27, y: rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.width * 0.44, y: rect.height * 0.68))
        path.addLine(to: CGPoint(x: rect.width * 0.75, y: rect.height * 0.35))
        return path
    }
}

private struct QRScannerCamera: UIViewControllerRepresentable {
    let isActive: Bool
    let onScan: (String) -> Bool
    let onRejected: () -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.onScan = onScan
        controller.onRejected = onRejected
        controller.onUnavailable = onUnavailable
        controller.setActive(isActive)
    }

    static func dismantleUIViewController(_ controller: QRScannerController, coordinator: ()) {
        controller.disconnect()
    }
}

private final class QRScannerController: UIViewController, DataScannerViewControllerDelegate {
    var onScan: (String) -> Bool = { _ in false }
    var onRejected: () -> Void = {}
    var onUnavailable: () -> Void = {}

    private let scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.qr])],
        qualityLevel: .balanced,
        recognizesMultipleItems: false,
        isHighFrameRateTrackingEnabled: false,
        isPinchToZoomEnabled: true,
        isGuidanceEnabled: false,
        isHighlightingEnabled: false
    )
    private var active = false
    private var visible = false
    private var accepted = false
    private var failed = false
    private var attemptedItems = Set<UUID>()

    override func viewDidLoad() {
        super.viewDidLoad()
        scanner.delegate = self
        addChild(scanner)
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scanner.view.frame = view.bounds
        let region = QRScanFraming.rect(in: scanner.view.bounds.size)
        if scanner.regionOfInterest != region { scanner.regionOfInterest = region }
        updateScanning()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        updateScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        visible = false
        scanner.stopScanning()
        super.viewWillDisappear(animated)
    }

    func disconnect() {
        active = false
        scanner.stopScanning()
        scanner.delegate = nil
        scanner.willMove(toParent: nil)
        scanner.view.removeFromSuperview()
        scanner.removeFromParent()
    }

    func setActive(_ active: Bool) {
        self.active = active
        updateScanning()
    }

    private func updateScanning() {
        guard active, visible, !accepted, !failed else {
            scanner.stopScanning()
            return
        }
        guard !scanner.view.bounds.isEmpty, view.window != nil else { return }
        guard DataScannerViewController.isAvailable else {
            scanningUnavailable()
            return
        }
        guard !scanner.isScanning else { return }
        do { try scanner.startScanning() }
        catch { scanningUnavailable() }
    }

    private func scanningUnavailable() {
        guard !failed, !accepted else { return }
        failed = true
        scanner.stopScanning()
        Task { @MainActor [weak self] in self?.onUnavailable() }
    }

    private func recognize(_ item: RecognizedItem) {
        guard active, visible, scanner.isScanning, !accepted, !failed,
              case .barcode(let barcode) = item,
              let value = barcode.payloadStringValue else { return }
        let bounds = barcode.bounds
        let region = scanner.regionOfInterest ?? scanner.view.bounds
        guard [bounds.topLeft, bounds.topRight, bounds.bottomLeft, bounds.bottomRight]
            .allSatisfy({ region.contains($0) }), attemptedItems.insert(item.id).inserted else { return }
        if onScan(value) {
            accepted = true
            scanner.stopScanning()
        } else { onRejected() }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        addedItems.forEach(recognize)
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        updatedItems.forEach(recognize)
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in removedItems { attemptedItems.remove(item.id) }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
        attemptedItems.remove(item.id)
        recognize(item)
    }

    func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        scanningUnavailable()
    }
}
