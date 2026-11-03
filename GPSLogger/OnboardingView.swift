import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @State private var bridge = GLManagerBridge.shared
    @State private var destination = Destination.device
    @State private var sheet: Editor?
    @State private var setupLink = ""
    @State private var endpoint = ""
    @State private var token = ""
    @State private var ownTracks = false
    @State private var useSetupLink = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var titleFocused: Bool
    @ScaledMetric(relativeTo: .title) private var titleSize = 28
    @ScaledMetric(relativeTo: .body) private var rowSize = 16
    @ScaledMetric(relativeTo: .subheadline) private var bodySize = 15
    @ScaledMetric(relativeTo: .caption) private var captionSize = 13

    private enum Destination: CaseIterable { case server, cloud, device }
    private enum Editor: String, Identifiable {
        case server, tracking, accuracy, distance, time, health
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 12) {
            topBar.padding(.horizontal, 16)
            Spacer(minLength: 0)
            ViewThatFits(in: .vertical) {
                panel.fixedSize(horizontal: false, vertical: true)
                ScrollView { panel }
                    .scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("wherewolf.setup.scroll")
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: 580)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(.container, edges: .bottom)
        .tint(.blue)
        .accessibilityAddTraits(.isModal)
        .sheet(item: $sheet) { editor in editorSheet(editor) }
        .task { await model.refresh(); loadDestination() }
        .onChange(of: bridge.usageProfile) { _, _ in
            Task { await model.refresh() }
        }
        .onChange(of: model.step) { _, _ in
            titleFocused = true
            Task {
                await model.refresh()
                if model.step == .destination { loadDestination() }
            }
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
            Task {
                await model.refresh()
                if sheet != .server { loadDestination() }
            }
        }
    }

    @ViewBuilder private var panel: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer { panelContent.glassEffect(.regular, in: .rect(cornerRadius: 46)) }
        } else {
            panelContent.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 46))
        }
    }

    private var panelContent: some View {
        VStack(spacing: model.step == .welcome ? 22 : [.tracking, .liveActivity].contains(model.step) ? 10 : 12) {
            header
            details
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("wherewolf.setup.error")
            }
            footer
        }
        .padding(.horizontal, model.step == .welcome ? 24 : model.step == .liveActivity ? 16 : 18)
        .padding(.top, model.step == .welcome ? 30 : model.step == .tracking ? 20 : 22)
        .padding(.bottom, model.step == .welcome || model.step == .done ? 22 : 18)
        .font(.system(size: rowSize))
        .id(model.step)
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.step)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wherewolf.setup.panel")
    }

    private var topBar: some View {
        HStack {
            if model.step != .welcome && model.step != .done {
                Button { model.back() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .controlSize(.large).frame(width: 44, height: 44)
                .buttonBorderShape(.circle).glassButtonStyle()
                .accessibilityLabel("Back")
            }
            if model.step != .welcome { Spacer(minLength: 8) }
            HStack(spacing: 6) {
                ForEach(model.steps) { step in
                    Capsule().fill(step == model.step ? Color.primary : Color.secondary.opacity(0.4))
                        .frame(width: step == model.step ? 18 : 6, height: 6)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9).glassCapsule()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Setup progress")
            .accessibilityValue("Step \(model.stepNumber) of \(model.steps.count)")
            Spacer(minLength: 8)
            if model.step != .welcome && model.step != .done {
                Button("Skip") { model.next() }
                    .font(.system(size: bodySize, weight: .semibold))
                    .buttonBorderShape(.capsule).glassButtonStyle()
                    .contextMenu { Button("Skip All") { model.skipAll() } }
                    .accessibilityAction(named: "Skip All") { model.skipAll() }
                    .accessibilityIdentifier("wherewolf.setup.skip")
            }
        }
        .disabled(model.busy)
        .frame(height: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wherewolf.setup.navigation")
    }

    private var header: some View {
        VStack(spacing: model.step == .welcome ? 12 : 8) {
            if model.step == .welcome {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 18))
            } else if [.permissions, .destination, .done].contains(model.step) {
                let color: Color = model.step == .permissions ? .blue : .green
                Image(systemName: model.step == .permissions ? "checkmark.shield" : model.step == .done ? "checkmark" : "arrow.up.doc")
                    .font(.system(size: 30, weight: .medium)).foregroundStyle(color)
                    .frame(width: 60, height: 60).background(color.opacity(0.2), in: Circle())
            }
            Text(model.step.title)
                .font(.system(size: model.step == .welcome ? titleSize + 2 : model.step == .liveActivity ? titleSize - 2 : titleSize, weight: .bold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.85)
                .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                .accessibilityIdentifier("wherewolf.setup.title")
            if let subtitle {
                Text(subtitle).font(.system(size: model.step == .welcome || model.step == .permissions ? rowSize : bodySize))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }

    private var subtitle: String? {
        switch model.step {
        case .welcome: return "A quiet location logger that keeps your history and sends it where you choose."
        case .permissions: return "iOS asks only when you tap. Choose Always so WhereWolf keeps recording after you close it."
        case .destination: return "You can change this any time in Settings."
        case .tracking: return "Start from a preset. Changing a setting makes it Custom."
        case .sending:
            if bridge.savesToICloudDrive { return "How points reach your iCloud Drive" }
            if model.status.serverConfigured { return "How points reach \(model.status.destination)" }
            return "Choose how points are sent when you add a destination."
        case .stayingActive: return "iOS can pause any app. These help WhereWolf keep recording."
        case .liveActivity, .done: return nil
        }
    }

    @ViewBuilder private var details: some View {
        switch model.step {
        case .welcome: welcome
        case .permissions: permissions
        case .destination: destinations
        case .tracking: tracking
        case .sending: sending
        case .liveActivity: liveActivity
        case .stayingActive: stayingActive
        case .done: summary
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            feature("Records in the background", "Even with the app closed, using as little battery as it can.", "clock", .blue)
            feature("Sends to your server", "GeoJSON or OwnTracks, or files in your iCloud Drive.", "arrow.up", .green)
            feature("Replays your day", "Scrub back through recent routes, or record trips.", "point.topleft.down.curvedto.point.bottomright.up", .orange)
        }
        .padding(.horizontal, 4)
    }

    private func feature(_ title: String, _ subtitle: String, _ symbol: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(color).frame(width: 30)
            rowText(title, subtitle)
        }
    }

    private var permissions: some View {
        group {
            permissionRow("Location", model.locationSummary, "location.fill", .blue,
                          model.status.location == .whileUsing ? .always : .whileUsing,
                          action: model.status.location == .whileUsing ? "Always" : "Allow")
            separator(icon: true)
            row {
                SettingsIcon(symbol: "scope", color: .green)
                rowText("Precise Location", "Good tracks and Wi-Fi zones")
                if model.status.location.allowed && model.status.preciseLocation { approved("On") }
                else { smallButton("Open Settings") { model.openSettings() } }
            }
            separator(icon: true)
            permissionRow("Motion & Fitness", "Activity types, steps, smarter stops", "figure.walk", .orange, .motion)
            separator(icon: true)
            permissionRow("Notifications", "Reminders, trip end, reopen after music", "bell.fill", .red, .notifications)
            if model.status.healthAvailable {
                separator(icon: true)
                row {
                    SettingsIcon(symbol: "heart.fill", color: .pink)
                    rowText("Apple Health", "Optional · trips as workouts, imports")
                    smallButton(model.status.healthWrite == .denied ? "Open Settings" : model.healthSummary == "Skipped" ? "Set Up" : "Review") {
                        if model.status.healthWrite == .denied { model.openSettings() }
                        else { sheet = .health }
                    }
                }
            }
        }
    }

    private func permissionRow(_ title: String, _ subtitle: String, _ symbol: String, _ color: Color,
                               _ permission: OnboardingPermission, action: String = "Allow") -> some View {
        row {
            SettingsIcon(symbol: symbol, color: color)
            rowText(title, subtitle)
            let status = model.status.permission(permission)
            if status == .granted { approved(permission == .whileUsing && model.status.location == .always ? "Always" : "On") }
            else if status == .unavailable { Text("Unavailable").font(.caption).foregroundStyle(.secondary) }
            else {
                smallButton(model.opensSettings(for: permission) ? "Open Settings" : action) {
                    Task { await model.request(permission) }
                }
            }
        }
    }

    private var destinations: some View {
        VStack(spacing: 8) {
            destinationCard(.server, "Your Server", "GeoJSON or OwnTracks over HTTPS", "server.rack", .blue)
            destinationCard(.cloud, "iCloud Drive", "Daily files in your own iCloud", "icloud.fill", .cyan)
            destinationCard(.device, "Keep on This iPhone", "Decide later", "iphone", .gray)
            if destination == .cloud && !bridge.cloudAvailable {
                Text("iCloud Drive is unavailable. Unwritten records stay queued.")
                    .font(.system(size: captionSize)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Paste Setup Link") { useSetupLink = true; sheet = .server }
                Button("Enter Manually") { useSetupLink = false; sheet = .server }
            }
            .font(.system(size: bodySize, weight: .semibold)).controlSize(.large)
            .buttonBorderShape(.capsule).glassButtonStyle()
            .padding(.top, 6)
        }
    }

    private func destinationCard(_ value: Destination, _ title: String, _ subtitle: String,
                                 _ symbol: String, _ color: Color) -> some View {
        Button {
            destination = value
            if value != .server {
                Task { await model.chooseDestination(value == .cloud ? .iCloud : .device) }
            } else if !bridge.endpointSet { sheet = .server }
            else { Task { await model.chooseDestination(.server(endpoint: endpoint, token: token, ownTracks: ownTracks)) } }
        } label: {
            HStack(spacing: 12) {
                SettingsIcon(symbol: symbol, color: color)
                rowText(title, subtitle)
                Image(systemName: destination == value ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(destination == value ? Color.blue : Color.secondary).accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(destination == value ? Color.blue.opacity(0.2) : sectionColor, in: RoundedRectangle(cornerRadius: 20))
            .overlay { if destination == value { RoundedRectangle(cornerRadius: 20).stroke(.blue, lineWidth: 1.5) } }
        }
        .buttonStyle(.plain).accessibilityAddTraits(destination == value ? .isSelected : [])
    }

    private var tracking: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(UsagePreset.values, id: \.self) { value in
                    Button { Task { await model.choosePreset(value) } } label: {
                        Text(UsagePreset.name(value)).font(.system(size: bodySize, weight: model.selectedPreset == value ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(model.selectedPreset == value ? Color.blue.opacity(0.22) : sectionColor,
                                        in: RoundedRectangle(cornerRadius: 14))
                            .overlay { if model.selectedPreset == value { RoundedRectangle(cornerRadius: 14).stroke(.blue, lineWidth: 1.5) } }
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(model.selectedPreset == value ? .isSelected : [])
                }
            }
            Text(UsagePreset.description(model.selectedPreset)).font(.system(size: captionSize))
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            group {
                editRow("Requested Accuracy", bridge.accuracyPreset == 1 ? "Best" : bridge.accuracyPreset == 2 ? "Navigation" : SettingFormat.meters(bridge.accuracyMeters), .accuracy)
                separator()
                editRow("Min Distance Between Points", bridge.discardDistanceMeters < 1 ? "Off" : "\(Int(bridge.discardDistanceMeters)) m", .distance)
                separator()
                editRow("Min Time Between Points", bridge.discardSecondsValue < 1 ? "Off" : "\(Int(bridge.discardSecondsValue)) s", .time)
                separator()
                toggleRow("Pause Updates Automatically", isOn: $bridge.pausesAutomatically, verticalPadding: 7)
                separator()
                toggleRow("Visit Tracking", isOn: $bridge.visitTracking, verticalPadding: 7)
            }
            Button("All Tracking Settings") { sheet = .tracking }.font(.system(size: captionSize))
            if model.status.tripActive {
                Text("The current trip keeps its settings. Finish it before changing presets.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .disabled(model.status.tripActive)
    }

    private var sending: some View {
        VStack(spacing: 14) {
            segmented("FORMAT") {
                Picker("Format", selection: $bridge.loggingModeIndex) {
                    Text("All Data").tag(0); Text("Only Latest").tag(1); Text("OwnTracks").tag(2)
                }
            }
            segmented("SEND EVERY") {
                Picker("Send Every", selection: $bridge.sendIntervalValue) {
                    ForEach([30.0, 60, 300, 900, 0], id: \.self) { value in
                        Text(intervalLabel(value)).tag(value)
                    }
                    if ![30.0, 60, 300, 900, 0].contains(bridge.sendIntervalValue) {
                        Text(SettingFormat.seconds(bridge.sendIntervalValue)).tag(bridge.sendIntervalValue)
                    }
                }
            }
            segmented("LOCATIONS PER BATCH") {
                Picker("Locations per Batch", selection: $bridge.batchValue) {
                    ForEach([50.0, 100, 200, 500, 1000], id: \.self) { Text("\(Int($0))").tag($0) }
                    if ![50.0, 100, 200, 500, 1000].contains(bridge.batchValue) {
                        Text("\(Int(bridge.batchValue))").tag(bridge.batchValue)
                    }
                }
            }
            group {
                toggleRow("Send Only on Wi-Fi", "Your own Send Now still goes", isOn: $bridge.sendOnlyOnWifi)
                separator()
                toggleRow("Background Uploads", "Lets iOS send while you’re away", isOn: advanced("background_uploads"))
                separator()
                toggleRow("Retry When Back Online", "Retries when a connection returns", isOn: advanced("connectivity_retry"))
            }
        }
    }

    private var liveActivity: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("DYNAMIC ISLAND")
                HStack(spacing: 6) {
                    ForEach(["blank", "minimal", "status", "off"], id: \.self) { value in
                        Button { chooseAppearance(value) } label: {
                            VStack(spacing: 7) {
                                islandPreview(value).frame(height: 18).accessibilityHidden(true)
                                Text(value.capitalized).font(.system(size: captionSize, weight: .medium))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(appearance == value ? Color.blue.opacity(0.2) : sectionColor, in: RoundedRectangle(cornerRadius: 16))
                            .overlay { if appearance == value { RoundedRectangle(cornerRadius: 16).stroke(.blue, lineWidth: 1.5) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(value.capitalized)
                        .accessibilityValue(appearance == value ? "Selected" : "")
                        .accessibilityAddTraits(appearance == value ? .isSelected : [])
                    }
                }
                Text("Blank keeps the island empty. Minimal shows an arrow and warns when updates stop; Status adds when it last sent.")
                    .font(.system(size: captionSize)).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
            if bridge.liveActivityPresentation.cardVisible {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("LOCK SCREEN")
                    group {
                        toggleRow("Lock Screen Card", bridge.liveActivityPresentation.cardRequired
                                  ? "Minimal and Status always include the Lock Screen card." : "Off needs Blank. Minimal and Status always show it.",
                                  isOn: Binding(get: { bridge.liveActivityPresentation.cardOn }, set: { bridge.liveActivityLockScreenCard = $0 }), verticalPadding: 8)
                            .disabled(!bridge.liveActivityPresentation.cardEditable)
                        TrackingLockScreenCard(state: WhereWolfBackgroundRuntime.shared.cardState(), preview: true)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
                            .accessibilityLabel("Lock Screen card preview")
                            .padding(.horizontal, 10).padding(.bottom, 10)
                    }
                }
            }
            group {
                toggleRow("Hide While Music Plays", "Gives Music the island. Needs Always.", isOn: $bridge.hideLiveActivityWhileAudioPlays, verticalPadding: 8)
                separator()
                toggleRow("Ask to Reopen", "A nudge to bring it back after music.", isOn: $bridge.askToReopenAfterAudio, verticalPadding: 8)
            }
        }
    }

    private var stayingActive: some View {
        group {
            helper("Location Indicator", "Blue arrow in the status bar. Most reliable.", "location.fill", .blue, $bridge.backgroundIndicator)
            separator(icon: true)
            helper("Background Recovery", "Helps iOS relaunch after system termination", "arrow.clockwise", .green, advanced("background_recovery"))
            separator(icon: true)
            helper("Service Session", "Retains already-Always access", "checkmark.shield.fill", .indigo, advanced("explicit_service_session"))
                .disabled(!serviceSessionAvailable)
            separator(icon: true)
            helper("Retry Stalled Updates", "Restarts GPS if fixes stop, up to 3 times", "arrow.clockwise", .orange, advanced("automatic_location_retry"))
            separator(icon: true)
            helper("Silent Audio", "Experimental. Plays silence to stay awake.", "waveform", .pink, $bridge.silentAudioEnabled)
        }
    }

    private var summary: some View {
        group {
            summaryRow("Location", model.locationSummary, .permissions)
            separator()
            summaryRow("Notifications", model.status.notifications == .granted ? "On" : model.status.notifications.rawValue, .permissions)
            separator()
            summaryRow("Sends to", model.summary(for: .destination), .destination)
            separator()
            summaryRow("Preset", model.summary(for: .tracking), .tracking)
            separator()
            summaryRow("Dynamic Island", model.summary(for: .liveActivity), .liveActivity)
            separator()
            summaryRow("Staying Active", model.summary(for: .stayingActive), .stayingActive)
            separator()
            summaryRow("Motion & Fitness", model.status.motion == .notDetermined ? "Set Up" : model.status.motion.rawValue, .permissions)
            if model.status.healthAvailable {
                separator()
                summaryRow("Apple Health", model.healthSummary, .permissions)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if model.step == .welcome {
                (Text("There’s no WhereWolf server. ") + Text("[Privacy Policy](https://sopat712.github.io/WhereWolf/privacy/)"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button { primaryAction() } label: {
                Text(model.step == .done ? "Start Tracking" : model.fixingSummary ? "Return to Summary" : "Continue")
                    .font(.system(.body, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 28)
            }
            .controlSize(.large).buttonBorderShape(.capsule).glassButtonStyle(prominent: true, tint: .blue)
            .disabled(!model.loaded || model.busy || (model.step == .done && !model.canStartTracking))
            .accessibilityIdentifier("wherewolf.setup.primary")
            if model.step == .done {
                Button { model.finish(startTracking: false) } label: {
                    Text("Finish Without Tracking").frame(maxWidth: .infinity, minHeight: 28)
                }
                .controlSize(.large).buttonBorderShape(.capsule).glassButtonStyle()
                .disabled(!model.loaded || model.busy)
                .accessibilityIdentifier("wherewolf.setup.secondary")
            }
        }
    }

    private func primaryAction() {
        if model.step == .done { model.finish(startTracking: true) }
        else if model.step == .destination && destination == .server && !bridge.endpointSet { sheet = .server }
        else { model.next() }
    }

    @ViewBuilder private func editorSheet(_ editor: Editor) -> some View {
        NavigationStack {
            Group {
                switch editor {
                case .tracking: TrackingSettingsView()
                case .server: serverForm
                case .accuracy:
                    Form {
                        Picker("Requested Accuracy", selection: $bridge.accuracyPreset) {
                            Text("Custom").tag(0); Text("Best").tag(1); Text("Navigation").tag(2)
                        }
                        if bridge.accuracyPreset == 0 {
                            SliderRow(title: "Target Accuracy", value: $bridge.accuracyMeters, range: 5...3000, unit: "meters", format: SettingFormat.meters)
                        }
                    }.navigationTitle("Requested Accuracy")
                case .distance:
                    Form { SliderRow(title: "Min Distance Between Points", value: $bridge.discardDistanceMeters, range: 0...1000, offBelow: 1, unit: "meters", format: SettingFormat.meters) }
                        .navigationTitle("Minimum Distance")
                case .time:
                    Form { SliderRow(title: "Min Time Between Points", value: $bridge.discardSecondsValue, range: 0...600, offBelow: 1, unit: "seconds", format: SettingFormat.seconds) }
                        .navigationTitle("Minimum Time")
                case .health:
                    Form {
                        Section {
                            Button("Set Up Saving Trips as Workouts") { Task { await model.request(.healthWrite) } }
                            Text("Save workouts: \(model.status.healthWrite.rawValue)")
                            Button("Review Workout Route Import Access") { Task { await model.request(.healthRead) } }
                        } footer: {
                            Text("Health keeps read approval private. \(model.status.healthReadReviewed ? "Access reviewed." : "Review access in Health.") Imported routes never upload automatically.")
                        }
                    }.navigationTitle("Apple Health")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(editor == .server ? "Save" : "Done") {
                    if editor == .server {
                        Task {
                            await model.chooseDestination(useSetupLink ? .setupLink(setupLink) : .server(endpoint: endpoint, token: token, ownTracks: ownTracks))
                            if model.error == nil { loadDestination(); sheet = nil }
                        }
                    } else { sheet = nil; Task { await model.refresh() } }
                }.disabled(model.busy)
            } }
        }
        .modifier(SetupServerSheetStyle(enabled: editor == .server))
        .presentationDetents(editor == .tracking ? [.large] : [.medium, .large])
        .onDisappear { Task { await model.refresh() } }
    }

    private var serverForm: some View {
        Form {
            Section {
                Toggle("Use a Setup Link", isOn: $useSetupLink)
                if useSetupLink {
                    TextField("wherewolf://setup?url=…", text: $setupLink, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    PasteButton(payloadType: String.self) { values in setupLink = values.first ?? "" }
                } else {
                    TextField("https://server.example.com/api", text: $endpoint)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Format", selection: $ownTracks) { Text("GeoJSON").tag(false); Text("OwnTracks").tag(true) }
                    SecureField("Access Token", text: $token)
                }
            } footer: {
                Text(useSetupLink ? "Paste a wherewolf:// or overland:// setup link from your server."
                     : "OwnTracks uses a Base64-encoded username:password token. More options are in Settings → Server.")
            }
            ConnectionTestSection(enabled: useSetupLink ? !setupLink.isEmpty : GLManager.isValidEndpoint(endpoint)) {
                bridge.applyOnboardingDestination(useSetupLink ? .setupLink(setupLink) : .server(endpoint: endpoint, token: token, ownTracks: ownTracks))
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        .settingsFormStyle()
        .navigationTitle(useSetupLink ? "Paste Setup Link" : "Your Server")
    }

    private func loadDestination() {
        destination = model.status.cloudSelected ? .cloud : model.status.serverConfigured ? .server : .device
        let gl = GLManager.shared()!
        endpoint = gl.apiEndpointURL() ?? ""
        token = gl.apiAccessToken() ?? ""
        ownTracks = gl.usesOwntracksFormat()
    }

    private var appearance: String { bridge.liveActivityEnabled ? bridge.liveActivityAppearance : "off" }
    private var sectionColor: Color { Color(uiColor: .secondarySystemGroupedBackground).opacity(0.45) }
    private var serviceSessionAvailable: Bool { if #available(iOS 18, *) { return true }; return false }
    private func advanced(_ key: String) -> Binding<Bool> {
        Binding(get: { bridge.advancedBool(key) }, set: { bridge.setAdvancedBool($0, forKey: key) })
    }
    private func chooseAppearance(_ value: String) {
        if value == "off" { bridge.liveActivityEnabled = false }
        else { bridge.liveActivityAppearance = value; bridge.liveActivityEnabled = true }
    }
    @ViewBuilder private func islandPreview(_ value: String) -> some View {
        if value == "off" { Image(systemName: "minus").foregroundStyle(.secondary) }
        else {
            HStack {
                if value != "blank" { Image(systemName: "location.fill").foregroundStyle(.blue) }
                Spacer(minLength: 0)
                if value == "status" { Text("1m").foregroundStyle(.green) }
            }
            .font(.system(size: 8, weight: .semibold)).padding(.horizontal, 6)
            .frame(width: value == "blank" ? 54 : value == "status" ? 64 : 60, height: 18)
            .background(.black, in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
        }
    }
    private func intervalLabel(_ value: Double) -> String {
        switch value { case 0: return "Manual"; case 30: return "30 s"; case 60: return "1 min"; case 300: return "5 min"; default: return "15 min" }
    }
    private func segmented<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { sectionLabel(title); content().pickerStyle(.segmented) }
    }
    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: captionSize, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 6)
    }
    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content).background(sectionColor, in: RoundedRectangle(cornerRadius: 22))
    }
    private func separator(icon: Bool = false) -> some View { Divider().padding(.leading, icon ? 56 : 16) }
    private func row<Content: View>(verticalPadding: CGFloat = 10, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12, content: content).padding(.horizontal, 14).padding(.vertical, verticalPadding)
    }
    private func rowText(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: rowSize))
            Text(subtitle).font(.system(size: captionSize)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
    private func approved(_ text: String) -> some View { Label(text, systemImage: "checkmark").font(.system(size: bodySize)).foregroundStyle(.green) }
    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).font(.system(size: bodySize, weight: .semibold))
            .buttonBorderShape(.capsule).glassButtonStyle(prominent: true, tint: .blue).disabled(model.busy || !model.loaded)
    }
    private func editRow(_ title: String, _ value: String, _ editor: Editor) -> some View {
        Button { sheet = editor } label: {
            row(verticalPadding: 7) {
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                Text(value).font(.system(size: bodySize)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }.buttonStyle(.plain)
    }
    private func toggleRow(_ title: String, _ subtitle: String? = nil, isOn: Binding<Bool>, verticalPadding: CGFloat = 10) -> some View {
        row(verticalPadding: verticalPadding) {
            Toggle(isOn: isOn) {
                if let subtitle { rowText(title, subtitle) } else { Text(title) }
            }
        }
    }
    private func helper(_ title: String, _ subtitle: String, _ symbol: String, _ color: Color, _ binding: Binding<Bool>) -> some View {
        row { SettingsIcon(symbol: symbol, color: color); Toggle(isOn: binding) { rowText(title, subtitle) } }
    }
    private func summaryRow(_ title: String, _ value: String, _ target: OnboardingStep) -> some View {
        Button { model.go(to: target) } label: {
            row {
                Text(title)
                Spacer(minLength: 0)
                Text(value).font(.system(size: bodySize)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
        .buttonStyle(.plain).accessibilityHint("Review this setup step")
        .accessibilityIdentifier("wherewolf.setup.summary.\(title)")
    }
}

private struct SetupServerSheetStyle: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.environment(\.glassSettingsSheet, true)
                .presentationBackground { Color.clear.glassPanel(cornerRadius: 32) }
        } else { content }
    }
}
