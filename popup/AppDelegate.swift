import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var onboardingController: OnboardingWindowController?
    private var isTerminating = false
    private var didSendTerminateReply = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory policy is required even in preview mode: without it the app
        // never reaches the background-running state that Xcode's launch monitor
        // waits for, causing a 30-second "failed to launch" timeout before the
        // preview JIT bootstrap can even begin.
        NSApp.setActivationPolicy(.accessory)

        // In preview mode the coordinator (and its NSStatusItem) must NOT be
        // started — the status-bar item creation races with the JIT bootstrap
        // handshake and causes a separate 30-second connection timeout.
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--uitest-reset-preferences") {
            PopupPreferences.resetForTesting()
        }

        // --show-onboarding resets the flag so the flow is visible on this run.
        if arguments.contains("--show-onboarding") {
            PopupPreferences.hasCompletedOnboarding = false
        }

        // Skip onboarding for UI test runs so existing test flow is unaffected.
        let isUITest = arguments.contains(where: { $0.hasPrefix("--uitest-") })
        if !PopupPreferences.hasCompletedOnboarding && !isUITest {
            showOnboarding(arguments: arguments)
        } else {
            startCoordinator(arguments: arguments)
        }
    }

    private func showOnboarding(arguments: [String]) {
        let controller = OnboardingWindowController()
        controller.onComplete = { [weak self] in
            PopupPreferences.hasCompletedOnboarding = true
            self?.onboardingController = nil
            self?.startCoordinator(arguments: ProcessInfo.processInfo.arguments)
        }
        controller.onDismiss = { [weak self] in
            self?.onboardingController = nil
            self?.startCoordinator(arguments: ProcessInfo.processInfo.arguments)
        }
        onboardingController = controller
        controller.show()
    }

    private func startCoordinator(arguments: [String]) {
        coordinator = AppCoordinator(
            skipsMirrorCreationForUITests: arguments.contains("--uitest-skip-mirror-creation")
        )
        coordinator?.start()

        if arguments.contains("--uitest-open-settings") {
            coordinator?.openSettingsWindow()
        }
        if arguments.contains("--uitest-begin-selection") {
            coordinator?.beginSelection()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Guard against a second call (e.g. double Quit keystroke) while the first
        // termination is already in progress. Calling reply() more than once is an
        // AppKit programming error.
        guard !isTerminating else { return .terminateLater }
        isTerminating = true

        let coord = coordinator
        coordinator = nil

        // Primary path: await full SCStream XPC teardown before replying.
        // All stream.stopCapture() calls run concurrently inside stopAndWait().
        Task { @MainActor in
            await coord?.stopAndWait()
            sendTerminateReply()
        }

        // Safety net: force the reply after 2 seconds in case any stopCapture()
        // XPC call stalls. Uses DispatchQueue (not Task.sleep) so it cannot be
        // cancelled by the Swift concurrency runtime during shutdown.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.sendTerminateReply()
        }

        return .terminateLater
    }

    private func sendTerminateReply() {
        guard !didSendTerminateReply else { return }
        didSendTerminateReply = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
