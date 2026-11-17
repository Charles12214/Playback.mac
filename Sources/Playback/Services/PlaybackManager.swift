import Foundation
import AppKit
import Combine

/// Listens to Apple Music + Spotify, keeps an interpolated, self-correcting
/// playback clock (handles seeks), and publishes the active lyric index.
@MainActor
final class PlaybackManager: ObservableObject {
    @Published var track: TrackInfo?
    @Published var isPlaying = false
    @Published var lyrics: [LyricLine] = []
    private var rawLyrics: [LyricLine] = []
    @Published var hasCustomLyrics = false
    /// User timing nudge in seconds (+ = lyrics appear earlier).
    @Published var lyricOffset: Double = UserDefaults.standard.double(forKey: "lyricOffset") {
        didSet { UserDefaults.standard.set(lyricOffset, forKey: "lyricOffset"); currentIndex = index(at: livePosition()) }
    }
    /// Strip "(backing vocals)" in brackets from lines.
    @Published var hideBackingVocals: Bool = UserDefaults.standard.bool(forKey: "hideBacking") {
        didSet { UserDefaults.standard.set(hideBackingVocals, forKey: "hideBacking"); rebuildLyrics() }
    }
    @Published var lyricsLoading = false
    @Published var isScrubbing = false
    @Published var scrubPosition: TimeInterval = 0
    @Published var currentIndex: Int = -1
    /// Smoothly animated album-art accent colours (sRGB 0...1).
    @Published var tintA = ArtworkService.neutral.0
    @Published var tintB = ArtworkService.neutral.1
    private var targetA = ArtworkService.neutral.0
    private var targetB = ArtworkService.neutral.1
    private var artworkTask: Task<Void, Never>?

    // Clock anchor (not published: views read it through TimelineView).
    private(set) var anchorPosition: TimeInterval = 0
    private(set) var anchorDate = Date()
    private var ticker: Timer?
    private var syncTimer: Timer?
    private var lyricsTask: Task<Void, Never>?
    private let scriptQueue = DispatchQueue(label: "playback.applescript")

    /// Lyrics appear this much early to feel "on beat" (display latency).
    private let lookahead: TimeInterval = 0.12

    init() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.handle(n.userInfo, source: .appleMusic) }
        }
        dnc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.handle(n.userInfo, source: .spotify) }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Smart sync: re-read the true position once a second to catch seeks/skips.
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.resync() }
        }
    }

    // MARK: Clock

    func livePosition(at date: Date = Date()) -> TimeInterval {
        let p = isPlaying ? anchorPosition + date.timeIntervalSince(anchorDate) : anchorPosition
        guard let d = track?.duration, d > 0 else { return max(0, p) }
        return min(max(0, p), d)
    }

    /// Position used for lyric timing (real clock + user offset).
    func lyricPosition(at date: Date = Date()) -> TimeInterval { livePosition(at: date) + lyricOffset }

    private func index(at position: TimeInterval) -> Int {
        lyrics.lastIndex(where: { $0.time <= position + lyricOffset + lookahead }) ?? -1
    }

    private func rebuildLyrics() {
        guard hideBackingVocals else { lyrics = rawLyrics; currentIndex = index(at: livePosition()); return }
        lyrics = rawLyrics.map { l in
            var t = l.text
            t = t.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            return LyricLine(time: l.time, text: t.trimmingCharacters(in: .whitespaces))
        }
        currentIndex = index(at: livePosition())
    }

    private func tick() {
        let idx = index(at: livePosition())
        if idx != currentIndex { currentIndex = idx }
        // Ease the tint toward the target (about a 1 s crossfade).
        if tintA != targetA || tintB != targetB {
            func step(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
                let d = b - a
                return (d * d).sum() < 1e-6 ? b : a + d * 0.07
            }
            tintA = step(tintA, targetA)
            tintB = step(tintB, targetB)
        }
    }

    private func loadArtwork(for t: TrackInfo) {
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            let p = await ArtworkService.palette(for: t.source)
            guard !Task.isCancelled, let self else { return }
            self.targetA = p?.0 ?? ArtworkService.neutral.0
            self.targetB = p?.1 ?? ArtworkService.neutral.1
        }
    }

    private func setAnchor(_ pos: TimeInterval, at date: Date = Date()) {
        anchorPosition = pos
        anchorDate = date
        currentIndex = index(at: livePosition())
    }

    // MARK: Notifications

    private func handle(_ info: [AnyHashable: Any]?, source: MusicSource) {
        guard let info else { return }
        let playing = (info["Player State"] as? String) == "Playing"
        let durKey = source == .appleMusic ? "Total Time" : "Duration"
        let t = TrackInfo(
            title: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            duration: ((info[durKey] as? NSNumber)?.doubleValue ?? 0) / 1000,
            source: source)

        isPlaying = playing
        if let sp = (info["Playback Position"] as? NSNumber)?.doubleValue {
            setAnchor(sp)
        }
        guard !t.title.isEmpty else { return }
        if t != track {
            track = t
            if info["Playback Position"] == nil { setAnchor(0) }
            loadLyrics(for: t)
            loadArtwork(for: t)
        }
        resync(force: true)   // precise position (Apple Music sends none)
    }

    func reloadLyrics() { if let t = track { loadLyrics(for: t) } }

    /// Use the given `.lrc` text for the current song (remembered on disk).
    @discardableResult
    func setCustomLyrics(_ text: String) -> Bool {
        guard let t = track, !LRCParser.parse(text).isEmpty else { NSSound.beep(); return false }
        LyricsStore.save(text, for: t)
        loadLyrics(for: t)
        return true
    }

    func removeCustomLyrics() {
        guard let t = track else { return }
        LyricsStore.remove(for: t)
        loadLyrics(for: t)
    }

    func importLyricsFromFile() {
        guard track != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "Choose a synced lyrics file (.lrc) for this song"
        panel.allowedContentTypes = [.init(filenameExtension: "lrc") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let text = try? String(contentsOf: url, encoding: .utf8) { setCustomLyrics(text) }
    }

    func importLyricsFromClipboard() {
        if let text = NSPasteboard.general.string(forType: .string) { setCustomLyrics(text) } else { NSSound.beep() }
    }

    private func loadLyrics(for t: TrackInfo) {
        hasCustomLyrics = LyricsStore.exists(for: t)
        lyrics = []
        rawLyrics = []
        currentIndex = -1
        lyricsLoading = true
        lyricsTask?.cancel()
        lyricsTask = Task { [weak self] in
            let l = await LyricsService.shared.lyrics(for: t, useCache: false)
            guard !Task.isCancelled, let self else { return }
            self.rawLyrics = l
            self.lyricsLoading = false
            self.rebuildLyrics()
        }
    }

    // MARK: Playback & Scrubbing Controls

    func togglePlayPause() {
        guard let t = track else { return }
        isPlaying.toggle()
        if isPlaying { anchorDate = Date() }
        let app = t.source == .appleMusic ? "Music" : "Spotify"
        scriptQueue.async {
            NSAppleScript(source: "tell application \"\(app)\" to playpause")?.executeAndReturnError(nil)
        }
    }

    func nextTrack() {
        guard let t = track else { return }
        let app = t.source == .appleMusic ? "Music" : "Spotify"
        scriptQueue.async {
            NSAppleScript(source: "tell application \"\(app)\" to next track")?.executeAndReturnError(nil)
        }
    }

    func previousTrack() {
        guard let t = track else { return }
        let app = t.source == .appleMusic ? "Music" : "Spotify"
        scriptQueue.async {
            NSAppleScript(source: "tell application \"\(app)\" to previous track")?.executeAndReturnError(nil)
        }
    }

    func seek(to position: TimeInterval) {
        guard let t = track else { return }
        let pos = min(max(0, position), t.duration)
        setAnchor(pos)
        let app = t.source == .appleMusic ? "Music" : "Spotify"
        scriptQueue.async {
            NSAppleScript(source: "tell application \"\(app)\" to set player position to \(pos)")?.executeAndReturnError(nil)
        }
    }

    // MARK: Seek / skip detection

    private func resync(force: Bool = false) {
        guard let t = track, isPlaying || force else { return }
        let source = t.source
        let expected = livePosition()
        let t0 = Date()
        scriptQueue.async { [weak self] in
            guard let pos = Self.readPosition(source) else { return }
            let t1 = Date()
            // The value was sampled roughly mid-call.
            let sampled = t0.addingTimeInterval(t1.timeIntervalSince(t0) / 2)
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated {
                    let drift = abs(pos - self.livePosition(at: sampled))
                    if force || drift > 0.45 || drift > 0.25 && expected != 0 && !self.isPlaying {
                        self.setAnchor(pos, at: sampled)
                    }
                }
            }
        }
    }

    private nonisolated static func readPosition(_ source: MusicSource) -> TimeInterval? {
        let (bundle, app) = source == .appleMusic ? ("com.apple.Music", "Music") : ("com.spotify.client", "Spotify")
        // Never launch the player just to ask for its position.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { return nil }
        var err: NSDictionary?
        let r = NSAppleScript(source: "tell application \"\(app)\" to return player position")?
            .executeAndReturnError(&err)
        return err == nil ? r?.doubleValue : nil
    }

    // MARK: Display helpers

    var statusText: String {
        if track == nil { return "Play something in Apple Music or Spotify" }
        if lyricsLoading { return "Finding lyrics…" }
        if lyrics.isEmpty { return "No synced lyrics for this track" }
        return ""
    }
}
