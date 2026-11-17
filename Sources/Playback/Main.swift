import SwiftUI
import AppKit
import Combine

enum HUDMode: String, CaseIterable, Identifiable {
    case floating = "Floating (above windows)", desktop = "Desktop (behind windows)"
    var id: String { rawValue }
}

@MainActor
final class HUDSettings: ObservableObject {
    @Published var mode: HUDMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") } }
    /// Desktop placement always uses the widget-sized layout; other sizes are floating-only.
    var effectiveSize: HUDSize { mode == .desktop ? .compact : size }
    @Published var size: HUDSize { didSet { UserDefaults.standard.set(size.rawValue, forKey: "size") } }
    @Published var clickThrough: Bool { didSet { UserDefaults.standard.set(clickThrough, forKey: "clickThrough") } }
    init() {
        let d = UserDefaults.standard
        mode = HUDMode(rawValue: d.string(forKey: "mode") ?? "") ?? .floating
        size = HUDSize(rawValue: d.string(forKey: "size") ?? "") ?? .standard
        clickThrough = d.bool(forKey: "clickThrough")
    }
}

@main
struct PlaybackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("Playback", systemImage: "music.note.list") {
            MenuContent(settings: delegate.settings, playback: delegate.playback, toggle: delegate.toggleHUD)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var settings: HUDSettings
    @ObservedObject var playback: PlaybackManager
    let toggle: () -> Void

    var body: some View {
        Button("Show / Hide Lyrics") { toggle() }.keyboardShortcut("l", modifiers: [.command, .shift])
        Divider()
        Picker("Placement", selection: $settings.mode) {
            ForEach(HUDMode.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.inline)
        if settings.mode == .floating {
            Picker("Size", selection: $settings.size) {
                ForEach(HUDSize.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.inline)
        } else {
            Text("Size: \(HUDSize.compact.rawValue) — desktop widgets use one size")
        }
        Toggle("Click-through (ignore mouse)", isOn: $settings.clickThrough)
        Divider()
        Text("Lyric timing: \(playback.lyricOffset >= 0 ? "+" : "")\(String(format: "%.2f", playback.lyricOffset)) s")
        Button("Lyrics earlier (+0.25 s)") { playback.lyricOffset += 0.25 }
        Button("Lyrics later (−0.25 s)") { playback.lyricOffset -= 0.25 }
        Button("Reset timing") { playback.lyricOffset = 0 }
        Toggle("Hide (bracketed) backing vocals", isOn: $playback.hideBackingVocals)
        Divider()
        Menu("Lyrics for this song") {
            Button("Use .lrc file…") { playback.importLyricsFromFile() }
            Button("Use .lrc text from clipboard") { playback.importLyricsFromClipboard() }
            Button("Remove my custom lyrics") { playback.removeCustomLyrics() }.disabled(!playback.hasCustomLyrics)
            Button("Look up again") { playback.reloadLyrics() }
        }.disabled(playback.track == nil)
        Divider()
        Button("Quit Playback") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let playback = PlaybackManager()
    let settings = HUDSettings()
    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        showHUD()
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applySettings() } }
            .store(in: &bag)
    }

    func toggleHUD() { (panel?.isVisible ?? false) ? panel?.orderOut(nil) : showHUD() }

    private func showHUD() {
        if panel == nil { buildPanel() }
        applySettings()
        panel?.orderFrontRegardless()
    }

    private func buildPanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 230),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = false // Controlled via drag handle so playhead scrubs cleanly
        p.isReleasedWhenClosed = false
        panel = p
        
        // Listen to window move to persist position locally
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel else { return }
                let key = self.settings.mode == .desktop ? "desktopOrigin" : "floatingOrigin"
                let pt = NSStringFromPoint(p.frame.origin)
                UserDefaults.standard.set(pt, forKey: key)
            }
        }
    }

    private func applySettings() {
        guard let p = panel else { return }
        let spec = settings.effectiveSize.spec
        let root = AnyView(LyricsPillView(pm: playback).environment(\.hudSpec, spec))
        if let host { host.rootView = root } else {
            let h = NSHostingView(rootView: root)
            p.contentView = h
            host = h
        }
        // Resize and restore saved position for the active mode
        let size = NSSize(width: spec.width, height: spec.height)
        let key = settings.mode == .desktop ? "desktopOrigin" : "floatingOrigin"
        if let saved = UserDefaults.standard.string(forKey: key) {
            let pt = NSPointFromString(saved)
            p.setFrame(NSRect(origin: pt, size: size), display: true)
        } else if let s = NSScreen.main {
            let defaultPt = NSPoint(x: s.frame.midX - size.width / 2, y: s.frame.minY + 120)
            p.setFrame(NSRect(origin: defaultPt, size: size), display: true)
            UserDefaults.standard.set(NSStringFromPoint(defaultPt), forKey: key)
        } else {
            let old = p.frame
            p.setFrame(NSRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        }

        switch settings.mode {
        case .floating:
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        case .desktop:
            // Above desktop icons, below every app window — a true desktop widget.
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
        p.ignoresMouseEvents = settings.clickThrough
    }
}
