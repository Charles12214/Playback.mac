import AppKit

/// Fetches album art and extracts two vivid accent colours from it.
enum ArtworkService {
    typealias RGB = SIMD3<Double>
    static let neutral: (RGB, RGB) = (RGB(0.85, 0.85, 0.9), RGB(0.7, 0.72, 0.8))

    /// Call off the main thread (runs AppleScript / network).
    static func palette(for source: MusicSource) async -> (RGB, RGB)? {
        guard let img = await image(for: source) else { return nil }
        return extract(from: img)
    }

    private static func image(for source: MusicSource) async -> NSImage? {
        switch source {
        case .appleMusic:
            return await Task.detached { () -> NSImage? in
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return nil }
                var err: NSDictionary?
                let d = NSAppleScript(source: #"tell application "Music" to return data of artwork 1 of current track"#)?
                    .executeAndReturnError(&err)
                guard err == nil, let data = d?.data, !data.isEmpty else { return nil }
                return NSImage(data: data)
            }.value
        case .spotify:
            let urlString: String? = await Task.detached { () -> String? in
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else { return nil }
                var err: NSDictionary?
                let d = NSAppleScript(source: #"tell application "Spotify" to return artwork url of current track"#)?
                    .executeAndReturnError(&err)
                return err == nil ? d?.stringValue : nil
            }.value
            guard let s = urlString, let url = URL(string: s),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
    }

    /// Hue-bucketed, saturation/brightness-weighted dominant colours.
    static func extract(from image: NSImage) -> (RGB, RGB)? {
        let n = 32
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let px = ctx.data?.bindMemory(to: UInt8.self, capacity: n * n * 4) else { return nil }

        let buckets = 12
        var weight = [Double](repeating: 0, count: buckets)
        var sum = [RGB](repeating: .zero, count: buckets)
        for i in 0..<(n * n) {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            let c = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            let s = Double(c.saturationComponent), v = Double(c.brightnessComponent)
            let w = s * s * v + 0.0005          // favour vivid, bright pixels
            let k = min(buckets - 1, Int(Double(c.hueComponent) * Double(buckets)))
            weight[k] += w
            sum[k] += RGB(r, g, b) * w
        }
        let order = weight.indices.sorted { weight[$0] > weight[$1] }
        guard let first = order.first, weight[first] > 0.01 else { return nil }
        func colour(_ k: Int) -> RGB { vivid(sum[k] / weight[k]) }
        let a = colour(first)
        let b = order.dropFirst().first {
            let d = abs($0 - first); return min(d, buckets - d) >= 2 && weight[$0] > weight[first] * 0.25
        }.map(colour) ?? vivid(a * 0.8 + RGB(0.1, 0.1, 0.2))
        return (a, b)
    }

    /// Lift very dark / washed-out colours so the glass tint is always visible.
    private static func vivid(_ c: RGB) -> RGB {
        let ns = NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        let o = NSColor(hue: h, saturation: max(s, 0.45), brightness: max(b, 0.7), alpha: 1).usingColorSpace(.sRGB)!
        return RGB(Double(o.redComponent), Double(o.greenComponent), Double(o.blueComponent))
    }
}
