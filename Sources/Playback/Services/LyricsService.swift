import Foundation
import CryptoKit

/// User-supplied `.lrc` overrides, stored in ~/Library/Application Support/Playback/Lyrics.
enum LyricsStore {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Playback/Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func file(for t: TrackInfo) -> URL {
        let raw = "\(Normalize.key(t.artist))|\(Normalize.key(t.title))"
        let h = SHA256.hash(data: Data(raw.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(h).lrc")
    }
    static func load(for t: TrackInfo) -> String? { try? String(contentsOf: file(for: t), encoding: .utf8) }
    static func save(_ text: String, for t: TrackInfo) { try? text.write(to: file(for: t), atomically: true, encoding: .utf8) }
    static func remove(for t: TrackInfo) { try? FileManager.default.removeItem(at: file(for: t)) }
    static func exists(for t: TrackInfo) -> Bool { FileManager.default.fileExists(atPath: file(for: t).path) }
}

enum Normalize {
    /// Lowercase, drop bracketed parts ("(feat. X)", "[Remastered]") and punctuation.
    static func key(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s-\s.*(remaster|version|edit|mix|live).*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: "", options: .regularExpression)
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Lyrics resolution: user override → LRCLIB exact match → best-scored LRCLIB search result.
actor LyricsService {
    static let shared = LyricsService()
    private var cache: [String: [LyricLine]] = [:]

    func lyrics(for t: TrackInfo, useCache: Bool = true) async -> [LyricLine] {
        if let custom = LyricsStore.load(for: t) {
            let l = LRCParser.parse(custom)
            if !l.isEmpty { return l }
        }
        let key = "\(t.artist)|\(t.title)|\(Int(t.duration))"
        if useCache, let hit = cache[key] { return hit }

        var lrc = await exact(t)
        if lrc == nil { lrc = await bestSearchResult(t) }
        let lines = lrc.map(LRCParser.parse) ?? []
        if !lines.isEmpty { cache[key] = lines } else { cache[key] = nil }
        return lines
    }

    private func request(_ path: String, _ items: [URLQueryItem]) async -> Any? {
        var c = URLComponents(string: "https://lrclib.net/api/\(path)")!
        c.queryItems = items
        var req = URLRequest(url: c.url!)
        req.setValue("Playback.mac/0.3 (https://github.com/Charles12214)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Exact match; only trusted if its length is within ~1.5 s of the real track.
    private func exact(_ t: TrackInfo) async -> String? {
        guard let json = await request("get", [
            .init(name: "artist_name", value: t.artist),
            .init(name: "track_name", value: t.title),
            .init(name: "album_name", value: t.album),
            .init(name: "duration", value: String(Int(t.duration.rounded())))
        ]) as? [String: Any],
              let synced = json["syncedLyrics"] as? String, !synced.isEmpty else { return nil }
        let d = json["duration"] as? Double ?? t.duration
        return t.duration > 0 && abs(d - t.duration) > 1.5 ? nil : synced
    }

    /// Scores every search hit by length, title, artist and album agreement.
    private func bestSearchResult(_ t: TrackInfo) async -> String? {
        let cleanTitle = Normalize.key(t.title)
        var hits: [[String: Any]] = []
        for items in [
            [URLQueryItem(name: "track_name", value: cleanTitle), URLQueryItem(name: "artist_name", value: t.artist)],
            [URLQueryItem(name: "q", value: "\(t.artist) \(cleanTitle)")]
        ] {
            if let arr = await request("search", items) as? [[String: Any]] { hits += arr }
        }
        let wantTitle = cleanTitle, wantArtist = Normalize.key(t.artist), wantAlbum = Normalize.key(t.album)

        func score(_ h: [String: Any]) -> Double? {
            guard let s = h["syncedLyrics"] as? String, !s.isEmpty else { return nil }
            let diff = t.duration > 0 ? abs((h["duration"] as? Double ?? 0) - t.duration) : 0
            if diff > 3 { return nil }
            var sc = diff
            if Normalize.key(h["trackName"] as? String ?? "") != wantTitle { sc += 2 }
            let a = Normalize.key(h["artistName"] as? String ?? "")
            if !(a == wantArtist || a.contains(wantArtist) || wantArtist.contains(a)) { sc += 3 }
            if Normalize.key(h["albumName"] as? String ?? "") != wantAlbum { sc += 0.5 }
            return sc
        }
        return hits.compactMap { h in score(h).map { (h, $0) } }
            .min { $0.1 < $1.1 }?.0["syncedLyrics"] as? String
    }
}
