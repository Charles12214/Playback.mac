
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }
    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

final class WindowDragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

func formatTime(_ t: TimeInterval) -> String {
    let s = Int(max(0, t))
    let mins = s / 60
    let secs = s % 60
    return String(format: "%d:%02d", mins, secs)
}
import SwiftUI

import AppKit

struct HUDSpec {
    var width: CGFloat, rowH: CGFloat, rows: CGFloat, font: CGFloat, corner: CGFloat, showTitle: Bool
    var height: CGFloat { rowH * rows + 32 + (showTitle ? 20 : 0) }
}

enum HUDSize: String, CaseIterable, Identifiable {
    case compact = "Small (widget size)", standard = "Medium", large = "Large"
    var id: String { rawValue }
    var spec: HUDSpec {
        switch self {
        case .compact:  return HUDSpec(width: 364, rowH: 40, rows: 2.95, font: 17, corner: 24, showTitle: true)
        case .standard: return HUDSpec(width: 560, rowH: 62, rows: 3.0, font: 26, corner: 30, showTitle: true)
        case .large:    return HUDSpec(width: 700, rowH: 82, rows: 3.8, font: 34, corner: 36, showTitle: true)
        }
    }
}

private struct HUDSpecKey: EnvironmentKey { static let defaultValue = HUDSize.standard.spec }
extension EnvironmentValues {
    var hudSpec: HUDSpec { get { self[HUDSpecKey.self] } set { self[HUDSpecKey.self] = newValue } }
}

struct LyricsPillView: View {
    @Environment(\.hudSpec) private var spec
    @ObservedObject var pm: PlaybackManager

    var body: some View {
        ZStack(alignment: .top) {
            // Window drag layer: clicking & dragging the background or lyrics area moves the window
            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(!pm.isScrubbing)

            VStack(spacing: 4) {
                // Top scrubber track / wave handle (top 28 pt): dedicated scrubbing zone
                GeometryReader { topGeo in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { val in
                                    guard let dur = pm.track?.duration, dur > 0 else { return }
                                    if !pm.isScrubbing {
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                            pm.isScrubbing = true
                                        }
                                    }
                                    let fraction = min(max(0, val.location.x / topGeo.size.width), 1)
                                    pm.scrubPosition = Double(fraction) * dur
                                }
                                .onEnded { val in
                                    guard let dur = pm.track?.duration, dur > 0 else { return }
                                    let fraction = min(max(0, val.location.x / topGeo.size.width), 1)
                                    let target = Double(fraction) * dur
                                    pm.seek(to: target)
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        pm.isScrubbing = false
                                    }
                                }
                        )
                }
                .frame(height: 24)

                // Main lyrics or Scrubbing Timestamp HUD
                ZStack {
                    if pm.isScrubbing {
                        // Scrubbing HUD: Large animated timestamp
                        VStack(spacing: 2) {
                            Text(formatTime(pm.scrubPosition))
                                .font(.system(size: spec.font * 1.6, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            if let dur = pm.track?.duration, dur > 0 {
                                Text("of \(formatTime(dur))")
                                    .font(.system(size: spec.font * 0.55, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity),
                                                removal: .scale(scale: 0.9).combined(with: .opacity)))
                    } else {
                        // Normal lyrics / status view
                        ZStack {
                            if pm.lyrics.isEmpty {
                                Text(pm.statusText)
                                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            } else {
                                LyricsStack(pm: pm)
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .frame(height: spec.rowH * spec.rows - 24)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: pm.isScrubbing)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                             .init(color: .black, location: 0.2),
                                             .init(color: .black, location: 0.8),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                
                if spec.showTitle {
                    BottomControlsBar(pm: pm)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
        }
        .frame(width: spec.width, height: spec.height)
        .background { GlassFlowBackground(pm: pm) }
    }
}

// MARK: - Glass Flow progress background

struct GlassFlowBackground: View {
    @Environment(\.hudSpec) private var spec
    private var a: Color { Color(.sRGB, red: pm.tintA.x, green: pm.tintA.y, blue: pm.tintA.z) }
    private var b: Color { Color(.sRGB, red: pm.tintB.x, green: pm.tintB.y, blue: pm.tintB.z) }
    @ObservedObject var pm: PlaybackManager

    var body: some View {
        ZStack {
            baseGlass
            LinearGradient(colors: [a.opacity(0.16), b.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(RoundedRectangle(cornerRadius: spec.corner, style: .continuous))
                .allowsHitTesting(false)
            TimelineView(.animation) { ctx in
                let dur = max(pm.track?.duration ?? 0, 1)
                let activePos = pm.isScrubbing ? pm.scrubPosition : pm.livePosition(at: ctx.date)
                let f = CGFloat(activePos / dur)
                let t = ctx.date.timeIntervalSinceReferenceDate
                GeometryReader { geo in
                    let w = geo.size.width
                    // Soft feathered body behind the front
                    wave(w: w, front: w * f - 24, feather: 280, opacity: 0.10, tint: a)
                    // "Atmosphere" front: an undulating liquid edge with a glowing crest
                    let h = geo.size.height
                    let front = w * f
                    let body = WaveEdge(front: front, t: t, amp: 10, height: h, closed: true)
                    body.fill(LinearGradient(colors: [b.opacity(0.0), b.opacity(0.22)],
                                             startPoint: UnitPoint(x: max(0, (front - 150) / w), y: 0.5),
                                             endPoint: UnitPoint(x: max(0.001, front / w), y: 0.5)))
                        .blur(radius: 10)
                    WaveEdge(front: front - 6, t: t * 0.8 + 2, amp: 7, height: h, closed: false)
                        .stroke(b.opacity(0.30), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .blur(radius: 9)
                    WaveEdge(front: front, t: t, amp: 10, height: h, closed: false)
                        .stroke(LinearGradient(colors: [a.opacity(0.08), a.opacity(0.55), a.opacity(0.08)],
                                               startPoint: .top, endPoint: .bottom),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .blur(radius: 1.6)
                        .opacity(f > 0.003 ? 1 : 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: spec.corner, style: .continuous))
            .allowsHitTesting(false)
        }
    }

    /// A tint that is fully "filled" behind the front and dissolves smoothly ahead of it.
    private func wave(w: CGFloat, front: CGFloat, feather: CGFloat, opacity: Double, tint: Color) -> some View {
        let end = min(1, max(0, front / w))
        let start = min(end, max(0, (front - feather) / w))
        return LinearGradient(colors: [tint.opacity(opacity * 0.6), tint.opacity(opacity)],
                              startPoint: .top, endPoint: .bottom)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                         .init(color: .black, location: start),
                                         .init(color: .clear, location: max(end, start + 0.0001)),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
    }

    @ViewBuilder private var baseGlass: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: spec.corner))
        } else {
            RoundedRectangle(cornerRadius: spec.corner, style: .continuous).fill(.ultraThinMaterial)
        }
    }
}

// MARK: - Physics lyric stack

struct LyricsStack: View {
    @Environment(\.hudSpec) private var spec
    @ObservedObject var pm: PlaybackManager
    private let spring = Animation.spring(response: 0.6, dampingFraction: 0.62)

    var body: some View {
        let cur = pm.currentIndex
        let lo = max(0, cur - 2), hi = min(pm.lyrics.count - 1, cur + 2)
        ZStack {
            if cur < 0 || pm.lyrics.indices.contains(cur) && pm.lyrics[cur].text.isEmpty {
                BreathingDots(pm: pm, index: cur)
            }
            if lo <= hi {
                ForEach(lo...hi, id: \.self) { i in
                    LyricRow(pm: pm, index: i, distance: i - cur)
                        .offset(y: CGFloat(i - cur) * spec.rowH)
                        .transition(.opacity)
                }
            }
        }
        .animation(spring, value: cur)
        .frame(maxWidth: .infinity)
    }
}

struct LyricRow: View {
    @State private var wraps = false
    @Environment(\.hudSpec) private var spec
    @ObservedObject var pm: PlaybackManager
    let index: Int
    let distance: Int

    var body: some View {
        // Rows can briefly outlive the lyrics array when the track changes.
        if pm.lyrics.indices.contains(index), !pm.lyrics[index].text.isEmpty {
            let line = pm.lyrics[index]
            let active = distance == 0
            ZStack {
                Text(line.text).foregroundStyle(.white.opacity(active ? 0.38 : 0.55))
                    // Measure the real layout: it only counts as wrapped if the text is taller than one line.
                    .background(GeometryReader { g in
                        Color.clear.onChange(of: g.size.height, initial: true) { _, h in
                            wraps = h > spec.font * 1.5
                        }
                    })
                if active {
                    TimelineView(.animation) { ctx in
                        let f = fill(at: ctx.date)
                        Text(line.text)
                            .foregroundStyle(.white)
                            .mask {
                                if wraps {   // fill the first wrapped line, then the second
                                    VStack(spacing: 0) {
                                        KaraokeMask(fill: min(1, f * 2))
                                        KaraokeMask(fill: max(0, f * 2 - 1))
                                    }
                                } else { KaraokeMask(fill: f) }
                            }
                    }
                }
            }
            .font(.system(size: spec.font, weight: .bold, design: .rounded))
            .multilineTextAlignment(.center)
            .lineLimit(2).minimumScaleFactor(0.7)
            .frame(width: spec.width - 56, height: spec.rowH)
            .scaleEffect(active ? 1.0 : 0.66)
            .opacity(active ? 1 : max(0.15, 0.55 - 0.2 * Double(abs(distance) - 1)))
            .blur(radius: abs(distance) > 1 ? 2.5 : 0)
        }
    }

    /// Line-level karaoke fill (LRCLIB has no per-word timing, so progress is
    /// spread across the line, capped to a natural singing pace).
    private func fill(at date: Date) -> Double {
        guard pm.lyrics.indices.contains(index) else { return 0 }
        let p = pm.lyricPosition(at: date)
        let start = pm.lyrics[index].time
        let next = index + 1 < pm.lyrics.count ? pm.lyrics[index + 1].time : start + 4
        let dur = max(0.3, min(next - start, max(1.0, Double(pm.lyrics[index].text.count) * 0.085)))
        return min(1, max(0, (p - start) / dur))
    }
}

struct KaraokeMask: View {
    let fill: Double
    var body: some View {
        // Soft edge that travels from fully off the left to fully off the right,
        // so at fill == 1 every character (incl. trailing punctuation) is solid.
        let feather = 0.08
        let e = -feather + fill * (1 + feather)
        return LinearGradient(stops: [.init(color: .white, location: 0),
                                      .init(color: .white, location: min(1, max(0, e))),
                                      .init(color: .white.opacity(0), location: min(1, max(0, e) + feather)),
                                      .init(color: .white.opacity(0), location: 1)],
                              startPoint: .leading, endPoint: .trailing)
    }
}

/// Instrumental break / long intro: three dots that fill until the next line.
struct BreathingDots: View {
    @Environment(\.hudSpec) private var spec
    @ObservedObject var pm: PlaybackManager
    let index: Int

    var body: some View {
        TimelineView(.animation) { ctx in
            let p = pm.lyricPosition(at: ctx.date)
            let start = pm.lyrics.indices.contains(index) ? pm.lyrics[index].time : 0
            let nextIdx = index + 1
            let end = pm.lyrics.indices.contains(nextIdx) ? pm.lyrics[nextIdx].time : start + 1
            let f = min(1, max(0, (p - start) / max(0.1, end - start)))
            let breath = 1 + 0.08 * sin(ctx.date.timeIntervalSinceReferenceDate * 3)
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { i in
                    let local = min(1, max(0, f * 3 - Double(i)))
                    Circle().fill(.white.opacity(0.25 + 0.75 * local))
                        .frame(width: 13, height: 13)
                        .scaleEffect((0.8 + 0.3 * local) * breath)
                }
            }
            .opacity(end - p < 0.35 ? max(0, (end - p) / 0.35) : 1)
        }
        .offset(y: index < 0 ? -spec.rowH * 0.2 : 0)
    }
}

/// A vertical, gently undulating liquid edge whose crest sits at `front`.
struct WaveEdge: Shape {
    var front: CGFloat
    var t: Double
    var amp: CGFloat
    var height: CGFloat
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        func x(_ y: CGFloat) -> CGFloat {
            let n = y / max(height, 1)
            return front
                + amp * CGFloat(sin(Double(n) * .pi * 3 + t * 1.5))
                + amp * 0.45 * CGFloat(sin(Double(n) * .pi * 5.4 - t * 1.0))
        }
        var p = Path()
        if closed { p.move(to: CGPoint(x: -40, y: -10)); p.addLine(to: CGPoint(x: x(-10), y: -10)) }
        else { p.move(to: CGPoint(x: x(-10), y: -10)) }
        var y: CGFloat = -10
        while y <= height + 10 { y += 4; p.addLine(to: CGPoint(x: x(y), y: y)) }
        if closed { p.addLine(to: CGPoint(x: -40, y: height + 10)); p.closeSubpath() }
        return p
    }
}

// MARK: - Hover Bottom Controls

struct BottomControlsBar: View {
    @ObservedObject var pm: PlaybackManager
    @State private var isHovered = false

    var body: some View {
        ZStack {
            if isHovered && pm.track != nil {
                HStack(spacing: 22) {
                    Button(action: { pm.previousTrack() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 13, weight: .bold))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { pm.togglePlayPause() }) {
                        Image(systemName: pm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { pm.nextTrack() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 13, weight: .bold))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.white)
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.9)),
                                        removal: .opacity.combined(with: .scale(scale: 0.9))))
            } else {
                if let t = pm.track {
                    Text("\(t.title) — \(t.artist)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                } else {
                    Text("")
                        .font(.system(size: 11))
                }
            }
        }
        .frame(height: 20)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
    }
}
