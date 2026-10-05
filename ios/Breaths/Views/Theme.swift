import SwiftUI
import UIKit

extension BreathState {
    /// One fixed hue per state, stepped separately for light and dark mode.
    var color: Color {
        switch self {
        case .asleep: Color(light: 0x2A78D6, dark: 0x3987E5)
        case .awake: Color(light: 0xEB6834, dark: 0xD95926)
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Date {
    /// "Mon 5 Oct" (order follows the phone's region).
    var dayLabel: String { formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
    /// "14:18" or "2:18 PM", following the phone's 12/24-hour setting.
    var timeLabel: String { formatted(.dateTime.hour().minute()) }
}

/// A small colored dot that identifies a state next to its label.
struct StateDot: View {
    let state: BreathState
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(state.color).frame(width: size, height: size)
    }
}

/// Segmented Asleep / Awake picker with colored dots.
struct StatePicker: View {
    @Binding var selection: BreathState

    var body: some View {
        Picker("State", selection: $selection) {
            ForEach(BreathState.allCases) { s in
                Text(s.label).tag(s)
            }
        }
        .pickerStyle(.segmented)
    }
}

func catTitle(_ name: String) -> String {
    let n = name.trimmingCharacters(in: .whitespaces)
    return n.isEmpty ? "Your cat" : n
}
