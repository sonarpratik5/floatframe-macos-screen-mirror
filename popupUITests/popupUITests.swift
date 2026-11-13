//
//  popupUITests.swift
//  popupUITests
//
//  Created by Pratik Sonar on 29.08.26.
//

import XCTest

final class popupUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesAsAccessoryApp() throws {
        let app = makeApp(resetPreferences: false)
        app.launch()

        let launched = app.wait(for: .runningBackground, timeout: 5)
            || app.wait(for: .runningForeground, timeout: 1)

        XCTAssertTrue(launched)
    }

    @MainActor
    func testSettingsWindowShowsCoreControls() throws {
        let app = makeApp(resetPreferences: true)
        app.launchArguments.append("--uitest-open-settings")
        app.launch()

        XCTAssertTrue(app.staticTexts["Screen Recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Appearance"].exists)
        XCTAssertTrue(app.staticTexts["Theme"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Standard"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Liquid Glass"].exists)
        XCTAssertTrue(app.buttons["Open Privacy Settings"].exists)
        XCTAssertTrue(app.staticTexts["Trigger shortcut"].exists)
        XCTAssertTrue(app.staticTexts["Default panel width"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["clickThroughDefaultToggle"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["launchAtLoginToggle"].exists)
    }

    @MainActor
    func testAppearanceThemeSwitchPersistsAcrossRelaunch() throws {
        let app = makeApp(resetPreferences: true)
        app.launchArguments.append("--uitest-open-settings")
        app.launch()

        XCTAssertTrue(app.staticTexts["Screen Recording"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["Liquid Glass"].click()
        XCTAssertTrue(app.staticTexts["Glass surfaces, brighter reflections, and a more fluid macOS 26 treatment."].waitForExistence(timeout: 2))

        app.terminate()

        let relaunchedApp = makeApp(resetPreferences: false)
        relaunchedApp.launchArguments.append("--uitest-open-settings")
        relaunchedApp.launch()

        XCTAssertTrue(relaunchedApp.staticTexts["Glass surfaces, brighter reflections, and a more fluid macOS 26 treatment."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSelectionOverlayOpensAndCancelsWithEscape() throws {
        let app = makeApp(resetPreferences: true)
        app.launchArguments.append("--uitest-begin-selection")
        app.launch()

        let overlay = app.groups["Drag to select a region. Escape to cancel."]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testSelectionOverlayCompletesDragSelection() throws {
        let app = makeApp(resetPreferences: true)
        app.launchArguments.append("--uitest-begin-selection")
        app.launchArguments.append("--uitest-skip-mirror-creation")
        app.launch()

        let overlay = app.groups["Drag to select a region. Escape to cancel."]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))

        let start = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        let end = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.60))
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))
    }

    private func makeApp(resetPreferences: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        if resetPreferences {
            app.launchArguments.append("--uitest-reset-preferences")
        }
        return app
    }
}
