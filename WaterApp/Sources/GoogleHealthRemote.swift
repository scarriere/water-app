import Foundation

/// Read-only view of hydration logs returned by Google. A matching timestamp and
/// volume is a candidate, not proof of provenance; only a saved Google ID confirms it.
struct GoogleHealthRemoteDrink: Identifiable, Equatable {
    enum Confidence: Equatable { case confirmed, possible }
    let id: String
    let at: Date
    let ml: Int
    let confidence: Confidence
}

enum GoogleHealthRemote {
    struct Record {
        let name: String
        let at: Date
        let ml: Int
    }

    enum ParseError: LocalizedError {
        case invalidPage
        var errorDescription: String? { "Google returned an unsupported hydration list response." }
    }

    static func page(_ json: [String: Any]) throws -> (records: [Record], nextPageToken: String?) {
        guard let raw = json["dataPoints"] as? [[String: Any]] ??
                json["dataPoint"] as? [[String: Any]] ??
                (json.isEmpty ? [] : nil) else { throw ParseError.invalidPage }
        let records = raw.compactMap { point -> Record? in
            guard let name = point["name"] as? String,
                  name.contains("/dataTypes/hydration-log/dataPoints/"),
                  let hydration = point["hydrationLog"] as? [String: Any],
                  let interval = hydration["interval"] as? [String: Any],
                  let time = interval["startTime"] as? String,
                  let at = date(from: time),
                  let volume = hydration["amountConsumed"] as? [String: Any],
                  let ml = (volume["milliliters"] as? Int) ??
                           (volume["milliliters"] as? String).flatMap(Int.init),
                  ml > 0 else { return nil }
            return Record(name: name, at: at, ml: ml)
        }
        // Do not silently hide records if Google's response shape changes.
        guard raw.count == records.count else { throw ParseError.invalidPage }
        return (records, json["nextPageToken"] as? String)
    }

    static func matchingWaterDrinks(_ records: [Record], entries: [GoogleHealthSync.Entry]) -> [GoogleHealthRemoteDrink] {
        let named = Set(entries.compactMap(\.remoteName).compactMap(dataPointID))
        let unresolved = entries.filter { $0.uncertain && $0.remoteName == nil }
        return records.compactMap { record in
            if let id = dataPointID(record.name), named.contains(id) {
                return GoogleHealthRemoteDrink(id: record.name, at: record.at, ml: record.ml,
                                                confidence: .confirmed)
            }
            let candidates = unresolved.filter { entry in
                guard let time = date(from: entry.at) else { return false }
                return entry.ml == record.ml && abs(time.timeIntervalSince(record.at)) < 1
            }
            guard candidates.count == 1 else { return nil }
            return GoogleHealthRemoteDrink(id: record.name, at: record.at, ml: record.ml,
                                            confidence: .possible)
        }.sorted { $0.at > $1.at }
    }

    private static func dataPointID(_ name: String) -> String? {
        guard name.contains("/dataTypes/hydration-log/dataPoints/"),
              let id = name.split(separator: "/").last, !id.isEmpty else { return nil }
        return String(id)
    }

    private static func date(from value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }
}
