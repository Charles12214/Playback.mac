import Foundation

enum MusicSource: String { case appleMusic = "Apple Music", spotify = "Spotify" }

struct TrackInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval   // seconds
    var source: MusicSource
}

struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}

enum LRCParser {
    /// Parses `[mm:ss.xx] text` lines (multiple timestamps per line supported).
    static func parse(_ lrc: String) -> [LyricLine] {
        let regex = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        var out: [LyricLine] = []
        // Standard LRC "[offset:+/-ms]" tag: positive = lyrics appear earlier.
        var shift = 0.0
        if let r = lrc.range(of: #"\[offset:\s*([+-]?\d+)\]"#, options: .regularExpression) {
            let num = lrc[r].filter { "+-0123456789".contains($0) }
            shift = (Double(num) ?? 0) / 1000
        }
        for raw in lrc.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let mins = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let secs = Double(ns.substring(with: m.range(at: 2))) ?? 0
                out.append(LyricLine(time: max(0, mins * 60 + secs - shift), text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}
