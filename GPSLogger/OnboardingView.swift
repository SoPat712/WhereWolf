import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @State private var bridge = GLManagerBridge.shared
    @State private var destination = Destination.device
    @State private var useSetupLink = true
    @State private var setupLink = ""
    @State private var endpoint = ""
    @State private var token = ""
    @State private var ownTracks = false
    @State private var destinationEdited = false
    @Environment(\.scenePhase) private var scenePhase
    @AccessibilityFocusState private var titleFocused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize = 68

    private enum Destination: String, CaseIterable, Identifiable {
        case server = "Your server", cloud = "iCloud Drive", device = "Keep on device for now"
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Step \(model.stepNumber) of \(model.steps.count)")
                                .font(.subheadline).foregroundStyle(.secondary)
                            ProgressView(value: Double(model.stepNumber), total: Double(model.steps.count))
                                .accessibilityLabel("Setup progress")
                                .accessibilityValue("Step \(model.stepNumber) of \(model.steps.count)")
                        }
                        .id("top")
                        Image(systemName: model.step.symbol)
                            .font(.system(size: symbolSize, weight: .regular))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(model.step.title)
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($titleFocused)
                            .accessibilityIdentifier("wherewolf.setup.title")
                        Text(model.step.explanation)
                            .fixedSize(horizontal: false, vertical: true)
                        statusRow("Status", value: model.loaded ? model.summary(for: model.step) : "Checking…")
                            .accessibilityIdentifier("wherewolf.setup.status")
                        details
                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.circle")
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("wherewolf.setup.error")
                        }
                        if model.busy { ProgressView("Updating access…") }
                        actions
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: model.step) { _, _ in
                    scroll.scrollTo("top", anchor: .top)
                    titleFocused = true
                    Task {
                        await model.refresh()
                        if model.step == .destination && !destinationEdited { loadDestination() }
                    }
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Setup Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.step != .welcome {
                        Button("Back", systemImage: "chevron.left") { model.back() }
                            .disabled(model.busy)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip All") { model.skipAll() }
                        .disabled(model.busy)
                        .accessibilityIdentifier("wherewolf.setup.skip-all")
                }
            }
        }
        .interactiveDismissDisabled()
        .task {
            await model.refresh()
            loadDestination()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name(GLAuthorizationStatusChangedNotification))) { _ in
            Task { await model.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name(GLNewActivityNotification))) { _ in
            Task { await model.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name(GLSettingsChangedNotification))) { _ in
            Task { await model.refresh() }
        }
    }

    @ViewBuilder private var details: some View {
        switch model.step {
        case .welcome:
            Link("Privacy Policy", destination: WhereWolfLinks.privacy)
            Text(model.status.tracking
                 ? "Your current recording continues while you review setup. You can skip any step and return from Settings → Setup Guide."
                 : "Nothing starts recording until you choose Start Tracking on the last screen. You can skip any step and return from Settings → Setup Guide.")
                .font(.subheadline).foregroundStyle(.secondary)
        case .whileUsing:
            Text("Choose Allow While Using App in the iOS prompt. Allow Once may need to be renewed the next time you open WhereWolf.")
                .font(.subheadline).foregroundStyle(.secondary)
        case .always:
            if !model.status.location.allowed {
                Text("Allow While Using first. You can also skip this step and return later.")
            }
            Text("iOS may show the Always choice later. If access remains While Using, open iOS Settings → WhereWolf → Location and select Always.")
            if model.status.location.allowed {
                statusRow("Precise Location", value: model.status.preciseLocation ? "On" : "Reduced Accuracy")
            }
            Text("Wi-Fi zones and accurate tracks need Precise Location. If accuracy is reduced, turn on Precise Location in iOS Settings.")
                .font(.subheadline).foregroundStyle(.secondary)
        case .motion:
            Text("Optional. Permission alone does not enable adaptive tracking. You can choose its stop-detection options later in Settings → Motion & Adaptive Tracking.")
                .font(.subheadline).foregroundStyle(.secondary)
        case .notifications:
            Text("Allowing enables the app’s Notifications setting. Ask to End Trip and Ask to Reopen When Audio Stops have their own switches. Notifications do not keep WhereWolf running.")
                .font(.subheadline).foregroundStyle(.secondary)
        case .destination:
            destinationControls
        case .preset:
            Picker("Usage Preset", selection: $model.selectedPreset) {
                if model.selectedPreset == 0 { Text("Custom (Current Settings)").tag(0) }
                ForEach(UsagePreset.values, id: \.self) { value in
                    Text(UsagePreset.name(value)).tag(value)
                }
            }
            .pickerStyle(.inline)
            .disabled(model.status.tripActive)
            ForEach(UsagePreset.values, id: \.self) { value in
                VStack(alignment: .leading, spacing: 4) {
                    Text(UsagePreset.name(value)).font(.headline)
                    Text(UsagePreset.description(value)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Text(model.status.tripActive ? "The current trip keeps its settings. Finish it before changing presets."
                 : "Your selection is applied when you finish the guide. Custom keeps your current settings.")
                .font(.subheadline).foregroundStyle(.secondary)
        case .liveActivity:
            Picker("Appearance", selection: Binding(
                get: { bridge.liveActivityEnabled ? bridge.liveActivityAppearance : "off" },
                set: { value in
                    if value == "off" { bridge.liveActivityEnabled = false }
                    else { bridge.liveActivityAppearance = value; bridge.liveActivityEnabled = true }
                    Task { await model.refresh() }
                })) {
                Text("Blank (Default)").tag("blank")
                Text("Minimal").tag("minimal")
                Text("Status").tag("status")
                Text("Off").tag("off")
            }
            .pickerStyle(.inline)
            VStack(alignment: .leading, spacing: 12) {
                Text("Blank: an empty Island with no Lock Screen card.")
                Text("Minimal: a compact tracking indicator.")
                Text("Status: tracking details in the Island and on the Lock Screen.")
                Text("Off: no tracking Live Activity. Trips have a separate setting.")
            }
            .font(.subheadline).foregroundStyle(.secondary)
            Toggle("Hide While Audio Plays", isOn: Binding(
                get: { bridge.hideLiveActivityWhileAudioPlays },
                set: { bridge.hideLiveActivityWhileAudioPlays = $0; Task { await model.refresh() } }))
            Text("Requires Always location access. Hides activities while other audio plays; while suspended, changes wait for a location update or app open.")
                .font(.subheadline).foregroundStyle(.secondary)
            Toggle("Ask to Reopen When Audio Stops", isOn: Binding(
                get: { bridge.askToReopenAfterAudio },
                set: { bridge.askToReopenAfterAudio = $0; Task { await model.refresh() } }))
            Text("With Hide While Audio Plays on, an authorized notification can ask you to reopen WhereWolf if the activity cannot return. Notification access: \(model.status.notifications.rawValue).")
                .font(.subheadline).foregroundStyle(.secondary)
            if model.status.notifications != .granted {
                Button("Review Notification Access") { model.go(to: .notifications) }
            }
        case .health:
            statusRow("Save Workouts", value: "\(model.status.healthWrite.rawValue) · \(model.status.healthEnabled ? "On" : "Off")")
            statusRow("Import Routes", value: model.status.healthReadReviewed ? "Access reviewed" : "Not Determined")
            Button(model.status.healthReadReviewed ? "Review Workout Import Access" : "Set Up Workout Route Import") {
                Task { await model.request(.healthRead) }
            }
            .disabled(model.busy)
            Text("Health hides read approval from apps. Review workout and route access in the Health app under Profile → Apps → WhereWolf. Importing is separate from live tracking and never uploads routes automatically.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Trip workout types follow your saved trip modes: " + bridge.tripModes.filter { $0.healthWorkout != nil }.map(\.name).joined(separator: ", ") + ". Change these in Settings → Integrations & Exports.")
                .font(.subheadline).foregroundStyle(.secondary)
        case .goodToKnow:
            statusRow("Background App Refresh", value: model.status.backgroundRefresh)
            statusRow("Low Power Mode", value: model.status.lowPower ? "On" : "Off")
            Text("Background App Refresh restrictions can limit recovery after a system termination. Low Power Mode can delay background work. iOS generally does not relaunch an app you force quit.")
                .font(.subheadline).foregroundStyle(.secondary)
            if model.status.watchPaired {
                Label("Your Apple Watch can start or stop tracking and trips, send now, retry updates and change presets. Install WhereWolf from the Watch app. Commands need a live connection to your iPhone.", systemImage: "applewatch")
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Try Siri").font(.headline)
                Text("“Start a trip in WhereWolf”")
                Text("“End my trip in WhereWolf”")
                Text("“Send WhereWolf data now”")
            }
            statusRow("Silent Audio (Experimental)", value: model.status.silentAudio ? "On" : "Off")
            Text("Silent Audio is off by default. It can use more battery and is an experimental option in Background settings.")
                .font(.subheadline).foregroundStyle(.secondary)
        case .done:
            ForEach(model.steps.filter { $0 != .welcome && $0 != .done }) { step in
                Button { model.go(to: step) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).font(.headline)
                            Text(model.summary(for: step)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Review this setup step")
                .accessibilityIdentifier("wherewolf.setup.summary.\(step)")
            }
            if !model.status.location.allowed {
                Text("Allow location access before starting tracking, or finish without tracking.")
            }
            if model.status.tracking {
                Text("Tracking is already on. Reopening this guide does not stop an existing recording.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var destinationControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Destination", selection: Binding(
                get: { destination }, set: { destination = $0; destinationEdited = true })) {
                ForEach(Destination.allCases) { choice in Text(choice.rawValue).tag(choice) }
            }
            .pickerStyle(.inline)
            if destination == .server {
                Toggle("Use a Setup Link", isOn: $useSetupLink)
                if useSetupLink {
                    TextField("wherewolf://setup?url=…", text: $setupLink, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Server setup link")
                    Text("Paste a wherewolf:// or overland:// setup link from your server. It can include a token, device ID and custom headers.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    TextField("https://server.example.com/api", text: $endpoint)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Server endpoint")
                    Picker("Format", selection: $ownTracks) {
                        Text("GeoJSON").tag(false)
                        Text("OwnTracks").tag(true)
                    }
                    SecureField("Access Token", text: $token).textFieldStyle(.roundedBorder)
                    Text("OwnTracks uses a Base64-encoded username:password token. Advanced server options are available in Settings → Server.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else if destination == .cloud {
                Text("Saves GeoJSON files in WhereWolf’s iCloud Drive folder. iOS manages syncing. Your server settings stay saved.")
                if !bridge.cloudAvailable {
                    Label("iCloud Drive is unavailable. Enable it in iOS Settings; this build also needs iCloud support. Unwritten records stay queued.", systemImage: "icloud.slash")
                    Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                }
            } else {
                Text("Keeps records in the local queue and replay history. This clears any server endpoint and turns off iCloud export. Queued records can be sent after you configure a destination later.")
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button { primaryAction() } label: {
                Text(primaryTitle).frame(maxWidth: .infinity)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!model.loaded || model.busy || (model.step == .done && !model.canStartTracking))
                .accessibilityIdentifier("wherewolf.setup.primary")
            Button(model.step == .done ? "Finish Without Tracking" : model.fixingSummary ? "Return to Summary" : "Not Now") {
                if model.step == .done { model.finish(startTracking: false) }
                else { model.next() }
            }
            .controlSize(.large)
            .disabled(model.busy || !model.loaded)
            .accessibilityIdentifier("wherewolf.setup.secondary")
        }
        .frame(maxWidth: .infinity)
    }

    private var permission: OnboardingPermission? {
        switch model.step {
        case .whileUsing: return .whileUsing
        case .always: return .always
        case .motion: return .motion
        case .notifications: return .notifications
        case .health: return .healthWrite
        default: return nil
        }
    }

    private var permissionNeedsAction: Bool {
        guard let permission else { return false }
        let status = model.status.permission(permission)
        if status == .unavailable { return false }
        if permission == .notifications && !model.status.notificationsEnabled { return true }
        if permission == .healthWrite && !model.status.healthEnabled { return true }
        return status != .granted
    }

    private var primaryTitle: String {
        if let permission, permissionNeedsAction {
            if model.opensSettings(for: permission) { return "Open Settings" }
            if permission == .always && !model.status.location.allowed { return "Set Up While Using First" }
            switch permission {
            case .whileUsing: return "Allow While Using App"
            case .always: return "Request Always Access"
            case .motion: return "Allow Motion & Fitness"
            case .notifications: return "Allow Notifications"
            case .healthWrite: return "Set Up Saving Trips to Health"
            case .healthRead: return "Set Up Workout Route Import"
            }
        }
        if model.step == .destination { return "Use This Destination" }
        if model.step == .done { return "Start Tracking" }
        return model.fixingSummary ? "Return to Summary" : "Continue"
    }

    private func primaryAction() {
        if let permission, permissionNeedsAction {
            if permission == .always && !model.status.location.allowed && !model.opensSettings(for: permission) {
                model.go(to: .whileUsing)
            } else { Task { await model.request(permission) } }
            return
        }
        if model.step == .destination {
            let choice: OnboardingDestination
            switch destination {
            case .server: choice = useSetupLink ? .setupLink(setupLink) : .server(endpoint: endpoint, token: token, ownTracks: ownTracks)
            case .cloud: choice = .iCloud
            case .device: choice = .device
            }
            Task {
                await model.chooseDestination(choice)
                if model.error == nil { model.next() }
            }
        } else if model.step == .done {
            model.finish(startTracking: true)
        } else { model.next() }
    }

    private func loadDestination() {
        destination = model.status.cloudSelected ? .cloud : model.status.serverConfigured ? .server : .device
        let gl = GLManager.shared()!
        endpoint = gl.apiEndpointURL() ?? ""
        token = gl.apiAccessToken() ?? ""
        ownTracks = gl.usesOwntracksFormat()
        useSetupLink = !model.status.serverConfigured
    }

    private func statusRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(value).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension OnboardingStep {
    var symbol: String {
        switch self {
        case .welcome: return "map.fill"
        case .whileUsing: return "location.fill"
        case .always: return "location.circle.fill"
        case .motion: return "figure.walk"
        case .notifications: return "bell.badge.fill"
        case .destination: return "externaldrive.fill.badge.person.crop"
        case .preset: return "dial.medium.fill"
        case .liveActivity: return "iphone.gen3"
        case .health: return "heart.fill"
        case .goodToKnow: return "info.circle.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    var explanation: String {
        switch self {
        case .welcome: return "WhereWolf records your location in the background, sends it to a server you choose, replays your routes and records trips. There is no developer server: you decide where your data goes."
        case .whileUsing: return "Let WhereWolf use your location to show where you are and record your route. Start with While Using access; background access is a separate choice on the next screen."
        case .always: return "Always access supports background tracking, recovery after relaunch, Hide While Audio Plays and Wi-Fi zones. iOS controls background delivery, and may offer the Always choice later."
        case .motion: return "Motion & Fitness adds activity types, trip steps and motion confirmation for adaptive stop detection. You can record locations without it."
        case .notifications: return "Optional alerts can remind you about missed updates, ask to end a stopped trip and ask you to reopen WhereWolf when audio stops and a Live Activity cannot return."
        case .destination: return "Choose your own server, save GeoJSON files to iCloud Drive, or keep records on this device until you are ready."
        case .preset: return "Choose how WhereWolf balances route detail and battery use. These are the same five Usage Presets available in Settings."
        case .liveActivity: return "Choose how tracking appears in Dynamic Island and on the Lock Screen. iOS decides which Live Activity is visible."
        case .health: return "Optionally save trips as Apple Health workouts with routes, or set up reading workout routes recorded by other apps. These are separate choices."
        case .goodToKnow: return "A few iPhone settings and shortcuts can help you use WhereWolf day to day."
        case .done: return "Review your choices. Tap any item to change it, then start tracking or finish without starting a recording."
        }
    }
}
