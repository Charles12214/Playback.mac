# Playback.mac

Playback.mac is a native macOS liquid-glass live lyrics widget and floating HUD for Apple Music and Spotify, built in Swift and SwiftUI.

## Key Features

- **Live Time-Synced Lyrics:** Queries [LRCLIB](https://lrclib.net) with smart duration and metadata matching so lyrics stay aligned with the active track, plus local `.lrc` override support stored in `~/Library/Application Support/Playback.mac/Lyrics`.
- **Atmosphere Wave Playhead:** An animated liquid-glass wave progresses behind the lyrics across the pill, with top-edge drag-to-scrub seeking that smoothly swaps lyrics for a live timestamp while scrubbing.
- **Album-Adaptive Glass Tinting:** Extracts dominant accent colors from the current track's artwork in real time to tint the glass surface and wave crest.
- **Dual Placement Modes:** Switch between a **Floating HUD** (`Small`, `Medium`, `Large`) above windows and a pinned **Desktop Widget** mode (`364 × 170 pt`, matching native macOS medium widgets) layered behind app windows, complete with independent saved screen coordinates and click-through toggle.
- **Inline & Menu Bar Controls:** Hover over the bottom track title bar for Previous, Play/Pause, and Next controls, or use the menu bar item (`⌘⇧L` to toggle visibility) to nudge lyric timing, filter bracketed backing vocals, and manage custom `.lrc` files.

## Requirements

- macOS 14.0 or later (optimized for macOS 26+ Liquid Glass APIs)
- Apple Silicon Mac (for pre-built release binaries)
- Apple Music and/or Spotify desktop app

## Installation

1. Download `Playback.mac-1.0.0.dmg` (or `Playback.mac-1.0.0.pkg`) from the [Releases](../../releases) page.
2. Open the disk image and drag **Playback.app** into your **Applications** folder (or run the `.pkg` installer).
3. **First Launch (Gatekeeper):** Because release builds are ad-hoc signed without an Apple Developer ID certificate, right-click (or Control-click) **Playback.app** in Applications, choose **Open**, and confirm **Open** on the prompt.
4. Allow the macOS Automation prompt when asked so Playback.mac can read playback timestamps and control Apple Music or Spotify.

## Building from Source

Requires Swift 6.0+ / Xcode Command Line Tools on macOS:

```zsh
# Build Playback.app
./build_app.sh

# Build Playback.app plus Playback.mac-1.0.0.dmg and Playback.mac-1.0.0.pkg
./build_installer.sh
```

## License

See [`LICENSE`](LICENSE) for details.

