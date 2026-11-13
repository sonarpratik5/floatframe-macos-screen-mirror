# Popup

Popup is a macOS menu bar utility that keeps a selected screen region visible in a floating live mirror while you work. Capture uses ScreenCaptureKit and stays on your Mac; the app does not save or upload captured content.

## Requirements

- macOS 26.5 or later (the project's current deployment target).
- Xcode with the macOS 26.5 SDK or later, selected with `xcode-select`.
- No third-party dependencies or package installation.

## Build and run

1. Open `popup.xcodeproj` in Xcode and select the shared `popup` scheme.
2. For a signed installation or distribution build, choose your own development team in Signing & Capabilities. Keep the existing `me.popup` bundle identifier for your existing local installation so its preferences and privacy permissions continue to apply; use a bundle identifier you own for distribution.
3. Run the app. Complete onboarding, then use the Popup menu bar item or **Shift-Command-P** to select a region. Press **Escape** to cancel selection.
4. Allow Screen Recording when macOS requests it. You can also manage access in **System Settings → Privacy & Security → Screen Recording** (called **Screen & System Audio Recording** on some macOS versions). Relaunch Popup if macOS asks you to.

Popup runs as an accessory app, so look for its menu bar item rather than a Dock icon. Settings includes appearance, shortcut, panel width, click-through, and launch-at-login controls. Adjust opacity in the menu bar menu, and use **Disable Click-Through** there if you need to interact with panels again.

The shared scheme follows the normal first-run behavior. To revisit onboarding during development, enable the optional `--show-onboarding` launch argument in **Product → Scheme → Edit Scheme → Run → Arguments**; disable it again afterward.

For a command-line build without a signing identity:

```sh
xcodebuild -project popup.xcodeproj -scheme popup \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

## Validation

```sh
bash scripts/check.sh             # Debug + Release builds and unit tests
bash scripts/check.sh --ui-tests  # Also run the existing UI tests
```

The script uses local ad hoc signing, requires no development team, and writes build products under `build/DerivedData`. Set `POPUP_DERIVED_DATA_PATH` to use another directory. It runs tests serially because the app and UI tests share persisted preferences and desktop state.

UI tests require an unlocked graphical macOS session and may request developer automation permission. They open Settings and selection overlays, reset Popup's preferences, and skip actual mirror creation. Run them when you can spare the desktop. Real live capture still needs a manual check with Screen Recording permission; automated tests do not validate captured pixels.

## Project layout

- `popup/`: app lifecycle, onboarding, preferences, selection, capture, and floating panel UI.
- `MirrorPanelLayout.swift`: shared panel geometry, included explicitly in the app target.
- `popupTests/`: Swift Testing unit coverage.
- `popupUITests/`: XCTest UI coverage.
- `handoff.md`: internal architecture notes and historical validation findings; retained in the repository, excluded from the app bundle.

## Current limitations

- Selections spanning displays are clipped to the display with the largest intersection.
- Regions inside a normal app window prefer window capture. Other regions use display capture and can reflect later overlapping windows.
- Minimizing a source window can pause its window-backed stream. Protected content remains subject to macOS capture restrictions.
- Mirrors are view-only. Click-through sends clicks to the app beneath the panel, rather than forwarding them to the captured source.
- The app icon catalog currently contains placeholder slots. Distribution also requires your own signing, provisioning, and release review.
