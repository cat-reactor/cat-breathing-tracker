import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportPreview: Identifiable {
    let id = UUID()
    let found: Int
    let asleep: Int
    let awake: Int
    let duplicates: Int
    let bad: [String]
    let fresh: [ParsedReading]
    let range: (from: Date, to: Date)?

    var summary: String {
        var parts: [String] = []
        if found == 0 {
            parts.append("No readings found. Each line needs a date, a time, a state (awake or asleep) and the number of breaths.")
        } else {
            var s = "Found \(found) reading\(found == 1 ? "" : "s"): \(asleep) asleep, \(awake) awake"
            if let range { s += ", from \(range.from.dayLabel) to \(range.to.dayLabel)" }
            parts.append(s + ".")
            if duplicates > 0 { parts.append("\(duplicates) \(duplicates == 1 ? "is" : "are") already in your log and will be skipped.") }
        }
        if !bad.isEmpty {
            let sample = bad.prefix(3).map { "• \($0)" }.joined(separator: "\n")
            parts.append("\(bad.count) line\(bad.count == 1 ? "" : "s") couldn’t be read:\n\(sample)\(bad.count > 3 ? "\n…" : "")")
        }
        if found > 0 && fresh.isEmpty { parts.append("Nothing new to add.") }
        return parts.joined(separator: "\n\n")
    }

    static func make(text: String, existing: [Reading]) -> ImportPreview {
        let (found, bad) = ImportParser.parse(text)
        var keys = Set(existing.map(\.duplicateKey))
        var fresh: [ParsedReading] = []
        for r in found where keys.insert(r.duplicateKey).inserted { fresh.append(r) }
        let dates = found.map(\.date)
        return ImportPreview(
            found: found.count,
            asleep: found.filter { $0.state == .asleep }.count,
            awake: found.filter { $0.state == .awake }.count,
            duplicates: found.count - fresh.count,
            bad: bad,
            fresh: fresh,
            range: dates.min().flatMap { lo in dates.max().map { (from: lo, to: $0) } }
        )
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Reading.date) private var readings: [Reading]
    @AppStorage(Prefs.catName) private var catName = ""
    @AppStorage(Prefs.alertLevel) private var alertLevel = Prefs.defaultAlertLevel

    @State private var showFileImporter = false
    @State private var showPaste = false
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
                    TextField("Name", text: $catName)
                    Stepper(value: $alertLevel, in: 10...80) {
                        LabeledContent("Alert level", value: "\(alertLevel)/min")
                    }
                } header: {
                    Text("Your cat")
                } footer: {
                    Text("Asleep readings above the alert level are flagged. Use the number your vet gave you; many vets use 30.")
                }

                if AppConfig.iCloudSyncEnabled {
                    Section {
                        let signedIn = FileManager.default.ubiquityIdentityToken != nil
                        LabeledContent("iCloud sync", value: signedIn ? "On" : "Off")
                    } footer: {
                        Text(FileManager.default.ubiquityIdentityToken != nil
                             ? "Readings are kept in your own iCloud and appear on your other devices. If you reinstall the app, they come back."
                             : "Sign in to iCloud in the Settings app to keep a copy of your readings in your iCloud.")
                    }
                }

                Section {
                    ShareLink(
                        item: CSVFile(name: CSVExport.fileName(catName: catName), text: CSVExport.csv(for: readings)),
                        preview: SharePreview("Breathing readings (CSV)")
                    ) {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    .disabled(readings.isEmpty)
                    Button { showFileImporter = true } label: {
                        Label("Import from a file…", systemImage: "doc.badge.plus")
                    }
                    Button { showPaste = true } label: {
                        Label("Paste old notes…", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("Backup & import")
                } footer: {
                    Text("Export a CSV to keep in Files or iCloud Drive, or to email to your vet. It opens in Numbers or Excel. Importing skips readings you already have.")
                }

                Section {
                    Button("Delete all readings", role: .destructive) { confirmWipe = true }
                        .disabled(readings.isEmpty)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Your readings stay on this iPhone\(AppConfig.iCloudSyncEnabled ? " and in your own iCloud" : ""). Nothing is sent to us or anyone else: no accounts, ads or analytics.")
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
            .sheet(isPresented: $showPaste) {
                PasteImportView(existing: readings) { fresh in add(fresh) }
            }
            .alert(
                preview?.fresh.isEmpty == false ? "Import readings?" : "Import",
                isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } }),
                presenting: preview
            ) { p in
                if !p.fresh.isEmpty {
                    Button("Add \(p.fresh.count)") { add(p.fresh) }
                    Button("Cancel", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { p in
                Text(p.summary)
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
        preview = ImportPreview.make(text: text, existing: readings)
    }

    private func add(_ fresh: [ParsedReading]) {
        for r in fresh { context.insert(Reading(date: r.date, state: r.state, bpm: r.bpm, note: r.note)) }
        try? context.save()
    }

    private func wipe() {
        for r in readings { context.delete(r) }
        try? context.save()
    }
}

/// Paste notes like "Tuesday 22nd Sept 14:50 (asleep) 18", check them, then add.
struct PasteImportView: View {
    @Environment(\.dismiss) private var dismiss
    let existing: [Reading]
    let onAdd: ([ParsedReading]) -> Void

    @State private var text = ""
    @State private var preview: ImportPreview?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: text) { preview = nil }
                } footer: {
                    Text("One reading per line, e.g. “Tuesday 22nd Sept 14:50 (asleep) 18”. A CSV exported from Breaths works too.")
                }
                if let preview {
                    Section("Check") {
                        Text(preview.summary).font(.subheadline)
                        if !preview.fresh.isEmpty {
                            Button("Add \(preview.fresh.count) reading\(preview.fresh.count == 1 ? "" : "s")") {
                                onAdd(preview.fresh)
                                dismiss()
                            }
                            .bold()
                        }
                    }
                }
            }
            .navigationTitle("Paste old notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Check") { preview = ImportPreview.make(text: text, existing: existing) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
