import Foundation
import Observation
import SwiftUI
import DocumentCore

/// Student preferences, backed by `UserDefaults`. Every property is stored
/// under a stable key so a change survives relaunch; the observable state is
/// one value struct, so SwiftUI updates on any change.
@MainActor
@Observable
final class SettingsStore {
    enum Appearance: String, CaseIterable, Identifiable, Hashable {
        case system, light, dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    enum Keys {
        static let pencilOnly = "settings.input.pencilOnly"
        static let fingerDrawing = "settings.input.fingerDrawing"
        static let leftHanded = "settings.input.leftHanded"
        static let defaultPaperKind = "settings.paper.defaultKind"
        static let defaultPageSize = "settings.paper.defaultPageSize"
        static let appearance = "settings.appearance"
        static let hasSeenOnboarding = "settings.onboarding.seen"
        static let lastBackupAt = "settings.backup.lastSucceededAt"
    }

    /// The observable payload. Reading any accessor below reads this value, so
    /// the `@Observable` machinery tracks every property.
    private struct Values: Equatable {
        var pencilOnly = true
        var fingerDrawing = false
        var leftHanded = false
        var defaultPaperKind: PaperKind = .lined
        var defaultPageSize: PageSizeChoice = .letter
        var appearance: Appearance = .system
        var hasSeenOnboarding = false
        var lastBackupAt: Date?
    }

    private var values = Values()
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = Values()
        if defaults.object(forKey: Keys.pencilOnly) != nil { loaded.pencilOnly = defaults.bool(forKey: Keys.pencilOnly) }
        if defaults.object(forKey: Keys.fingerDrawing) != nil { loaded.fingerDrawing = defaults.bool(forKey: Keys.fingerDrawing) }
        if defaults.object(forKey: Keys.leftHanded) != nil { loaded.leftHanded = defaults.bool(forKey: Keys.leftHanded) }
        if let raw = defaults.string(forKey: Keys.defaultPaperKind), let kind = PaperKind(rawValue: raw) { loaded.defaultPaperKind = kind }
        if let raw = defaults.string(forKey: Keys.defaultPageSize), let size = PageSizeChoice(rawValue: raw) { loaded.defaultPageSize = size }
        if let raw = defaults.string(forKey: Keys.appearance), let appearance = Appearance(rawValue: raw) { loaded.appearance = appearance }
        loaded.hasSeenOnboarding = defaults.bool(forKey: Keys.hasSeenOnboarding)
        loaded.lastBackupAt = defaults.object(forKey: Keys.lastBackupAt) as? Date
        self.values = loaded
    }

    // MARK: Input

    /// Apple Pencil only (the default): a finger pans and selects, never draws.
    var pencilOnly: Bool {
        get { values.pencilOnly }
        set { values.pencilOnly = newValue; defaults.set(newValue, forKey: Keys.pencilOnly) }
    }

    /// Draw with a finger as well as the Pencil.
    var fingerDrawing: Bool {
        get { values.fingerDrawing }
        set { values.fingerDrawing = newValue; defaults.set(newValue, forKey: Keys.fingerDrawing) }
    }

    /// Mirrors the primary controls to the leading edge.
    var leftHanded: Bool {
        get { values.leftHanded }
        set { values.leftHanded = newValue; defaults.set(newValue, forKey: Keys.leftHanded) }
    }

    // MARK: Paper defaults

    var defaultPaperKind: PaperKind {
        get { values.defaultPaperKind }
        set { values.defaultPaperKind = newValue; defaults.set(newValue.rawValue, forKey: Keys.defaultPaperKind) }
    }

    var defaultPageSize: PageSizeChoice {
        get { values.defaultPageSize }
        set { values.defaultPageSize = newValue; defaults.set(newValue.rawValue, forKey: Keys.defaultPageSize) }
    }

    // MARK: Appearance and onboarding

    var appearance: Appearance {
        get { values.appearance }
        set { values.appearance = newValue; defaults.set(newValue.rawValue, forKey: Keys.appearance) }
    }

    var hasSeenOnboarding: Bool {
        get { values.hasSeenOnboarding }
        set { values.hasSeenOnboarding = newValue; defaults.set(newValue, forKey: Keys.hasSeenOnboarding) }
    }

    var lastBackupAt: Date? {
        get { values.lastBackupAt }
        set {
            values.lastBackupAt = newValue
            if let newValue { defaults.set(newValue, forKey: Keys.lastBackupAt) } else { defaults.removeObject(forKey: Keys.lastBackupAt) }
        }
    }

    // MARK: Derived

    /// The template a new notebook or quick note starts from.
    var defaultTemplate: PaperTemplate { .preset(defaultPaperKind) }

    /// Input policy handed to the editor's canvases.
    var editorInput: EditorInputSettings {
        EditorInputSettings(pencilOnly: pencilOnly, fingerDrawing: fingerDrawing, leftHanded: leftHanded)
    }

    /// Restores the shipped defaults (used by tests and Settings > Reset).
    func resetToDefaults() {
        pencilOnly = true
        fingerDrawing = false
        leftHanded = false
        defaultPaperKind = .lined
        defaultPageSize = .letter
        appearance = .system
    }
}
