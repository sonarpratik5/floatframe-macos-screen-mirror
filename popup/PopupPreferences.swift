import AppKit
import Carbon.HIToolbox

struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyEquivalent: String

    static let defaultSelection = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_P),
        modifiers: UInt32(cmdKey | shiftKey),
        keyEquivalent: "p"
    )

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        parts.append(keyEquivalent.uppercased())
        return parts.joined(separator: "-")
    }

    var glyphDisplayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyEquivalent.uppercased())
        return parts.joined()
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        return mask
    }
}

enum PopupAppearanceTheme: String, CaseIterable, Identifiable {
    case standard
    case liquidGlass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard:
            "Standard"
        case .liquidGlass:
            "Liquid Glass"
        }
    }
}

enum PopupPreferences {
    static let didChangeNotification = Notification.Name("PopupPreferencesDidChange")
    static let defaultPanelOpacity: Double = 1
    static let panelOpacityRange: ClosedRange<Double> = 0.2...1
    static let defaultPanelWidth: Double = 420
    static let panelWidthRange: ClosedRange<Double> = 200...800
    static let panelWidthStep: Double = 10

    private enum Key {
        static let selectionShortcut = "selectionShortcut"
        static let panelOpacity = "panelOpacity"
        static let clickThrough = "clickThrough"
        static let panelDefaultWidth = "panelDefaultWidth"
        static let appearanceTheme = "appearanceTheme"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"

        static let all = [
            selectionShortcut,
            panelOpacity,
            clickThrough,
            panelDefaultWidth,
            appearanceTheme,
            hasCompletedOnboarding
        ]
    }

    static var selectionShortcut: KeyboardShortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: Key.selectionShortcut),
                  let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) else {
                return .defaultSelection
            }
            return shortcut
        }
        set {
            guard newValue != selectionShortcut else { return }
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Key.selectionShortcut)
            }
            notifyChange()
        }
    }

    static var panelOpacity: Double {
        get {
            let value = UserDefaults.standard.double(forKey: Key.panelOpacity)
            return value == 0 ? defaultPanelOpacity : clamped(value, to: panelOpacityRange)
        }
        set {
            let clamped = clamped(newValue, to: panelOpacityRange)
            guard abs(clamped - panelOpacity) > 0.001 else { return }
            UserDefaults.standard.set(clamped, forKey: Key.panelOpacity)
            notifyChange()
        }
    }

    static var clickThrough: Bool {
        get { UserDefaults.standard.bool(forKey: Key.clickThrough) }
        set {
            guard newValue != clickThrough else { return }
            UserDefaults.standard.set(newValue, forKey: Key.clickThrough)
            notifyChange()
        }
    }

    static var panelDefaultWidth: Double {
        get {
            let value = UserDefaults.standard.double(forKey: Key.panelDefaultWidth)
            return value == 0 ? defaultPanelWidth : clamped(value, to: panelWidthRange)
        }
        set {
            let clamped = clamped(newValue, to: panelWidthRange)
            guard abs(clamped - panelDefaultWidth) > 0.5 else { return }
            UserDefaults.standard.set(clamped, forKey: Key.panelDefaultWidth)
            notifyChange()
        }
    }

    static var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Key.hasCompletedOnboarding) }
        set { UserDefaults.standard.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    static var appearanceTheme: PopupAppearanceTheme {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: Key.appearanceTheme),
                  let theme = PopupAppearanceTheme(rawValue: rawValue) else {
                return .standard
            }
            return theme
        }
        set {
            guard newValue != appearanceTheme else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.appearanceTheme)
            notifyChange()
        }
    }

    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func resetForTesting() {
        removePersistedValuesForTesting()
        notifyChange()
    }

    static func snapshotPersistedValuesForTesting() -> [String: Any] {
        Key.all.reduce(into: [:]) { result, key in
            result[key] = UserDefaults.standard.object(forKey: key)
        }
    }

    static func restorePersistedValuesForTesting(_ values: [String: Any]) {
        for key in Key.all {
            if let value = values[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    static func removePersistedValuesForTesting() {
        for key in Key.all {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func notifyChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

extension NSEvent.ModifierFlags {
    var carbonHotKeyModifiers: UInt32 {
        var result: UInt32 = 0
        if contains(.command) { result |= UInt32(cmdKey) }
        if contains(.shift) { result |= UInt32(shiftKey) }
        if contains(.option) { result |= UInt32(optionKey) }
        if contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}
