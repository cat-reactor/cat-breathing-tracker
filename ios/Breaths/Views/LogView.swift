import SwiftUI
import SwiftData

struct LogView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Reading.date, order: .reverse) private var readings: [Reading]
    @AppStorage(Prefs.logFilter) private var filter = "all"
    @AppStorage(Prefs.alertLevel) private var alertLevel = Prefs.defaultAlertLevel

    @State private var editing: Reading?
    @State private var adding = false
    @State private var confirmDelete: Reading?

    private struct DaySection: Identifiable {
        let day: Date
        var items: [Reading]
        var id: Date { day }
    }

    private var sections: [DaySection] {
        let cal = Calendar.current
        var result: [DaySection] = []
        for r in readings where filter == "all" || r.stateRaw == filter {
            let day = cal.startOfDay(for: r.date)
            if result.last?.day == day {
                result[result.count - 1].items.append(r)
            } else {
                result.append(DaySection(day: day, items: [r]))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $filter) {
                    Text("All").tag("all")
                    ForEach(BreathState.allCases) { s in Text(s.label).tag(s.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                ForEach(sections) { section in
                    Section(section.day.dayLabel + yearSuffix(section.day)) {
                        ForEach(section.items) { r in
                            Button { editing = r } label: { ReadingRow(reading: r, alertLevel: alertLevel) }
                                .swipeActions {
                                    Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = r }
                                }
                        }
                    }
                }
            }
            .overlay {
                if sections.isEmpty {
                    ContentUnavailableView(
                        readings.isEmpty ? "No readings yet" : "No matching readings",
                        systemImage: "list.bullet",
                        description: Text(readings.isEmpty
                            ? "Count breaths on the Count tab, tap + to add a past reading, or import your old log in Settings."
                            : "Try another filter.")
                    )
                }
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add a past reading", systemImage: "plus") { adding = true }
                }
            }
            .sheet(item: $editing) { r in EntrySheet(reading: r) }
            .sheet(isPresented: $adding) { EntrySheet(reading: nil) }
            .confirmationDialog("Delete this reading?", isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let r = confirmDelete { context.delete(r); try? context.save() }
                    confirmDelete = nil
                }
            } message: {
                if let r = confirmDelete {
                    Text("\(r.bpm)/min, \(r.state.label.lowercased()), \(r.date.dayLabel) \(r.date.timeLabel)")
                }
            }
        }
    }

    private func yearSuffix(_ day: Date) -> String {
        let cal = Calendar.current
        let y = cal.component(.year, from: day)
        return y == cal.component(.year, from: Date()) ? "" : " \(y)"
    }
}

struct ReadingRow: View {
    let reading: Reading
    let alertLevel: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(reading.date.timeLabel)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .leading)
            StateDot(state: reading.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(reading.state.label)
                if !reading.note.isEmpty {
                    Text(reading.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if reading.isOverAlert(alertLevel) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Above alert level")
            }
            Text("\(reading.bpm)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }
}

/// Add a past reading, or edit / delete an existing one.
struct EntrySheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.countState) private var lastState: BreathState = .asleep

    let reading: Reading?
    @State private var date = Date()
    @State private var state: BreathState = .asleep
    @State private var bpmText = ""
    @State private var note = ""
    @State private var loaded = false
    @State private var confirmDelete = false

    private var bpm: Int? {
        guard let v = Int(bpmText.trimmingCharacters(in: .whitespaces)), (1...250).contains(v) else { return nil }
        return v
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date & time", selection: $date, in: ...Date().addingTimeInterval(300))
                Section("State") {
                    StatePicker(selection: $state)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section("Breaths per minute") {
                    TextField("e.g. 24", text: $bpmText)
                        .keyboardType(.numberPad)
                        .font(.title3)
                }
                Section("Note (optional)") {
                    TextField("e.g. after eating", text: $note)
                }
                if reading != nil {
                    Section {
                        Button("Delete reading", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(reading == nil ? "Add reading" : "Edit reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(bpm == nil)
                }
            }
            .confirmationDialog("Delete this reading?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let reading { context.delete(reading); try? context.save() }
                    dismiss()
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let reading {
            date = reading.date
            state = reading.state
            bpmText = String(reading.bpm)
            note = reading.note
        } else {
            state = lastState
        }
    }

    private func save() {
        guard let bpm else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reading {
            reading.date = date
            reading.state = state
            reading.bpm = bpm
            reading.note = trimmed
        } else {
            context.insert(Reading(date: date, state: state, bpm: bpm, note: trimmed))
        }
        try? context.save()
        dismiss()
    }
}
