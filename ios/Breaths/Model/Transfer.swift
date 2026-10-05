import Foundation
import CoreTransferable
import UniformTypeIdentifiers

struct ParsedReading {
    var date: Date
    var state: BreathState? // nil when the file doesn't say asleep or awake
    var bpm: Int
    var note: String
}

// MARK: - Export

enum CSVExport {
    static let header = "date,time,state,breaths_per_min,note"

    static func csv(for readings: [Reading]) -> String {
        let day = posixFormatter("yyyy-MM-dd")
        let time = posixFormatter("HH:mm")
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

    static func fileName(petName: String, date: Date = Date()) -> String {
        let pet = petName.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined()
        return "\(pet.isEmpty ? "" : pet + " ")breathing backup \(posixFormatter("yyyy-MM-dd").string(from: date)).csv"
    }

    private static func posixFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
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

/// Reads a CSV with a header row. Columns are found by name, in any order:
/// a date (or date-and-time) column and a breaths-per-minute column are required;
/// time, state (asleep/awake) and note columns are optional.
enum CSVImport {
    struct Result {
        var found: [ParsedReading] = []
        var bad: [String] = []
        /// Set when the whole file can't be read.
        var problem: String?
        /// Rows with no time of day; they were placed at 12:00.
        var missingTime = 0
        /// Set when dates like 03/10/2026 could be either order and the phone's region decided.
        var assumedDateOrder: String?
    }

    static let expectedColumns = "a header row naming the columns, such as date, time, state, breaths_per_min"

    static func parse(_ raw: String, calendar: Calendar = .current, locale: Locale = .current) -> Result {
        let text = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        guard let headerLine = text.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return Result(problem: "The file is empty.") }

        let delimiter: Character = [",", ";", "\t"].max { a, b in
            headerLine.filter { $0 == a }.count < headerLine.filter { $0 == b }.count
        } ?? ","
        var rows = csvRows(text, delimiter: delimiter)
            .filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        let head = rows.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        func column(_ test: (String) -> Bool, excluding: [Int?] = []) -> Int? {
            head.indices.first { i in !excluding.contains(i) && test(head[i]) }
        }
        let iBpm = column { h in ["bpm", "breath", "rate", "rpm", "resp", "per min", "/min", "count"].contains { h.contains($0) } }
        let iDate = column({ h in h.contains("date") || h.contains("timestamp") || h == "day" || h == "when" }, excluding: [iBpm])
        let iTime = column({ h in h.contains("time") && !h.contains("timestamp") }, excluding: [iBpm, iDate])
        let iState = column({ h in ["state", "status", "sleep", "awake", "condition", "activity"].contains { h.contains($0) } },
                            excluding: [iBpm, iDate, iTime])
        let iNote = column({ h in ["note", "comment", "remark"].contains { h.contains($0) } }, excluding: [iBpm, iDate, iTime, iState])

        guard let iDate, let iBpm else {
            return Result(problem: "Couldn’t find a date column and a breaths-per-minute column. The file needs \(expectedColumns).")
        }

        func get(_ cells: [String], _ i: Int?) -> String {
            guard let i, i < cells.count else { return "" }
            return cells[i].trimmingCharacters(in: .whitespaces)
        }

        var result = Result()
        let order = dayMonthOrder(rows.map { get($0, iDate) }, locale: locale)
        if order.assumed { result.assumedDateOrder = order.dayFirst ? "day/month" : "month/day" }

        for cells in rows {
            guard let parsed = parseDate(get(cells, iDate), dayFirst: order.dayFirst),
                  let bpm = parseBpm(get(cells, iBpm))
            else {
                result.bad.append(cells.joined(separator: delimiter == "\t" ? "  " : "\(delimiter) "))
                continue
            }
            let (y, m, d, rest) = parsed
            var hour = 12, minute = 0
            let timeCell = iTime.map { get(cells, $0) } ?? ""
            if let t = match(clock, in: timeCell.isEmpty ? rest : timeCell), let h = Int(t[1]!), let mm = Int(t[2]!) {
                hour = to24h(h, t[3])
                minute = mm
            } else {
                result.missingTime += 1
            }
            guard let date = makeDate(y, m, d, hour, minute, calendar: calendar) else {
                result.bad.append(cells.joined(separator: "\(delimiter) "))
                continue
            }
            let state = iState.flatMap { stateFrom(get(cells, $0)) }
            result.found.append(ParsedReading(date: date, state: state, bpm: bpm, note: get(cells, iNote)))
        }
        return result
    }

    /// Recognises asleep/awake wording. "Half-asleep", "resting" and "relaxed" count as awake.
    static func stateFrom(_ s: String) -> BreathState? {
        let s = s.lowercased()
        if ["half", "drows", "doz", "relax", "rest", "calm"].contains(where: { s.contains($0) }) { return .awake }
        if s.contains("sleep") { return .asleep }
        if s.contains("wake") || s.contains("active") { return .awake }
        return nil
    }

    // MARK: Dates

    private static let isoDate = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{1,2})-(\d{1,2})"#)
    private static let numericDate = try! NSRegularExpression(pattern: #"^(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})"#)
    // "5 Oct 2026", "Mon 5th October 2026"
    private static let dayMonthName = try! NSRegularExpression(
        pattern: #"^(?:[a-z]+,?\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]{3,})\.?,?\s+(\d{4})"#, options: [.caseInsensitive])
    // "Oct 5, 2026", "Monday, October 5th 2026"
    private static let monthNameDay = try! NSRegularExpression(
        pattern: #"^(?:[a-z]+,?\s+)?([a-z]{3,})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})"#, options: [.caseInsensitive])
    private static let clock = try! NSRegularExpression(pattern: #"(\d{1,2})[:.](\d{2})(?::\d{2})?\s*(am|pm)?"#, options: [.caseInsensitive])

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    /// Decides whether 03/10/2026 means 3 October or March 10: from the data when any day is
    /// above 12, otherwise from the phone's region.
    static func dayMonthOrder(_ cells: [String], locale: Locale) -> (dayFirst: Bool, assumed: Bool) {
        var sawNumeric = false
        for c in cells {
            guard let g = match(numericDate, in: c), let a = Int(g[1]!), let b = Int(g[2]!) else { continue }
            sawNumeric = true
            if a > 12 { return (true, false) }
            if b > 12 { return (false, false) }
        }
        let format = DateFormatter.dateFormat(fromTemplate: "dMy", options: 0, locale: locale) ?? "d/M/y"
        let dayFirst = (format.firstIndex(of: "d") ?? format.startIndex) < (format.firstIndex(of: "M") ?? format.endIndex)
        return (dayFirst, sawNumeric)
    }

    /// Returns year, month, day and whatever follows the date in the cell (which may hold the time).
    private static func parseDate(_ s: String, dayFirst: Bool) -> (Int, Int, Int, String)? {
        func rest(_ g: [String?]) -> String { String(s.dropFirst(g[0]!.count)) }
        if let g = match(isoDate, in: s) {
            return (Int(g[1]!)!, Int(g[2]!)!, Int(g[3]!)!, rest(g))
        }
        if let g = match(numericDate, in: s) {
            let a = Int(g[1]!)!, b = Int(g[2]!)!
            var y = Int(g[3]!)!
            if y < 100 { y += 2000 }
            return dayFirst ? (y, b, a, rest(g)) : (y, a, b, rest(g))
        }
        if let g = match(dayMonthName, in: s), let m = months[String(g[2]!.prefix(3)).lowercased()] {
            return (Int(g[3]!)!, m, Int(g[1]!)!, rest(g))
        }
        if let g = match(monthNameDay, in: s), let m = months[String(g[1]!.prefix(3)).lowercased()] {
            return (Int(g[3]!)!, m, Int(g[2]!)!, rest(g))
        }
        return nil
    }

    private static func parseBpm(_ s: String) -> Int? {
        guard let r = s.range(of: #"\d+(?:[.,]\d+)?"#, options: .regularExpression),
              let v = Double(s[r].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        let bpm = Int(v.rounded())
        return (1..<300).contains(bpm) ? bpm : nil
    }

    private static func to24h(_ hour: Int, _ ampm: String?) -> Int {
        guard let ampm = ampm?.lowercased() else { return hour }
        if hour == 12 { return ampm == "pm" ? 12 : 0 }
        return ampm == "pm" ? hour + 12 : hour
    }

    static func makeDate(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int, calendar: Calendar) -> Date? {
        guard (1...12).contains(m), (1...31).contains(d), (0...23).contains(hh), (0...59).contains(mm) else { return nil }
        guard let date = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm)),
              calendar.component(.month, from: date) == m, calendar.component(.day, from: date) == d
        else { return nil } // e.g. 31 September
        return date
    }

    // MARK: CSV text

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

    private static func match(_ re: NSRegularExpression, in s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) }
        }
    }
}
