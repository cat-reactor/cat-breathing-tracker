import SwiftUI
import SwiftData
import UIKit

struct CountView: View {
    static var duration: TimeInterval {
        #if DEBUG
        // Test builds only: `defaults write <bundle id> debugCountSeconds 5` shortens the count.
        let override = UserDefaults.standard.double(forKey: "debugCountSeconds")
        if override > 0 { return override }
        #endif
        return 60
    }

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Prefs.petName) private var petName = ""
    @AppStorage(Prefs.countState) private var countState: BreathState = .asleep
    @Query(CountView.lastAsleepDescriptor) private var lastAsleep: [Reading]

    private enum Phase { case idle, running, done }

    @State private var phase: Phase = .idle
    @State private var start = Date()
    @State private var count = 0
    @State private var lockUntil = Date.distantPast
    @State private var finishTask: Task<Void, Never>?
    @State private var pulse = false
    @State private var pending: PendingCount?

    private let tapHaptic = UIImpactFeedbackGenerator(style: .light)
    private let doneHaptic = UINotificationFeedbackGenerator()

    static var lastAsleepDescriptor: FetchDescriptor<Reading> {
        var d = FetchDescriptor<Reading>(
            predicate: #Predicate<Reading> { $0.stateRaw == "asleep" },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        d.fetchLimit = 1
        return d
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(petTitle(petName)) is…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    StatePicker(selection: $countState)
                }

                pad

                Button("Reset", role: .cancel) { reset() }
                    .buttonStyle(.bordered)
                    .opacity(phase == .running ? 1 : 0)
                    .disabled(phase != .running)

                Text("Tap once each time the chest rises. The 1-minute timer starts with your first tap.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let last = lastAsleep.first {
                    Text("Last asleep reading: \(Text("\(last.bpm)/min").bold().foregroundStyle(.primary)) · \(last.date.dayLabel), \(last.date.timeLabel)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .navigationTitle("Count breaths")
            .sheet(item: $pending) { p in
                ResultSheet(pending: p, onSave: save, onDiscard: { pending = nil; reset() })
            }
            .onChange(of: scenePhase) { _, newPhase in
                // The timer may have run out while the app was in the background.
                if newPhase == .active, phase == .running, Date().timeIntervalSince(start) >= Self.duration { finish() }
            }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    // MARK: Tap pad

    private var pad: some View {
        TimelineView(.animation(paused: phase != .running)) { timeline in
            let elapsed = phase == .running ? min(Self.duration, timeline.date.timeIntervalSince(start))
                : phase == .done ? Self.duration : 0
            ZStack {
                Circle()
                    .fill(Color(.secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: 8)
                    .padding(10)
                Circle()
                    .trim(from: 0, to: elapsed / Self.duration)
                    .stroke(countState.color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(10)
                    .opacity(phase == .idle ? 0 : 1)
                VStack(spacing: 8) {
                    Text(phase == .idle ? "Tap" : "\(count)")
                        .font(.system(size: phase == .idle ? 44 : 84, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(subtitle(elapsed: elapsed))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: 300)
        .aspectRatio(1, contentMode: .fit)
        .scaleEffect(pulse ? 0.965 : 1)
        // Count on touch-down (not lift) so fast taps register immediately.
        .overlay { TouchDownArea { tap() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(phase == .idle ? "Tap for each breath" : "\(count) breaths")
        .accessibilityAction { tap() }
    }

    private func subtitle(elapsed: TimeInterval) -> String {
        switch phase {
        case .idle: "on the first breath"
        case .running: "\(Int((Self.duration - elapsed).rounded(.up))) s left"
        case .done: "Time’s up"
        }
    }

    // MARK: Counting

    private func tap() {
        let now = Date()
        switch phase {
        case .idle:
            guard now >= lockUntil else { return } // ignore stray taps right after a count
            start = now
            count = 1
            phase = .running
            UIApplication.shared.isIdleTimerDisabled = true
            tapHaptic.prepare()
            finishTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.duration))
                if !Task.isCancelled { finish() }
            }
        case .running:
            if now.timeIntervalSince(start) >= Self.duration { finish(); return }
            count += 1
        case .done:
            return
        }
        tapHaptic.impactOccurred()
        withAnimation(.easeOut(duration: 0.06)) { pulse = true }
        withAnimation(.easeOut(duration: 0.14).delay(0.06)) { pulse = false }
    }

    private func finish() {
        guard phase == .running else { return }
        finishTask?.cancel()
        phase = .done
        UIApplication.shared.isIdleTimerDisabled = false
        doneHaptic.notificationOccurred(.success)
        pending = PendingCount(bpm: count, date: start, state: countState)
    }

    private func reset() {
        finishTask?.cancel()
        phase = .idle
        count = 0
        lockUntil = Date().addingTimeInterval(0.7)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func save(_ result: PendingCount) {
        context.insert(Reading(date: result.date, state: result.state, bpm: result.bpm, note: result.note))
        try? context.save()
        countState = result.state
        pending = nil
        reset()
    }
}

/// A circular touch area that reports every finger the moment it lands.
private struct TouchDownArea: UIViewRepresentable {
    let onTouchDown: () -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = false
        view.onTouchDown = onTouchDown
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.onTouchDown = onTouchDown
    }

    final class TouchView: UIView {
        var onTouchDown: (() -> Void)?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for _ in touches { onTouchDown?() }
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            let radius = min(bounds.width, bounds.height) / 2
            return hypot(point.x - bounds.midX, point.y - bounds.midY) <= radius
        }
    }
}

struct PendingCount: Identifiable {
    let id = UUID()
    var bpm: Int
    var date: Date
    var state: BreathState
    var note = ""
}

/// Shown when the minute is up: adjust, pick the state, add a note, save.
struct ResultSheet: View {
    @AppStorage(Prefs.alertLevel) private var alertLevel = Prefs.defaultAlertLevel
    @State var pending: PendingCount
    let onSave: (PendingCount) -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("1-minute count")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                stepButton("minus", label: "One fewer") { if pending.bpm > 1 { pending.bpm -= 1 } }
                Spacer()
                VStack(spacing: 2) {
                    Text("\(pending.bpm)")
                        .font(.system(size: 64, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("breaths per minute")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                stepButton("plus", label: "One more") { pending.bpm += 1 }
            }

            Text("\(pending.date.dayLabel) · started \(pending.date.timeLabel)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if pending.state == .asleep && pending.bpm > alertLevel {
                Label {
                    Text("Above your alert level of \(alertLevel). Consider counting again in a few minutes, and follow your vet’s advice.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .font(.subheadline)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            StatePicker(selection: $pending.state)

            TextField("Note (optional)", text: $pending.note)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Button(role: .destructive, action: onDiscard) {
                    Text("Discard").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { onSave(pending) } label: {
                    Text("Save").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)

            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.top, 28)
        .presentationDetents([.large])
        .interactiveDismissDisabled() // don't lose a count to an accidental swipe
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 52, height: 52)
                .background(Color(.secondarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
