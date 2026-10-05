import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// What a CSV would add, shown for checking before anything is saved.
struct ImportPreview: Identifiable {
    let id = UUID()
    let fileName: String
    let result: CSVImport.Result
    let existingKeys: Set<String>

    var missingState: Int { result.found.filter { $0.state == nil }.count }

    /// Readings not already in the log, with `fallback` used where the file doesn't say asleep or awake.
    func fresh(assuming fallback: BreathState) -> [ParsedReading] {
        var keys = existingKeys
        var out: [ParsedReading] = []
        for var r in result.found {
            if r.state == nil { r.state = fallback }
            if keys.insert(Reading.duplicateKey(date: r.date, state: r.state ?? fallback, bpm: r.bpm)).inserted {
                out.append(r)
            }
        }
        return out.sorted { $0.date < $1.date }
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Reading.date) private var readings: [Reading]
    @AppStorage(Prefs.petName) private var petName = ""
    @AppStorage(Prefs.alertLevel) private var alertLevel = Prefs.defaultAlertLevel
    @AppStorage(Prefs.appearance) private var appearance: Appearance = .system

    @State private var showFileImporter = false
    @State private var showAdd = false
    @State private var preview: ImportPreview?
    @State private var confirmWipe = false
    @State private var notice: String?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Pet’s name", text: $petName)
                    Stepper(value: $alertLevel, in: 10...80) {
                        LabeledContent("Alert level", value: "\(alertLevel)/min")
                    }
                } header: {
                    Text("Your pet")
                } footer: {
                    Text("Asleep readings above the alert level are flagged. Use the number your vet gave you; many vets use 30.")
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if AppConfig.iCloudSyncEnabled {
                    Section {
                        LabeledContent("iCloud sync", value: FileManager.default.ubiquityIdentityToken != nil ? "On" : "Off")
                    } footer: {
                        Text(FileManager.default.ubiquityIdentityToken != nil
                             ? "Readings are kept in your own iCloud and appear on your other devices. If you reinstall the app, they come back."
                             : "Sign in to iCloud in the Settings app to keep a copy of your readings in your iCloud.")
                    }
                }

                Section {
                    ShareLink(
                        item: CSVFile(name: CSVExport.fileName(petName: petName), text: CSVExport.csv(for: readings)),
                        preview: SharePreview("Breathing readings (CSV)")
                    ) {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    .disabled(readings.isEmpty)
                    Button { showAdd = true } label: {
                        Label("Add past readings…", systemImage: "calendar.badge.plus")
                    }
                    Button { showFileImporter = true } label: {
                        Label("Import a CSV file…", systemImage: "doc.badge.plus")
                    }
                } header: {
                    Text("Backup & import")
                } footer: {
                    Text("Export a CSV to keep in Files or iCloud Drive, or to email to your vet. You can import it again later; readings you already have are skipped.")
                }

                Section {
                    Button("Delete all readings", role: .destructive) { confirmWipe = true }
                        .disabled(readings.isEmpty)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(AppConfig.iCloudSyncEnabled
                         ? "Your data stay solely on this iPhone and in your own iCloud."
                         : "Your data stay solely on this iPhone.")
                }

                Section {
                    LabeledContent("Readings", value: "\(readings.count)")
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
                importFile(result)
            }
            .sheet(isPresented: $showAdd) { EntrySheet(reading: nil) }
            .sheet(item: $preview) { p in
                ImportSheet(preview: p) { fresh in add(fresh) }
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete all \(readings.count) readings?",
                isPresented: $confirmWipe,
                titleVisibility: .visible
            ) {
                Button("Delete all readings", role: .destructive) { wipe() }
            } message: {
                Text("This can’t be undone. Export a CSV first if you might want them.")
            }
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else {
            notice = "Couldn’t read that file."
            return
        }
        let parsed = CSVImport.parse(text)
        if let problem = parsed.problem {
            notice = problem
            return
        }
        preview = ImportPreview(fileName: url.lastPathComponent, result: parsed, existingKeys: Set(readings.map(\.duplicateKey)))
    }

    private func add(_ fresh: [ParsedReading]) {
        for r in fresh {
            context.insert(Reading(date: r.date, state: r.state ?? .awake, bpm: r.bpm, note: r.note))
        }
        try? context.save()
    }

    private func wipe() {
        for r in readings { context.delete(r) }
        try? context.save()
    }
}

/// Shows what a CSV contains so dates and states can be checked before importing.
struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preview: ImportPreview
    let onAdd: ([ParsedReading]) -> Void

    @State private var fallback: BreathState = .asleep

    var body: some View {
        let result = preview.result
        let fresh = preview.fresh(assuming: fallback)
        let duplicates = result.found.count - fresh.count

        NavigationStack {
            List {
                Section {
                    Text(summary(fresh: fresh, duplicates: duplicates))
                } footer: {
                    Text(preview.fileName)
                }

                if preview.missingState > 0 {
                    Section {
                        StatePicker(selection: $fallback)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    } header: {
                        Text("Asleep or awake?")
                    } footer: {
                        Text("\(preview.missingState) reading\(preview.missingState == 1 ? " doesn’t" : "s don’t") say whether your pet was asleep or awake. Choose which to record \(preview.missingState == 1 ? "it" : "them") as.")
                    }
                }

                if !fresh.isEmpty {
                    Section {
                        ForEach(Array(sample(fresh).enumerated()), id: \.offset) { _, item in
                            if let r = item {
                                ImportRow(reading: r)
                            } else {
                                Text("⋯").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                            }
                        }
                    } header: {
                        Text("Check these look right")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if let order = result.assumedDateOrder {
                                Text("Dates like 03/10 were read as \(order), following your iPhone’s region. If they look wrong, cancel and change the dates in the file to the 2026-10-03 style.")
                            }
                            if result.missingTime > 0 {
                                Text("\(result.missingTime) reading\(result.missingTime == 1 ? " has" : "s have") no time, so \(result.missingTime == 1 ? "it was" : "they were") set to 12:00.")
                            }
                        }
                    }
                }

                if !result.bad.isEmpty {
                    Section {
                        ForEach(Array(result.bad.prefix(5).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).lineLimit(2)
                        }
                        if result.bad.count > 5 {
                            Text("…and \(result.bad.count - 5) more").font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("\(result.bad.count) row\(result.bad.count == 1 ? "" : "s") couldn’t be read")
                    } footer: {
                        Text("These will be skipped. Each row needs a date and a number of breaths.")
                    }
                }
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(fresh.count)") {
                        onAdd(fresh)
                        dismiss()
                    }
                    .disabled(fresh.isEmpty)
                }
            }
        }
    }

    private func summary(fresh: [ParsedReading], duplicates: Int) -> String {
        if preview.result.found.isEmpty { return "No readings could be read from this file." }
        var s: String
        if let first = fresh.first, let last = fresh.last {
            let from = first.date.formatted(date: .abbreviated, time: .omitted)
            let to = last.date.formatted(date: .abbreviated, time: .omitted)
            s = "\(fresh.count) new reading\(fresh.count == 1 ? "" : "s") to add, \(from == to ? "on \(from)" : "from \(from) to \(to)")."
        } else {
            s = "Nothing new to add."
        }
        if duplicates > 0 {
            s += " \(duplicates) \(duplicates == 1 ? "is" : "are") already in your log and will be skipped."
        }
        return s
    }

    /// Up to six readings: all of them, or the first three and the last two.
    private func sample(_ rs: [ParsedReading]) -> [ParsedReading?] {
        let all = rs.map { Optional($0) }
        return all.count <= 6 ? all : Array(all.prefix(3)) + [nil] + Array(all.suffix(2))
    }
}

private struct ImportRow: View {
    let reading: ParsedReading

    var body: some View {
        let state = reading.state ?? .awake
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(reading.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
                Text(reading.date.timeLabel).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            StateDot(state: state)
            Text(state.label).foregroundStyle(.secondary)
            Text("\(reading.bpm)").font(.headline).monospacedDigit().frame(minWidth: 28, alignment: .trailing)
        }
    }
}
