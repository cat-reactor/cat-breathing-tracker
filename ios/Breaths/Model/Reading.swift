import Foundation
import SwiftData

enum BreathState: String, CaseIterable, Identifiable, Codable {
    case asleep
    case awake

    var id: String { rawValue }
    var label: String { self == .asleep ? "Asleep" : "Awake" }
}

/// One breathing-rate reading.
/// Every stored property has a default value so the store can sync with iCloud (CloudKit).
@Model
final class Reading {
    var date: Date = Date()
    var stateRaw: String = BreathState.awake.rawValue
    var bpm: Int = 0
    var note: String = ""

    init(date: Date, state: BreathState, bpm: Int, note: String = "") {
        self.date = date
        self.stateRaw = state.rawValue
        self.bpm = bpm
        self.note = note
    }

    var state: BreathState {
        get { BreathState(rawValue: stateRaw) ?? .awake }
        set { stateRaw = newValue.rawValue }
    }

    /// Same minute, state and count: treated as the same reading when importing.
    var duplicateKey: String { Reading.duplicateKey(date: date, state: state, bpm: bpm) }

    static func duplicateKey(date: Date, state: BreathState, bpm: Int) -> String {
        "\(Int((date.timeIntervalSince1970 / 60).rounded()))|\(state.rawValue)|\(bpm)"
    }
}

/// Settings stored with @AppStorage.
enum Prefs {
    static let petName = "petName"
    static let appearance = "appearance"
    static let alertLevel = "alertLevel"
    static let countState = "countState"
    static let logFilter = "logFilter"
    static let trendRange = "trendRange"

    static let defaultAlertLevel = 30
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Turns on once the app has an iCloud container (needs a paid Apple Developer account).
enum AppConfig {
    static let iCloudSyncEnabled = false
}

extension Reading {
    func isOverAlert(_ level: Int) -> Bool { state == .asleep && bpm > level }
}
