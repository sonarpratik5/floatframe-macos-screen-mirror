import AppKit
import SwiftUI
import ServiceManagement

struct ContentView: View {
    @State private var shortcut = PopupPreferences.selectionShortcut
    @State private var clickThrough = PopupPreferences.clickThrough
    @State private var panelDefaultWidth = PopupPreferences.panelDefaultWidth
    @State private var isEditingWidth = false
    @State private var appearanceTheme = PopupPreferences.appearanceTheme
    @State private var launchAtLogin = false
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    @State private var launchAtLoginError: String?
    @State private var suppressLaunchAtLoginChange = false

    var body: some View {
        ScrollView {
            settingsContent
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(windowBackground)
        .frame(minWidth: 560, idealWidth: 560, maxWidth: 560, minHeight: 560)
        .animation(.smooth(duration: 0.22), value: appearanceTheme)
        .onAppear {
            syncLaunchAtLoginStatus()
        }
        .onChange(of: shortcut) { _, newValue in
            PopupPreferences.selectionShortcut = newValue
        }
        .onChange(of: panelDefaultWidth) { _, newValue in
            if !isEditingWidth { PopupPreferences.panelDefaultWidth = newValue }
        }
        .onChange(of: clickThrough) { _, newValue in
            PopupPreferences.clickThrough = newValue
        }
        .onChange(of: appearanceTheme) { _, newValue in
            PopupPreferences.appearanceTheme = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: PopupPreferences.didChangeNotification)) { _ in
            shortcut = PopupPreferences.selectionShortcut
            clickThrough = PopupPreferences.clickThrough
            panelDefaultWidth = PopupPreferences.panelDefaultWidth
            appearanceTheme = PopupPreferences.appearanceTheme
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncLaunchAtLoginStatus()
        }
    }

    private var isLiquidGlass: Bool {
        appearanceTheme == .liquidGlass
    }

    @ViewBuilder
    private var settingsContent: some View {
        let content = VStack(alignment: .leading, spacing: 18) {
            header
            appearanceSection
            captureSection
            mirrorPanelSection
            generalSection
        }

        if isLiquidGlass {
            GlassEffectContainer(spacing: 18) {
                content
            }
        } else {
            content
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(headerIconFill)
                Image(systemName: "rectangle.on.rectangle.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)
            .if(isLiquidGlass) { view in
                view.glassEffect(.regular.tint(.cyan).interactive(), in: .rect(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Popup")
                    .font(.title2.weight(.semibold))
                Text("Keep a selected screen region floating above your workspace.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            primarySelectButton
        }
    }

    @ViewBuilder
    private var primarySelectButton: some View {
        if isLiquidGlass {
            Button {
                AppCoordinator.shared?.beginSelection()
            } label: {
                Label("Select Region", systemImage: "scope")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        } else {
            Button {
                AppCoordinator.shared?.beginSelection()
            } label: {
                Label("Select Region", systemImage: "scope")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var appearanceSection: some View {
        SettingsCard(title: "Appearance", systemImage: "paintpalette", theme: appearanceTheme) {
            SettingsRow(
                title: "Theme",
                subtitle: isLiquidGlass
                    ? "Glass surfaces, brighter reflections, and a more fluid macOS 26 treatment."
                    : "Quiet native settings surfaces with high contrast and minimal effects.",
                systemImage: "sparkles",
                theme: appearanceTheme
            ) {
                Picker("Theme", selection: $appearanceTheme) {
                    ForEach(PopupAppearanceTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }
        }
    }

    private var captureSection: some View {
        SettingsCard(title: "Capture", systemImage: "viewfinder", theme: appearanceTheme) {
            SettingsRow(
                title: "Screen Recording",
                subtitle: "Required for live region mirroring. After changing access, quit and relaunch Popup.",
                systemImage: "lock.shield",
                theme: appearanceTheme
            ) {
                Button {
                    ScreenRecordingSettings.open()
                } label: {
                    Label("Open Privacy Settings", systemImage: "gearshape")
                }
            }

            Divider()

            SettingsRow(
                title: "Trigger shortcut",
                subtitle: "Press Escape while recording a shortcut to keep the current one.",
                systemImage: "keyboard",
                theme: appearanceTheme
            ) {
                ShortcutRecorderView(shortcut: $shortcut)
                    .frame(width: 180, height: 30)
            }
        }
    }

    private var mirrorPanelSection: some View {
        SettingsCard(title: "Mirror Panel", systemImage: "macwindow.on.rectangle", theme: appearanceTheme) {
            sliderRow(
                title: "Default panel width",
                subtitle: "Maximum initial width when a new mirror opens.",
                systemImage: "arrow.left.and.right",
                valueText: "\(Int(panelDefaultWidth)) pt"
            ) {
                Slider(
                    value: $panelDefaultWidth,
                    in: PopupPreferences.panelWidthRange,
                    step: PopupPreferences.panelWidthStep
                ) { editing in
                    isEditingWidth = editing
                    if !editing { PopupPreferences.panelDefaultWidth = panelDefaultWidth }
                }
            }

            Divider()

            SettingsRow(
                title: "Click-through by default",
                subtitle: clickThrough
                    ? "New panels ignore mouse clicks. Disable it from the menu bar to recover controls."
                    : "New panels receive mouse clicks for hover controls and resizing.",
                systemImage: "cursorarrow.rays",
                theme: appearanceTheme
            ) {
                Toggle("", isOn: $clickThrough)
                    .labelsHidden()
                    .accessibilityIdentifier("clickThroughDefaultToggle")
            }
        }
    }

    private var generalSection: some View {
        SettingsCard(title: "General", systemImage: "switch.2", theme: appearanceTheme) {
            SettingsRow(
                title: "Launch at login",
                subtitle: launchAtLoginSubtitle,
                systemImage: "power",
                theme: appearanceTheme
            ) {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden()
                    .accessibilityIdentifier("launchAtLoginToggle")
                    .onChange(of: launchAtLogin) { _, newValue in
                        guard !suppressLaunchAtLoginChange else {
                            suppressLaunchAtLoginChange = false
                            return
                        }
                        setLaunchAtLogin(newValue)
                    }
            }

            if launchAtLoginStatus == .requiresApproval {
                Divider()
                SettingsRow(
                    title: "Login Items Approval",
                    subtitle: "Approval is pending in System Settings.",
                    systemImage: "exclamationmark.triangle",
                    theme: appearanceTheme
                ) {
                    Button {
                        SMAppService.openSystemSettingsLoginItems()
                    } label: {
                        Label("Open Login Items", systemImage: "arrow.up.forward.app")
                    }
                }
            }

            if let errorMessage = launchAtLoginError {
                Divider()
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var windowBackground: some View {
        if isLiquidGlass {
            LiquidGlassBackdrop()
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    private var headerIconFill: AnyShapeStyle {
        if isLiquidGlass {
            AnyShapeStyle(LinearGradient(
                colors: [.cyan, .blue, .indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        } else {
            AnyShapeStyle(.blue.gradient)
        }
    }

    private var launchAtLoginSubtitle: String {
        switch launchAtLoginStatus {
        case .enabled:
            "Popup starts automatically when you sign in."
        case .requiresApproval:
            "Waiting for approval in System Settings."
        default:
            "Keep Popup available from the menu bar after sign-in."
        }
    }

    private func sliderRow<Control: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        valueText: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                RowIcon(systemImage: systemImage, theme: appearanceTheme)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .font(.body.weight(.medium))
                        Spacer()
                        Text(valueText)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            control()
                .padding(.leading, 42)
        }
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
            syncLaunchAtLoginStatus()
        } catch {
            launchAtLoginError = error.localizedDescription
            syncLaunchAtLoginStatus()
        }
    }

    private func syncLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
        let isEnabled = launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
        guard launchAtLogin != isEnabled else { return }
        suppressLaunchAtLoginChange = true
        launchAtLogin = isEnabled
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let theme: PopupAppearanceTheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            VStack(spacing: 12) {
                content
            }
            .padding(14)
            .settingsSurface(theme)
        }
    }
}

private struct SettingsRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let theme: PopupAppearanceTheme
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RowIcon(systemImage: systemImage, theme: theme)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            accessory
        }
    }
}

private struct RowIcon: View {
    let systemImage: String
    let theme: PopupAppearanceTheme

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.tint)
            .frame(width: 30, height: 30)
            .background(.tint.opacity(theme == .liquidGlass ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .if(theme == .liquidGlass) { view in
                view.glassEffect(.regular.tint(.cyan.opacity(0.2)).interactive(), in: .rect(cornerRadius: 6))
            }
    }
}

private struct LiquidGlassBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            LinearGradient(
                colors: [
                    .cyan.opacity(0.18),
                    .blue.opacity(0.08),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .center
            )

            LinearGradient(
                colors: [
                    .clear,
                    .indigo.opacity(0.10),
                    .mint.opacity(0.12)
                ],
                startPoint: .center,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private extension View {
    @ViewBuilder
    func settingsSurface(_ theme: PopupAppearanceTheme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        if theme == .liquidGlass {
            self
                .background(.thinMaterial, in: shape)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
                .overlay {
                    shape.strokeBorder(.white.opacity(0.24))
                }
        } else {
            self
                .background(.background.secondary, in: shape)
                .overlay {
                    shape.strokeBorder(.separator.opacity(0.55))
                }
        }
    }

    @ViewBuilder
    func `if`<Transformed: View>(
        _ condition: Bool,
        transform: (Self) -> Transformed
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

#Preview {
    ContentView()
}
