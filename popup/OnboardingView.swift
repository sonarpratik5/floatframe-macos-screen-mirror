import AppKit
import ScreenCaptureKit
import SwiftUI

// MARK: - Window Controller

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var completed = false
    var onComplete: (() -> Void)?
    var onDismiss: (() -> Void)?

    func show() {
        let contentView = OnboardingView { [weak self] in
            self?.finish()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: contentView)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        window?.close()
        window = nil
        onComplete?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !completed else { return }
        completed = true
        window = nil
        onDismiss?()
    }
}

// MARK: - Step

private enum OnboardingStep: Int, CaseIterable {
    case welcome, howItWorks, permission, ready
}

// MARK: - Permission Status

private enum PermissionStatus {
    case idle, checking, granted, openSettings
}

// MARK: - Main View

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var permissionStatus: PermissionStatus = .idle

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.35)
            footer
        }
        .frame(width: 560, height: 540)
        .background(windowBackground)
        .animation(.spring(duration: 0.35), value: step)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard step == .permission, permissionStatus == .openSettings else { return }
            silentlyCheckPermission()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            WelcomeStep()
        case .howItWorks:
            HowItWorksStep()
        case .permission:
            PermissionStep(status: permissionStatus)
        case .ready:
            ReadyStep()
        }
    }

    // MARK: Background

    private var windowBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [.cyan.opacity(0.06), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            LinearGradient(
                colors: [.clear, .indigo.opacity(0.04)],
                startPoint: .center,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 14) {
            progressDots
            actionButtons
        }
        .padding(.horizontal, 32)
        .padding(.top, 18)
        .padding(.bottom, 24)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.22))
                    .frame(width: s == step ? 22 : 6, height: 6)
                    .animation(.spring(duration: 0.3), value: step)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch step {
        case .welcome, .howItWorks:
            primaryButton("Continue") { advance() }

        case .permission:
            switch permissionStatus {
            case .idle:
                primaryButton("Grant Screen Recording Access") { requestPermission() }
                skipButton
            case .checking:
                primaryButton("Checking\u{2026}") {}
                    .disabled(true)
                skipButton
            case .granted:
                primaryButton("Continue") { advance() }
            case .openSettings:
                primaryButton("Open Privacy Settings") { ScreenRecordingSettings.open() }
                skipButton
            }

        case .ready:
            primaryButton("Get Started") { onComplete() }
        }
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(OnboardingPrimaryButtonStyle())
    }

    private var skipButton: some View {
        Button("I'll set this up later") { advance() }
            .buttonStyle(.plain)
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }

    // MARK: Navigation

    private func advance() {
        withAnimation(.spring(duration: 0.35)) {
            switch step {
            case .welcome:    step = .howItWorks
            case .howItWorks: step = .permission
            case .permission: step = .ready
            case .ready:      onComplete()
            }
        }
    }

    // MARK: Permission

    private func requestPermission() {
        permissionStatus = .checking
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                await MainActor.run {
                    withAnimation { permissionStatus = .granted }
                }
                try await Task.sleep(nanoseconds: 900_000_000)
                withAnimation(.spring(duration: 0.35)) { step = .ready }
            } catch {
                await MainActor.run { permissionStatus = .openSettings }
            }
        }
    }

    private func silentlyCheckPermission() {
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                await MainActor.run {
                    withAnimation { permissionStatus = .granted }
                }
            } catch {}
        }
    }
}

// MARK: - Welcome Step

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            appIcon

            Spacer().frame(height: 20)

            Text("Welcome to Popup")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)

            Spacer().frame(height: 8)

            Text("Mirror any part of your screen into a floating panel\nthat stays on top of your work \u{2014} entirely on your device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 24)

            privacyPills

            Spacer()
        }
        .padding(.horizontal, 52)
    }

    private var appIcon: some View {
        ZStack {
            // Outer glow rings
            Circle()
                .fill(.blue.opacity(0.06))
                .frame(width: 136, height: 136)
            Circle()
                .fill(.blue.opacity(0.09))
                .frame(width: 116, height: 116)

            // Icon tile
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [.cyan, Color(hue: 0.58, saturation: 0.85, brightness: 0.95), .indigo],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 96, height: 96)
                .shadow(color: .blue.opacity(0.4), radius: 22, y: 8)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                }

            Image(systemName: "rectangle.on.rectangle.circle.fill")
                .font(.system(size: 48, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
        .frame(width: 136, height: 136)
    }

    private var privacyPills: some View {
        HStack(spacing: 8) {
            PrivacyPill(icon: "lock.fill", color: .green, text: "Local Only")
            PrivacyPill(icon: "wifi.slash", color: .blue, text: "No Network")
            PrivacyPill(icon: "eye.slash.fill", color: .purple, text: "No Analytics")
        }
    }
}

// MARK: - How It Works Step

private struct HowItWorksStep: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Here's how it works")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)

            Spacer().frame(height: 6)

            Text("Three steps. No configuration required.")
                .font(.body)
                .foregroundStyle(.secondary)

            Spacer().frame(height: 28)

            // Unified card with dividers — matches Apple Settings style
            VStack(spacing: 0) {
                FeatureRow(
                    number: "1",
                    icon: "scope",
                    color: .blue,
                    title: "Select any region",
                    description: "Press \u{21e7}\u{2318}P or use the menu bar, then draw a rectangle over anything on screen."
                )
                Divider().padding(.leading, 62)
                FeatureRow(
                    number: "2",
                    icon: "rectangle.on.rectangle",
                    color: .indigo,
                    title: "It floats above everything",
                    description: "Your mirror stays visible across all Spaces and full-screen apps \u{2014} always on top."
                )
                Divider().padding(.leading, 62)
                FeatureRow(
                    number: "3",
                    icon: "lock.shield.fill",
                    color: .green,
                    title: "Completely private",
                    description: "Pixels never leave your Mac. No files saved, no data sent, no servers involved."
                )
            }
            .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.secondary.opacity(0.1)))

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Permission Step

private struct PermissionStep: View {
    let status: PermissionStatus

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            statusIcon

            Spacer().frame(height: 22)

            Text(status == .granted ? "Access granted" : "One permission needed")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
                .animation(.none, value: status)

            Spacer().frame(height: 10)

            if status == .granted {
                Text("Popup can now mirror your screen. Everything captured stays on your device and is never saved or transmitted.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                VStack(spacing: 18) {
                    Text("Popup needs **Screen Recording** access to mirror a selected region. This is the only permission it uses.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 400)

                    infoCallout
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Spacer()
        }
        .padding(.horizontal, 48)
        .animation(.spring(duration: 0.4), value: status == .granted)
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(status == .granted ? Color.green.opacity(0.12) : Color.blue.opacity(0.09))
                .frame(width: 104, height: 104)
            Circle()
                .fill(status == .granted ? Color.green.opacity(0.08) : Color.blue.opacity(0.06))
                .frame(width: 120, height: 120)

            Image(systemName: status == .granted ? "checkmark.shield.fill" : "viewfinder")
                .font(.system(size: 44, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(status == .granted ? .green : .blue)
                .contentTransition(.symbolEffect(.replace))
        }
        .animation(.spring(duration: 0.45), value: status == .granted)
    }

    private var infoCallout: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 14))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("What macOS will ask")
                    .font(.caption.weight(.semibold))
                Text("You'll be directed to **Privacy & Security \u{2192} Screen & System Audio Recording**. You may need to quit and relaunch Popup after granting access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.blue.opacity(0.14)))
    }
}

// MARK: - Ready Step

private struct ReadyStep: View {
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            checkmarkIcon
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)

            Spacer().frame(height: 22)

            Text("You're all set!")
                .font(.largeTitle.weight(.bold))
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)

            Spacer().frame(height: 10)

            Text("Popup lives in your menu bar. Use it to keep any part of your screen floating while you work.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 6)

            Spacer().frame(height: 28)

            quickTip
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 6)

            Spacer()
        }
        .padding(.horizontal, 48)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.65).delay(0.05)) {
                appeared = true
            }
        }
    }

    private var checkmarkIcon: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.07))
                .frame(width: 120, height: 120)
            Circle()
                .fill(Color.green.opacity(0.11))
                .frame(width: 104, height: 104)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: appeared)
        }
    }

    private var quickTip: some View {
        HStack(spacing: 14) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text("Quick tip")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                HStack(spacing: 5) {
                    Text("Press")
                        .foregroundStyle(.secondary)
                    Text("\u{21e7}\u{2318}P")
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.13), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.secondary.opacity(0.18)))
                    Text("from anywhere to select a region")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.orange.opacity(0.14)))
        .frame(maxWidth: 380)
    }
}

// MARK: - Shared Components

private struct FeatureRow: View {
    let number: String
    let icon: String
    let color: Color
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(color.opacity(0.13))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color)
            }
            .padding(12)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1.5)
            }
            .padding(.top, 13)
            .padding(.trailing, 14)
            .padding(.bottom, 13)

            Spacer(minLength: 0)
        }
    }
}

private struct PrivacyPill: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(color.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.18)))
    }
}

// MARK: - Button Style

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                Color.accentColor.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .shadow(
                color: isEnabled ? Color.accentColor.opacity(configuration.isPressed ? 0 : 0.28) : .clear,
                radius: 8, y: 3
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    OnboardingView {}
}
