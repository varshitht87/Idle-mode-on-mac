import SwiftUI
import AppKit

// MARK: - Engine
//
// Holds the background's physical state between frames: blended colours, a spring-smoothed
// pointer, and click ripples. It is mutated from the TimelineView each frame and never
// publishes, so pointer movement doesn't re-render the view tree.

@MainActor
final class BackgroundEngine {
    struct Ripple { let center: CGPoint; let start: Double }

    struct Frame {
        var points: [SIMD2<Float>]
        var colors: [Color]
        var glow: RGB
        var pointer: CGPoint
        var presence: Double
        var phase: Double
    }

    var pointerTarget: CGPoint?
    private(set) var ripples: [Ripple] = []

    private var colors: [RGB] = []
    private var pointer = CGPoint(x: 0.5, y: 0.5)
    private var velocity = CGPoint.zero
    private var presence = 0.0
    private var phase = Double.random(in: 0...200)
    private var last: Double?

    func addRipple(_ p: CGPoint) {
        ripples.append(Ripple(center: p, start: Date().timeIntervalSinceReferenceDate))
        if ripples.count > 8 { ripples.removeFirst(ripples.count - 8) }
    }

    func step(now: Double, target: [RGB], accent: RGB, motion: Double, interactive: Bool) -> Frame {
        let dt = min(max(now - (last ?? now), 0), 0.1)
        last = now

        // Colours ease toward the target palette (smooth crossfade when the theme or artwork changes).
        if colors.count != target.count { colors = target }
        let k = 1 - exp(-dt * 2.2)
        for i in colors.indices { colors[i] = colors[i].mix(target[i], k) }

        // Critically damped spring (response 0.7s) for the pointer: no overshoot, always continuous.
        let goal = (interactive ? pointerTarget : nil) ?? CGPoint(x: 0.5, y: 0.5)
        let omega = 2 * Double.pi / 0.7
        let ax = omega * omega * (goal.x - pointer.x) - 2 * omega * velocity.x
        let ay = omega * omega * (goal.y - pointer.y) - 2 * omega * velocity.y
        velocity.x += ax * dt; velocity.y += ay * dt
        pointer.x += velocity.x * dt; pointer.y += velocity.y * dt
        presence += ((interactive && pointerTarget != nil ? 1 : 0) - presence) * (1 - exp(-dt * 3))

        phase += dt * motion * 1.1
        ripples.removeAll { now - $0.start > 1.6 }

        let p = phase
        let pull = SIMD2<Float>(Float((pointer.x - 0.5) * 0.32 * presence), Float((pointer.y - 0.5) * 0.32 * presence))
        func f(_ v: Double) -> Float { Float(v) }
        var center = SIMD2<Float>(f(0.5 + 0.2 * sin(p * 0.23)), f(0.5 + 0.2 * cos(p * 0.19))) + pull
        center = center.clamped(lowerBound: SIMD2(0.12, 0.12), upperBound: SIMD2(0.88, 0.88))

        let points: [SIMD2<Float>] = [
            [0, 0], [f(0.5 + 0.22 * sin(p * 0.31)), 0], [1, 0],
            [0, f(0.5 + 0.22 * sin(p * 0.27 + 1))], center, [1, f(0.5 + 0.22 * cos(p * 0.33 + 2))],
            [0, 1], [f(0.5 + 0.22 * cos(p * 0.29 + 3)), 1], [1, 1],
        ]

        let c = colors
        let breathe = 0.5 + 0.5 * sin(p * 0.21)
        let mid = c[2].mix(c[3], breathe * 0.45)
        let meshColors: [Color] = [
            c[0].color, c[1].color, c[4].color,
            c[1].mix(c[2], 0.3).color, mid.color, c[3].mix(c[1], 0.55).color,
            c[4].color, c[3].mix(c[0], 0.5).color, c[0].color,
        ]

        return Frame(points: points, colors: meshColors, glow: accent, pointer: pointer, presence: presence, phase: p)
    }
}

// MARK: - View

struct LiveBackground: View {
    let engine: BackgroundEngine
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var nowPlaying: NowPlayingService
    @EnvironmentObject private var ui: UIState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cfg = settings.config
        let target = settings.colors(adaptive: nowPlaying.artPalette)
        let accent = settings.accent(adaptive: nowPlaying.artPalette)
        let texture = TextureFactory.image(cfg.texture)

        GeometryReader { geo in
            // 60 fps is plenty for a slow ambient drift, and leaves the main thread free for paging.
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: ui.paging || ui.transitioning)) { tl in
                let now = tl.date.timeIntervalSinceReferenceDate
                let frame = engine.step(now: now, target: target, accent: accent,
                                        motion: reduceMotion ? 0 : cfg.motion,
                                        interactive: cfg.interactive)
                let size = geo.size
                let maxDim = max(size.width, size.height)

                ZStack(alignment: .topLeading) {
                    if settings.showsPhoto, let photo = settings.photo {
                        // Cover the window with explicit math (any aspect ratio), plus a little slack
                        // so drift and pointer parallax can never expose an edge.
                        let iw = max(1, photo.size.width), ih = max(1, photo.size.height)
                        let scale = max(size.width / iw, size.height / ih) * 1.08
                        let dw = iw * scale, dh = ih * scale
                        let slackX = (dw - size.width) / 2, slackY = (dh - size.height) / 2
                        let p = frame.phase
                        let dx = (0.5 - frame.pointer.x) * 1.2 * slackX * frame.presence + 0.3 * slackX * sin(p * 0.07)
                        let dy = (0.5 - frame.pointer.y) * 1.2 * slackY * frame.presence + 0.3 * slackY * cos(p * 0.05)
                        Image(nsImage: photo)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: dw, height: dh)
                            .position(x: size.width / 2 + min(slackX, max(-slackX, dx)),
                                      y: size.height / 2 + min(slackY, max(-slackY, dy)))
                        Color.black.opacity(0.18)
                    } else {
                        MeshGradient(width: 3, height: 3, points: frame.points, colors: frame.colors, smoothsColors: true)
                    }

                    // Soft light that follows the pointer.
                    RadialGradient(colors: [frame.glow.color.opacity(0.55 * frame.presence), .clear],
                                   center: UnitPoint(x: frame.pointer.x, y: frame.pointer.y),
                                   startRadius: 0, endRadius: maxDim * 0.38)
                        .blendMode(.softLight)

                    RippleLayer(ripples: engine.ripples, now: now, tint: frame.glow)

                    if let texture {
                        TextureLayer(image: texture, kind: cfg.texture, amount: cfg.textureAmount,
                                     tint: frame.glow, now: reduceMotion ? 0 : now,
                                     parallax: CGPoint(x: (frame.pointer.x - 0.5) * 14, y: (frame.pointer.y - 0.5) * 14),
                                     size: size)
                    }

                    // Vignette keeps the edges calm and the blocks legible.
                    RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center,
                                   startRadius: maxDim * 0.25, endRadius: maxDim * 0.8)
                }
                .frame(width: size.width, height: size.height)
                .clipped()
                .drawingGroup()   // render the whole background as one Metal layer
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct RippleLayer: View {
    let ripples: [BackgroundEngine.Ripple]
    let now: Double
    let tint: RGB

    var body: some View {
        Canvas { ctx, size in
            ctx.blendMode = .plusLighter
            let maxDim = max(size.width, size.height)
            for r in ripples {
                let a = min(1, (now - r.start) / 1.6)
                let eased = 1 - pow(1 - a, 3)
                let radius = 20 + eased * maxDim * 0.32
                let c = CGPoint(x: r.center.x * size.width, y: r.center.y * size.height)
                let rect = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
                let fade = (1 - a) * (1 - a)
                ctx.fill(Path(ellipseIn: rect),
                         with: .radialGradient(Gradient(colors: [tint.color.opacity(0.0), tint.color.opacity(0.10 * fade), .clear]),
                                               center: c, startRadius: radius * 0.6, endRadius: radius))
                ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.18 * fade)), lineWidth: 1.2)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct TextureLayer: View {
    let image: CGImage
    let kind: TextureKind
    let amount: Double
    let tint: RGB
    let now: Double
    let parallax: CGPoint
    let size: CGSize

    var body: some View {
        let tile: CGFloat = 128
        // Film grain re-rolls 24 times a second; patterned textures stay put and only drift with the pointer.
        let jitter: CGPoint = {
            guard kind == .grain || kind == .smooth else { return parallax }
            var h = UInt64(Int(now * 24)) &* 0x9E3779B97F4A7C15
            h ^= h >> 29
            return CGPoint(x: CGFloat(h % 128), y: CGFloat((h >> 8) % 128))
        }()
        let strength = kind == .smooth ? 0.12 : amount

        // The oversized tile strip lives in an overlay so it never changes this layer's size
        // (an oversized child would grow and re-centre the whole background stack).
        Color.clear
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    texture
                        .blendMode(.overlay)
                        .opacity(strength)
                    // A second pass tinted with the theme colour so the texture picks up the palette.
                    texture
                        .colorMultiply(tint.color)
                        .blendMode(.screen)
                        .opacity(strength * 0.32)
                }
                .frame(width: size.width + tile * 2, height: size.height + tile * 2, alignment: .topLeading)
                .offset(x: -tile + jitter.x.truncatingRemainder(dividingBy: tile),
                        y: -tile + jitter.y.truncatingRemainder(dividingBy: tile))
            }
            .allowsHitTesting(false)
    }

    private var texture: some View {
        Image(decorative: image, scale: 2)
            .resizable(resizingMode: .tile)
    }
}

// MARK: - Procedural textures

enum TextureFactory {
    @MainActor private static var cache: [TextureKind: CGImage] = [:]

    @MainActor static func image(_ kind: TextureKind) -> CGImage? {
        if let c = cache[kind] { return c }
        let img = make(kind)
        cache[kind] = img
        return img
    }

    private struct RNG {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
        mutating func gauss() -> Double { (unit() + unit() + unit() + unit()) / 4 - 0.5 }
    }

    private static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    /// Tileable value noise: the lattice wraps so the 256px tile repeats seamlessly.
    private static func noise(_ rng: inout RNG, n: Int, cells: Int) -> [Double] {
        let lat = (0..<(cells * cells)).map { _ in rng.unit() }
        var out = [Double](repeating: 0, count: n * n)
        for y in 0..<n {
            let fy = Double(y) / Double(n) * Double(cells)
            let y0 = Int(fy) % cells, y1 = (y0 + 1) % cells, ty = smooth(fy - floor(fy))
            for x in 0..<n {
                let fx = Double(x) / Double(n) * Double(cells)
                let x0 = Int(fx) % cells, x1 = (x0 + 1) % cells, tx = smooth(fx - floor(fx))
                let a = lat[y0 * cells + x0], b = lat[y0 * cells + x1]
                let c = lat[y1 * cells + x0], d = lat[y1 * cells + x1]
                let top = a + (b - a) * tx, bottom = c + (d - c) * tx
                out[y * n + x] = top + (bottom - top) * ty
            }
        }
        return out
    }

    static func make(_ kind: TextureKind) -> CGImage? {
        let n = 256
        var rng = RNG(s: 0xC0FFEE ^ UInt64(kind.rawValue.hashValue & 0xFFFF))
        var v = [Double](repeating: 0.5, count: n * n)

        switch kind {
        case .grain, .smooth:
            for i in v.indices { v[i] = 0.5 + rng.gauss() * 1.9 }

        case .paper:
            let low = noise(&rng, n: n, cells: 8), mid = noise(&rng, n: n, cells: 32)
            for i in v.indices { v[i] = 0.5 + (low[i] - 0.5) * 0.28 + (mid[i] - 0.5) * 0.14 + rng.gauss() * 0.6 }

        case .linen:
            let rows = (0..<(n / 2)).map { _ in rng.unit() }
            let cols = (0..<(n / 2)).map { _ in rng.unit() }
            let low = noise(&rng, n: n, cells: 4)
            for y in 0..<n {
                for x in 0..<n {
                    let weave = ((x / 2 + y / 2) % 2 == 0) ? 0.05 : -0.05
                    v[y * n + x] = 0.5 + (rows[y / 2] - 0.5) * 0.26 + (cols[x / 2] - 0.5) * 0.22
                        + weave + (low[y * n + x] - 0.5) * 0.12 + rng.gauss() * 0.3
                }
            }

        case .halftone:
            let size = noise(&rng, n: n, cells: 4)
            let cell = 8.0
            for y in 0..<n {
                for x in 0..<n {
                    let cx = (floor(Double(x) / cell) + 0.5) * cell
                    let cy = (floor(Double(y) / cell) + 0.5) * cell
                    let d = ((Double(x) + 0.5 - cx) * (Double(x) + 0.5 - cx) + (Double(y) + 0.5 - cy) * (Double(y) + 0.5 - cy)).squareRoot()
                    let radius = 1.2 + size[y * n + x] * 2.6
                    let dot = 1 - min(1, max(0, d - radius + 0.5))
                    v[y * n + x] = 0.47 + dot * 0.26 + rng.gauss() * 0.25
                }
            }
        }

        var bytes = v.map { UInt8(max(0, min(255, $0 * 255))) }
        let image: CGImage? = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            if kind == .paper {
                // Fibres: short, faint curved strokes, light and dark.
                ctx.setLineCap(.round)
                for i in 0..<160 {
                    let x = rng.unit() * Double(n), y = rng.unit() * Double(n)
                    let a = rng.unit() * .pi * 2, len = 6 + rng.unit() * 18
                    ctx.setStrokeColor(gray: i % 2 == 0 ? 0.75 : 0.3, alpha: 0.28)
                    ctx.setLineWidth(0.5 + rng.unit() * 0.6)
                    ctx.move(to: CGPoint(x: x, y: y))
                    ctx.addQuadCurve(to: CGPoint(x: x + cos(a) * len, y: y + sin(a) * len),
                                     control: CGPoint(x: x + cos(a + 0.6) * len * 0.5, y: y + sin(a + 0.6) * len * 0.5))
                    ctx.strokePath()
                }
            }
            return ctx.makeImage()
        }
        return image
    }
}
