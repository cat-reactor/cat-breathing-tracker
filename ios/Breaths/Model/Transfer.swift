import Foundation
import CoreTransferable
import UniformTypeIdentifiers

struct ParsedReading {
    var date: Date
    var state: BreathState
    var bpm: Int
    var note: String

    var duplicateKey: String { Reading.duplicateKey(date: date, state: state, bpm: bpm) }
}

// MARK: - Export

enum CSVExport {
    static let header = "date,time,state,breaths_per_min,note"

    static func csv(for readings: [Reading]) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        var lines = [header]
        for r in readings.sorted(by: { $0.date < $1.date }) {
            lines.append([day.string(from: r.date), time.string(from: r.date), r.state.rawValue, String(r.bpm), r.note]
                .map(cell).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func cell(_ s: String) -> String {
        s.contains(where: { ",\"\r\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func fileName(catName: String, date: Date = Date()) -> String {
        let cat = catName.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined()
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return "\(cat.isEmpty ? "" : cat + " ")breathing backup \(day.string(from: date)).csv"
    }
}

/// A CSV file handed to the share sheet ("Save to Files", Mail, AirDrop…).
struct CSVFile: Transferable {
    let name: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

// MARK: - Import

/// Reads either a CSV (as exported by this app or the web version) or free-text notes,
/// one reading per line, e.g. "Monday 21st Sept 23:00 (awake)  32".
enum ImportParser {
    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> (found: [ParsedReading], bad: [String]) {
        let text = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        let lines = text.components(separatedBy: .newlines)
        let first = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        if first.range(of: #"^\s*"?date"?\s*[,;\t]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return parseCSV(text, headerLine: first, calendar: calendar)
        }
        var found: [ParsedReading] = []
        var bad: [String] = []
        for line in lines {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if let r = parseFreeLine(l, now: now, calendar: calendar) {
                found.append(r)
            } else if l.rangeOfCharacter(from: .decimalDigits) != nil {
                bad.append(l) // lines without digits are just headings
            }
        }
        return (found, bad)
    }

    /// "half-asleep" (from older logs) counts as awake.
    static func stateFrom(_ s: String) -> BreathState? {
        let s = s.lowercased()
        if ["half", "drows", "doz", "relax"].contains(where: { s.contains($0) }) { return .awake }
        if s.contains("sleep") { return .asleep }
        if s.contains("wake") { return .awake }
        return nil
    }

    // MARK: Free text

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    private static let freeRegex = try! NSRegularExpression(
        pattern: #"(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]{3,9})\.?,?(?:\s+(\d{4}))?[\s,]+(\d{1,2})[:.](\d{2})\s*(am|pm)?\s*(?:\(([^)]*)\)|\b(asleep|sleeping|half[\s-]?asleep|drowsy|awake)\b)?\s*[-–—:=,]?\s*(\d{1,3})\D*$"#,
        options: [.caseInsensitive]
    )

    static func parseFreeLine(_ line: String, now: Date, calendar: Calendar) -> ParsedReading? {
        guard let g = match(freeRegex, in: line),
              let monthWord = g[2], let month = months[String(monthWord.prefix(3)).lowercased()],
              let day = g[1].flatMap(Int.init), let hour = g[4].flatMap(Int.init), let minute = g[5].flatMap(Int.init),
              let state = stateFrom(g[7] ?? g[8] ?? ""),
              let bpm = g[9].flatMap(Int.init), (1..<300).contains(bpm)
        else { return nil }
        let hh = to24h(hour, g[6])
        let year = g[3].flatMap(Int.init) ?? guessYear(month: month, day: day, hour: hh, minute: minute, now: now, calendar: calendar)
        guard let date = makeDate(year, month, day, hh, minute, calendar: calendar) else { return nil }
        return ParsedReading(date: date, state: state, bpm: bpm, note: "")
    }

    // MARK: CSV

    private static func parseCSV(_ text: String, headerLine: String, calendar: Calendar) -> (found: [ParsedReading], bad: [String]) {
        let delim: Character = [",", ";", "\t"].max { a, b in
            headerLine.filter { $0 == a }.count < headerLine.filter { $0 == b }.count
        } ?? ","
        var rows = csvRows(text, delimiter: delim).filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !rows.isEmpty else { return ([], []) }
        let head = rows.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ test: (String) -> Bool) -> Int? { head.firstIndex(where: test) }
        let iDate = col { $0.hasPrefix("date") || $0.contains("day") }
        let iTime = col { $0.contains("time") }
        let iState = col { $0.contains("state") || $0.contains("status") }
        let iBpm = col { let h = $0; return ["bpm", "breath", "rate", "per min", "count"].contains(where: { h.contains($0) }) }
        let iNote = col { $0.contains("note") || $0.contains("comment") }

        var found: [ParsedReading] = []
        var bad: [String] = []
        for cells in rows {
            func get(_ i: Int?) -> String {
                guard let i, i < cells.count else { return "" }
                return cells[i].trimmingCharacters(in: .whitespaces)
            }
            if let r = csvReading(date: get(iDate), time: get(iTime), state: get(iState), bpm: get(iBpm), note: get(iNote), calendar: calendar) {
                found.append(r)
            } else {
                bad.append(cells.joined(separator: delim == "\t" ? "  " : "\(delim) "))
            }
        }
        return (found, bad)
    }

    private static let isoDate = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{1,2})-(\d{1,2})"#)
    private static let ukDate = try! NSRegularExpression(pattern: #"^(\d{1,2})[/.](\d{1,2})[/.](\d{2,4})"#)
    private static let clock = try! NSRegularExpression(pattern: #"(\d{1,2})[:.](\d{2})(?::\d{2})?\s*(am|pm)?"#, options: [.caseInsensitive])

    private static func csvReading(date ds: String, time ts: String, state st: String, bpm bs: String, note: String, calendar: Calendar) -> ParsedReading? {
        var y = 0, m = 0, d = 0
        if let g = match(isoDate, in: ds) {
            y = Int(g[1]!)!; m = Int(g[2]!)!; d = Int(g[3]!)!
        } else if let g = match(ukDate, in: ds) {
            d = Int(g[1]!)!; m = Int(g[2]!)!; y = Int(g[3]!)!
            if y < 100 { y += 2000 }
        } else {
            return nil
        }
        // The time may be in its own column or after the date ("2026-10-05 14:18").
        guard let t = match(clock, in: ts.isEmpty ? String(ds.dropFirst(8)) : ts),
              let hour = Int(t[1]!), let minute = Int(t[2]!),
              let state = stateFrom(st),
              let bpm = Int(bs), (1..<300).contains(bpm),
              let date = makeDate(y, m, d, to24h(hour, t[3]), minute, calendar: calendar)
        else { return nil }
        return ParsedReading(date: date, state: state, bpm: bpm, note: note)
    }

    /// Splits CSV text into rows of cells, honouring quotes (including newlines inside quotes).
    static func csvRows(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var chars = text.makeIterator()
        var pending: Character?
        while let c = pending ?? chars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { cell.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    cell.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == delimiter {
                row.append(cell); cell = ""
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(cell); rows.append(row); row = []; cell = ""
            } else {
                cell.append(c)
            }
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows
    }

    // MARK: Helpers

    private static func match(_ re: NSRegularExpression, in s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) }
        }
    }

    private static func to24h(_ hour: Int, _ ampm: String?) -> Int {
        guard let ampm = ampm?.lowercased() else { return hour }
        if hour == 12 { return ampm == "pm" ? 12 : 0 }
        return ampm == "pm" ? hour + 12 : hour
    }

    /// Notes often leave out the year: use this year, unless that would be in the future.
    private static func guessYear(month: Int, day: Int, hour: Int, minute: Int, now: Date, calendar: Calendar) -> Int {
        let y = calendar.component(.year, from: now)
        if let d = makeDate(y, month, day, hour, minute, calendar: calendar), d > now.addingTimeInterval(86_400) { return y - 1 }
        return y
    }

    static func makeDate(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int, calendar: Calendar) -> Date? {
        guard (1...12).contains(m), (1...31).contains(d), (0...23).contains(hh), (0...59).contains(mm) else { return nil }
        let comps = DateComponents(year: y, month: m, day: d, hour: hh, minute: mm)
        guard let date = calendar.date(from: comps),
              calendar.component(.month, from: date) == m, calendar.component(.day, from: date) == d
        else { return nil } // e.g. 31 September
        return date
    }
}
