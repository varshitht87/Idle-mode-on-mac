import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreImage

// MARK: - Colour

struct RGB: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init(h: Double, s: Double, v: Double) {
        let h6 = (h - floor(h)) * 6
        let i = floor(h6), f = h6 - i
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let c: (Double, Double, Double)
        switch Int(i) % 6 {
        case 0: c = (v, t, p)
        case 1: c = (q, v, p)
        case 2: c = (p, v, t)
        case 3: c = (p, q, v)
        case 4: c = (t, p, v)
        default: c = (v, p, q)
        }
        r = c.0; g = c.1; b = c.2
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    func mix(_ o: RGB, _ t: Double) -> RGB {
        RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
    }

    var hsv: (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    /// Same hue, new brightness and scaled saturation — used to fit any colour into the background's tonal range.
    func toned(v: Double, sat: Double = 1) -> RGB {
        let c = hsv
        return RGB(h: c.h, s: min(1, c.s * sat), v: v)
    }

    func distance(_ o: RGB) -> Double {
        let dr = r - o.r, dg = g - o.g, db = b - o.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

// MARK: - Palettes

struct Palette: Identifiable, Equatable {
    let id: String
    let name: String
    /// Five tones: [deep base, mid, vivid, light, shadow]
    let colors: [RGB]
    let accent: RGB

    static let adaptiveID = "adaptive"

    static let presets: [Palette] = [
        Palette(id: "dusk", name: "Dusk",
                colors: [RGB(0x1B1035), RGB(0x5B2A86), RGB(0xE0607E), RGB(0xF9A26C), RGB(0x2D1B69)],
                accent: RGB(0xFFB38A)),
        Palette(id: "ocean", name: "Ocean",
                colors: [RGB(0x03122B), RGB(0x0B3D91), RGB(0x1A8FB5), RGB(0x5FD4C8), RGB(0x062A4F)],
                accent: RGB(0x7FE7DA)),
        Palette(id: "aurora", name: "Aurora",
                colors: [RGB(0x05140F), RGB(0x0E4D3A), RGB(0x2BBF8A), RGB(0x7A5CFF), RGB(0x0B2A3D)],
                accent: RGB(0x8CFFC9)),
        Palette(id: "ember", name: "Ember",
                colors: [RGB(0x170806), RGB(0x5C1A0E), RGB(0xD9481C), RGB(0xFFB347), RGB(0x2E0F0A)],
                accent: RGB(0xFFC07A)),
        Palette(id: "bloom", name: "Bloom",
                colors: [RGB(0x1A0B1E), RGB(0x8E2D6A), RGB(0xFF7EB6), RGB(0xFFD3E8), RGB(0x3C1253)],
                accent: RGB(0xFF9DCB)),
        Palette(id: "graphite", name: "Graphite",
                colors: [RGB(0x0B0B0D), RGB(0x2A2A30), RGB(0x55555E), RGB(0x9A9AA5), RGB(0x17171B)],
                accent: RGB(0xE8E8EE)),
    ]

    static func preset(_ id: String) -> Palette { presets.first { $0.id == id } ?? presets[0] }
}

// MARK: - Widgets & textures

enum WidgetKind: String, CaseIterable, Codable, Identifiable {
    case clock, analog, calendar, nowPlaying, battery, timer, worldClock, system, note, redirect
    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: "Clock"
        case .analog: "Analog"
        case .calendar: "Calendar"
        case .nowPlaying: "Now Playing"
        case .battery: "Battery"
        case .timer: "Timer"
        case .worldClock: "World Clock"
        case .system: "System"
        case .note: "Note"
        case .redirect: "Redirect"
        }
    }

    var symbol: String {
        switch self {
        case .clock: "textformat.123"
        case .analog: "clock"
        case .calendar: "calendar"
        case .nowPlaying: "waveform"
        case .battery: "battery.75percent"
        case .timer: "timer"
        case .worldClock: "globe"
        case .system: "cpu"
        case .note: "note.text"
        case .redirect: "arrow.up.forward.app"
        }
    }
}

/// How the Redirect tile draws app icons, like iPhone's icon appearance: tinted to the theme, dark, clear glass, or as-is.
enum AppIconStyle: String, CaseIterable, Codable, Identifiable {
    case theme, dark, clear, original
    var id: String { rawValue }
    var title: String {
        switch self {
        case .theme: "Theme"
        case .dark: "Dark"
        case .clear: "Clear"
        case .original: "Original"
        }
    }
    var symbol: String {
        switch self {
        case .theme: "paintpalette.fill"
        case .dark: "moon.fill"
        case .clear: "drop.halffull"
        case .original: "app.fill"
        }
    }
}

enum TextureKind: String, CaseIterable, Codable, Identifiable {
    case grain, paper, linen, halftone, smooth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .grain: "Film Grain"
        case .paper: "Paper"
        case .linen: "Linen"
        case .halftone: "Halftone"
        case .smooth: "Smooth"
        }
    }
}

enum BlockSize { case large, small }

/// A tile on the home grid: what it shows, where it sits and how many cells it spans.
struct Block: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: WidgetKind
    var col = -1
    var row = -1
    var w = 2
    var h = 2

    var size: BlockSize { w * h >= 8 ? .large : .small }
}

// Older saves have no grid position; they decode with col/row = -1 and get laid out fresh.
extension Block {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = try c.decode(WidgetKind.self, forKey: .kind)
        col = (try? c.decode(Int.self, forKey: .col)) ?? -1
        row = (try? c.decode(Int.self, forKey: .row)) ?? -1
        w = (try? c.decode(Int.self, forKey: .w)) ?? 2
        h = (try? c.decode(Int.self, forKey: .h)) ?? 2
    }
}

/// iPad-style widget sizes, in grid cells.
enum TileShape: String, CaseIterable, Identifiable {
    case mini, small, wide, tall, large
    var id: String { rawValue }
    var cells: (w: Int, h: Int) {
        switch self {
        case .mini: (1, 1)
        case .small: (2, 2)
        case .wide: (4, 2)
        case .tall: (2, 4)
        case .large: (4, 4)
        }
    }
    var title: String {
        switch self {
        case .mini: "Mini"
        case .small: "Small"
        case .wide: "Wide"
        case .tall: "Tall"
        case .large: "Large"
        }
    }
    var symbol: String {
        switch self {
        case .mini: "square.dashed"
        case .small: "square"
        case .wide: "rectangle"
        case .tall: "rectangle.portrait"
        case .large: "square.grid.2x2"
        }
    }
}

/// The 6×4 home grid and the packing rules used while a tile is dragged or resized.
enum GridLayout {
    static let cols = 6, rows = 4

    static func fits(_ b: Block) -> Bool {
        b.col >= 0 && b.row >= 0 && b.col + b.w <= cols && b.row + b.h <= rows
    }

    /// Puts `pinned` where it is, leaves every other tile in place unless it collides, and moves
    /// colliders to the nearest free spot after their old position (reading order), like iPad widgets.
    /// Returns nil when everything can't fit.
    static func reflow(_ blocks: [Block], pinned: Int) -> [Block]? {
        var result = blocks
        var grid = [[Bool]](repeating: [Bool](repeating: false, count: cols), count: rows)
        func free(_ b: Block) -> Bool {
            for r in b.row..<(b.row + b.h) { for c in b.col..<(b.col + b.w) where grid[r][c] { return false } }
            return true
        }
        func mark(_ b: Block) {
            for r in b.row..<(b.row + b.h) { for c in b.col..<(b.col + b.w) { grid[r][c] = true } }
        }

        guard result.indices.contains(pinned), fits(result[pinned]) else { return nil }
        mark(result[pinned])

        let others = result.indices.filter { $0 != pinned }
            .sorted { (result[$0].row, result[$0].col) < (result[$1].row, result[$1].col) }
        var displaced: [Int] = []
        for i in others {
            if fits(result[i]) && free(result[i]) { mark(result[i]) } else { displaced.append(i) }
        }

        let cells = (0..<rows).flatMap { r in (0..<cols).map { c in (r, c) } }
        var stuck = false
        for i in displaced {
            let start = cells.firstIndex { $0.0 == max(0, result[i].row) && $0.1 == max(0, result[i].col) } ?? 0
            var placed = false
            for k in 0..<cells.count {
                var b = result[i]
                (b.row, b.col) = cells[(start + k) % cells.count]
                if fits(b) && free(b) {
                    result[i] = b
                    mark(b)
                    placed = true
                    break
                }
            }
            if !placed { stuck = true; break }
        }
        if !stuck { return result }

        // No room to just nudge the colliders: repack everyone else around the pinned tile, keeping
        // their reading order (bigger tiles first so they get the space they need).
        result = blocks
        grid = [[Bool]](repeating: [Bool](repeating: false, count: cols), count: rows)
        mark(result[pinned])
        let order = others.sorted { (result[$0].w * result[$0].h, -result[$0].row, -result[$0].col) > (result[$1].w * result[$1].h, -result[$1].row, -result[$1].col) }
        for i in order {
            var placed = false
            for (r, c) in cells {
                var b = result[i]
                b.row = r; b.col = c
                if fits(b) && free(b) { result[i] = b; mark(b); placed = true; break }
            }
            if !placed { return nil }
        }
        return result
    }

    /// The first free spot (reading order) for a tile of this size, or nil when the page is full.
    static func freeSpot(in blocks: [Block], w: Int, h: Int) -> (col: Int, row: Int)? {
        var grid = [[Bool]](repeating: [Bool](repeating: false, count: cols), count: rows)
        for b in blocks where fits(b) {
            for r in b.row..<(b.row + b.h) { for c in b.col..<(b.col + b.w) { grid[r][c] = true } }
        }
        guard w <= cols, h <= rows else { return nil }
        for r in 0...(rows - h) {
            for c in 0...(cols - w) {
                var free = true
                for rr in r..<(r + h) { for cc in c..<(c + w) where grid[rr][cc] { free = false } }
                if free { return (c, r) }
            }
        }
        return nil
    }

    /// Makes any saved layout valid: unplaced or overlapping tiles are packed into free space,
    /// falling back to the default arrangement.
    static func normalize(_ blocks: [Block]) -> [Block] {
        guard !blocks.isEmpty else { return Config.defaultBlocks }
        var b = blocks
        for i in b.indices {
            b[i].w = min(cols, max(1, b[i].w)); b[i].h = min(rows, max(1, b[i].h))
        }
        if let first = b.indices.first(where: { fits(b[$0]) }), let packed = reflow(b, pinned: first) { return packed }
        let defaults = Config.defaultBlocks
        return b.enumerated().map { i, block in
            var d = defaults[i % defaults.count]
            d.id = block.id
            d.kind = block.kind
            return d
        }
    }
}

struct WorldCity: Codable, Equatable, Hashable, Identifiable {
    var name: String
    var tz: String
    var id: String { name + "|" + tz }

    static let popular: [WorldCity] = [
        WorldCity(name: "Mumbai", tz: "Asia/Kolkata"), WorldCity(name: "Dubai", tz: "Asia/Dubai"),
        WorldCity(name: "Singapore", tz: "Asia/Singapore"), WorldCity(name: "Tokyo", tz: "Asia/Tokyo"),
        WorldCity(name: "Sydney", tz: "Australia/Sydney"), WorldCity(name: "Hong Kong", tz: "Asia/Hong_Kong"),
        WorldCity(name: "Seoul", tz: "Asia/Seoul"), WorldCity(name: "London", tz: "Europe/London"),
        WorldCity(name: "Paris", tz: "Europe/Paris"), WorldCity(name: "Berlin", tz: "Europe/Berlin"),
        WorldCity(name: "New York", tz: "America/New_York"), WorldCity(name: "Toronto", tz: "America/Toronto"),
        WorldCity(name: "Cupertino", tz: "America/Los_Angeles"), WorldCity(name: "São Paulo", tz: "America/Sao_Paulo"),
    ]

    /// Searchable city names that aren't time-zone identifiers (macOS still files India under "Asia/Calcutta").
    static let extras: [WorldCity] = [
        ("Kolkata", "Asia/Kolkata"), ("Delhi", "Asia/Kolkata"), ("New Delhi", "Asia/Kolkata"), ("Bengaluru", "Asia/Kolkata"),
        ("Chennai", "Asia/Kolkata"), ("Hyderabad", "Asia/Kolkata"), ("Pune", "Asia/Kolkata"), ("Ahmedabad", "Asia/Kolkata"),
        ("Jaipur", "Asia/Kolkata"), ("Kochi", "Asia/Kolkata"), ("Visakhapatnam", "Asia/Kolkata"), ("Vijayawada", "Asia/Kolkata"),
        ("Abu Dhabi", "Asia/Dubai"), ("Doha", "Asia/Qatar"), ("Riyadh", "Asia/Riyadh"), ("Beijing", "Asia/Shanghai"),
        ("Shenzhen", "Asia/Shanghai"), ("Ho Chi Minh City", "Asia/Ho_Chi_Minh"), ("Kuala Lumpur", "Asia/Kuala_Lumpur"),
        ("Melbourne", "Australia/Melbourne"), ("Auckland", "Pacific/Auckland"), ("Los Angeles", "America/Los_Angeles"),
        ("San Francisco", "America/Los_Angeles"), ("Seattle", "America/Los_Angeles"), ("Chicago", "America/Chicago"),
        ("Dallas", "America/Chicago"), ("Austin", "America/Chicago"), ("Denver", "America/Denver"),
        ("Washington DC", "America/New_York"), ("Boston", "America/New_York"), ("Miami", "America/New_York"),
        ("Vancouver", "America/Vancouver"), ("Mexico City", "America/Mexico_City"), ("Amsterdam", "Europe/Amsterdam"),
        ("Madrid", "Europe/Madrid"), ("Rome", "Europe/Rome"), ("Zurich", "Europe/Zurich"), ("Dublin", "Europe/Dublin"),
        ("Istanbul", "Europe/Istanbul"), ("Moscow", "Europe/Moscow"), ("Cairo", "Africa/Cairo"), ("Lagos", "Africa/Lagos"),
        ("Nairobi", "Africa/Nairobi"), ("Johannesburg", "Africa/Johannesburg"), ("Honolulu", "Pacific/Honolulu"),
    ].map { WorldCity(name: $0.0, tz: $0.1) }

    /// "America/Argentina/Buenos_Aires" → "Buenos Aires"
    static func cityName(for tz: String) -> String {
        (tz.split(separator: "/").last.map(String.init) ?? tz).replacingOccurrences(of: "_", with: " ")
    }

    static func region(for tz: String) -> String {
        tz.split(separator: "/").first.map(String.init) ?? ""
    }
}

enum ClockFont: String, CaseIterable, Codable {
    case rounded, classic, thin, heavy, serif, mono, condensed, expanded, didot, futura, avenir

    var title: String {
        switch self {
        case .rounded: "Rounded"
        case .classic: "Classic"
        case .thin: "Thin"
        case .heavy: "Heavy"
        case .serif: "New York"
        case .mono: "Mono"
        case .condensed: "Condensed"
        case .expanded: "Expanded"
        case .didot: "Didot"
        case .futura: "Futura"
        case .avenir: "Avenir"
        }
    }

    func font(_ size: CGFloat) -> Font {
        switch self {
        case .rounded: .system(size: size, weight: .semibold, design: .rounded)
        case .classic: .system(size: size, weight: .medium)
        case .thin: .system(size: size, weight: .thin)
        case .heavy: .system(size: size, weight: .black, design: .rounded)
        case .serif: .system(size: size, weight: .semibold, design: .serif)
        case .mono: .system(size: size, weight: .regular, design: .monospaced)
        case .condensed: .system(size: size, weight: .bold).width(.compressed)
        case .expanded: .system(size: size, weight: .heavy).width(.expanded)
        case .didot: .custom("Didot", size: size)
        case .futura: .custom("Futura-Medium", size: size)
        case .avenir: .custom("AvenirNext-UltraLight", size: size)
        }
    }

    /// Approximate digit width as a fraction of the point size — used to fit the time to the screen.
    var widthFactor: CGFloat {
        switch self {
        case .condensed: 0.42
        case .expanded: 0.86
        case .heavy: 0.7
        case .thin, .didot, .avenir: 0.58
        default: 0.62
        }
    }

    /// Display sizes want tighter tracking; how much depends on the face.
    var tracking: CGFloat {
        switch self {
        case .rounded, .heavy: -0.045
        case .classic, .expanded: -0.035
        case .thin, .serif, .futura: -0.025
        case .mono: -0.02
        case .condensed, .didot, .avenir: -0.01
        }
    }

    func step(_ delta: Int) -> ClockFont {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + delta + all.count) % all.count]
    }
}

/// When Idle Mode holds the display awake. Otherwise the Mac's own display-sleep setting applies.
enum KeepAwakeMode: String, Codable, CaseIterable, Identifiable {
    case chargingOrExternal, chargingAndExternal, always, never
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chargingOrExternal: "Plugged in or external display"
        case .chargingAndExternal: "Plugged in and external display"
        case .always: "Always while open"
        case .never: "Never (use Mac settings)"
        }
    }
}

struct Config: Codable, Equatable {
    var blocks: [Block] = Config.defaultBlocks
    var paletteID = "dusk"
    var texture: TextureKind = .grain
    var textureAmount = 0.55
    var motion = 0.6
    var interactive = true
    var use24h = false
    var showSeconds = false
    var note = "Tap to write a note…"
    var clockFont: ClockFont = .rounded
    var worldCities: [WorldCity] = Config.defaultCities
    var backgroundPhoto: String?
    var usePhoto = false
    var photoBlur = 0.0
    var glassTint = 0.35          // 0 = clear Liquid Glass, 1 = tinted
    var keepAwake: KeepAwakeMode = .chargingOrExternal
    /// The Redirect tile's four app shortcuts (paths to .app bundles; "" = empty slot).
    var redirectApps: [String] = ["", "", "", ""]
    var redirectIconStyle: AppIconStyle = .theme
    /// How many shortcuts the Redirect tile shows (1–4). Hidden slots keep their app for later.
    var redirectCount = 4

    static let defaultBlocks: [Block] = [
        Block(kind: .clock, col: 0, row: 0, w: 2, h: 4),
        Block(kind: .nowPlaying, col: 2, row: 0, w: 2, h: 2),
        Block(kind: .calendar, col: 4, row: 0, w: 2, h: 2),
        Block(kind: .analog, col: 2, row: 2, w: 2, h: 2),
        Block(kind: .timer, col: 4, row: 2, w: 2, h: 2),
    ]

    static let defaultCities: [WorldCity] = [
        WorldCity(name: "Cupertino", tz: "America/Los_Angeles"), WorldCity(name: "New York", tz: "America/New_York"),
        WorldCity(name: "London", tz: "Europe/London"), WorldCity(name: "Tokyo", tz: "Asia/Tokyo"),
    ]
}

// Decodes field by field so settings saved by an older version (missing new keys) keep everything else.
extension Config {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        blocks = (try? c.decode([Block].self, forKey: .blocks)) ?? d.blocks
        paletteID = (try? c.decode(String.self, forKey: .paletteID)) ?? d.paletteID
        texture = (try? c.decode(TextureKind.self, forKey: .texture)) ?? d.texture
        textureAmount = (try? c.decode(Double.self, forKey: .textureAmount)) ?? d.textureAmount
        motion = (try? c.decode(Double.self, forKey: .motion)) ?? d.motion
        interactive = (try? c.decode(Bool.self, forKey: .interactive)) ?? d.interactive
        use24h = (try? c.decode(Bool.self, forKey: .use24h)) ?? d.use24h
        showSeconds = (try? c.decode(Bool.self, forKey: .showSeconds)) ?? d.showSeconds
        note = (try? c.decode(String.self, forKey: .note)) ?? d.note
        clockFont = (try? c.decode(ClockFont.self, forKey: .clockFont)) ?? d.clockFont
        worldCities = (try? c.decode([WorldCity].self, forKey: .worldCities)) ?? d.worldCities
        backgroundPhoto = try? c.decode(String.self, forKey: .backgroundPhoto)
        usePhoto = (try? c.decode(Bool.self, forKey: .usePhoto)) ?? d.usePhoto
        photoBlur = (try? c.decode(Double.self, forKey: .photoBlur)) ?? d.photoBlur
        glassTint = (try? c.decode(Double.self, forKey: .glassTint)) ?? d.glassTint
        keepAwake = (try? c.decode(KeepAwakeMode.self, forKey: .keepAwake)) ?? d.keepAwake
        redirectApps = (try? c.decode([String].self, forKey: .redirectApps)) ?? d.redirectApps
        redirectIconStyle = (try? c.decode(AppIconStyle.self, forKey: .redirectIconStyle)) ?? d.redirectIconStyle
        redirectCount = min(4, max(1, (try? c.decode(Int.self, forKey: .redirectCount)) ?? d.redirectCount))
    }
}

// MARK: - Settings from the StandBy days

/// Version 2.2 renamed StandBy to Idle Mode and changed the bundle ID, which gives the app a fresh, empty
/// preferences file. On the first launch, copy the old settings (blocks, theme, cities, last media…) across.
/// The keys keep their "standby." prefix, so nothing else has to change.
enum LegacySettings {
    private static let oldDomain = "com.varsh.standby"
    private static let doneKey = "idlemode.migratedFromStandBy"

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != oldDomain, !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        guard let old = defaults.persistentDomain(forName: oldDomain) else { return }
        for (key, value) in old where key.hasPrefix("standby.") && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}

// MARK: - Settings store

@MainActor
final class AppSettings: ObservableObject {
    @Published var config: Config { didSet { save() } }
    /// The imported background photo, downscaled to screen size, and the colours pulled from it.
    @Published private(set) var photo: NSImage?
    @Published private(set) var photoPalette: [RGB]?
    private static let key = "standby.config.v2"

    init() {
        LegacySettings.migrateIfNeeded()
        if let data = UserDefaults.standard.data(forKey: Self.key),
           var c = try? JSONDecoder().decode(Config.self, from: data) {
            c.blocks = GridLayout.normalize(c.blocks)
            config = c
        } else {
            config = Config()
        }
        loadPhoto()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    var isAdaptive: Bool { config.paletteID == Palette.adaptiveID }
    var showsPhoto: Bool { config.usePhoto && photo != nil }

    func colors(adaptive: [RGB]?) -> [RGB] {
        if showsPhoto, let photoPalette { return photoPalette }
        if isAdaptive { return adaptive ?? Palette.presets[0].colors }
        return Palette.preset(config.paletteID).colors
    }

    func accent(adaptive: [RGB]?) -> RGB {
        if showsPhoto, let photoPalette { return photoPalette[3] }
        if isAdaptive { return adaptive?[3] ?? Palette.presets[0].accent }
        return Palette.preset(config.paletteID).accent
    }

    func swap(_ a: Int, _ b: Int) {
        guard a != b, config.blocks.indices.contains(a), config.blocks.indices.contains(b) else { return }
        config.blocks.swapAt(a, b)
    }

    func setKind(_ kind: WidgetKind, at i: Int) {
        guard config.blocks.indices.contains(i) else { return }
        config.blocks[i].kind = kind
    }

    func resetLayout() { config.blocks = Config.defaultBlocks.map { var b = $0; b.id = UUID(); return b } }

    /// Where a new tile would go: a Small (2×2) if there's room, otherwise a Mini (1×1); nil when the page is full.
    var newTileSlot: Block? {
        for shape in [TileShape.small, .mini] {
            if let spot = GridLayout.freeSpot(in: config.blocks, w: shape.cells.w, h: shape.cells.h) {
                return Block(kind: .clock, col: spot.col, row: spot.row, w: shape.cells.w, h: shape.cells.h)
            }
        }
        return nil
    }

    func addTile(_ kind: WidgetKind) {
        guard var b = newTileSlot else { return }
        b.kind = kind
        config.blocks.append(b)
    }

    /// Removes a tile, always leaving at least one on the page.
    func removeTile(at index: Int) {
        guard config.blocks.count > 1, config.blocks.indices.contains(index) else { return }
        config.blocks.remove(at: index)
    }

    // MARK: Redirect shortcuts

    /// The app in a Redirect slot, if one is set and still installed.
    func redirectPath(_ slot: Int) -> String? {
        let apps = config.redirectApps
        guard apps.indices.contains(slot), !apps[slot].isEmpty, FileManager.default.fileExists(atPath: apps[slot]) else { return nil }
        return apps[slot]
    }

    func setRedirectApp(slot: Int, path: String?) {
        var apps = config.redirectApps
        while apps.count < 4 { apps.append("") }
        guard apps.indices.contains(slot) else { return }
        apps[slot] = path ?? ""
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { config.redirectApps = apps }
    }

    func chooseRedirectApp(slot: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose an app for Redirect shortcut \(slot + 1)"
        if panel.runModal() == .OK, let url = panel.url { setRedirectApp(slot: slot, path: url.path) }
    }

    static func appName(_ path: String) -> String {
        let n = FileManager.default.displayName(atPath: path)
        return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
    }

    /// Whether a size fits as-is, only fits if the other tiles shrink to Mini, or can't fit at all.
    enum ResizeFit { case fits, shrinksOthers, noRoom }

    func fit(_ index: Int, to shape: TileShape) -> ResizeFit {
        if resized(index, to: shape, shrinkOthers: false) != nil { return .fits }
        if resized(index, to: shape, shrinkOthers: true) != nil { return .shrinksOthers }
        return .noRoom
    }

    /// Changes a tile's size, nudging it back on-grid and moving neighbours out of the way. If there's no
    /// room (a 4×4 tile next to four 2×2s, say), the other tiles shrink to Mini to make space.
    /// Returns false (and changes nothing) when the new size can't fit even then.
    @discardableResult
    func resize(_ index: Int, to shape: TileShape) -> Bool {
        guard let packed = resized(index, to: shape, shrinkOthers: false)
                ?? resized(index, to: shape, shrinkOthers: true) else { return false }
        config.blocks = packed
        return true
    }

    private func resized(_ index: Int, to shape: TileShape, shrinkOthers: Bool) -> [Block]? {
        guard config.blocks.indices.contains(index) else { return nil }
        var b = config.blocks
        b[index].w = shape.cells.w
        b[index].h = shape.cells.h
        b[index].col = min(max(0, b[index].col), GridLayout.cols - b[index].w)
        b[index].row = min(max(0, b[index].row), GridLayout.rows - b[index].h)
        if shrinkOthers {
            for i in b.indices where i != index { b[i].w = 1; b[i].h = 1 }
        }
        return GridLayout.reflow(b, pinned: index)
    }

    func toggleCity(_ city: WorldCity) {
        if let i = config.worldCities.firstIndex(where: { $0.tz == city.tz && $0.name == city.name }) {
            config.worldCities.remove(at: i)
        } else if config.worldCities.count < 10 {
            config.worldCities.append(city)
        }
    }

    func removeCity(_ city: WorldCity) { config.worldCities.removeAll { $0 == city } }

    // MARK: Background photo

    private static var photoDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("StandBy", isDirectory: true)
    }

    /// Copies the chosen image into Application Support so it survives the original being moved or deleted.
    func importPhoto(from url: URL) {
        let dir = Self.photoDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let dest = dir.appendingPathComponent("Background-\(Int(Date().timeIntervalSince1970)).\(ext)")
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            NSSound.beep()
            return
        }
        if let old = config.backgroundPhoto, old != dest.path { try? FileManager.default.removeItem(atPath: old) }
        config.backgroundPhoto = dest.path
        config.usePhoto = true
        loadPhoto()
    }

    func removePhoto() {
        if let old = config.backgroundPhoto { try? FileManager.default.removeItem(atPath: old) }
        config.backgroundPhoto = nil
        config.usePhoto = false
        photo = nil
        photoPalette = nil
        photoSource = nil
    }

    private func loadPhoto() {
        guard let path = config.backgroundPhoto else { return }
        let url = URL(fileURLWithPath: path)
        let blur = config.photoBlur
        Task.detached(priority: .userInitiated) {
            guard let cg = Self.downscaled(url, maxPixels: 3200) else { return }
            let original = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            let palette = ArtPalette.extract(original)
            let shown = Self.blurred(cg, amount: blur)
            await MainActor.run {
                self.photoSource = cg
                withAnimation(.easeInOut(duration: 0.8)) {
                    self.photo = shown
                    self.photoPalette = palette
                }
            }
        }
    }

    /// 0…1. The blurred copy is rendered once off the main thread, never per frame.
    func setPhotoBlur(_ amount: Double) {
        config.photoBlur = min(1, max(0, amount))
        guard let cg = photoSource else { return }
        blurGeneration += 1
        let generation = blurGeneration
        let value = config.photoBlur
        Task.detached(priority: .userInitiated) {
            let image = Self.blurred(cg, amount: value)
            await MainActor.run {
                guard generation == self.blurGeneration else { return }
                withAnimation(.easeInOut(duration: 0.35)) { self.photo = image }
            }
        }
    }

    private var photoSource: CGImage?
    private var blurGeneration = 0

    nonisolated private static func blurred(_ cg: CGImage, amount: Double) -> NSImage {
        let size = NSSize(width: cg.width, height: cg.height)
        guard amount > 0.005 else { return NSImage(cgImage: cg, size: size) }
        let input = CIImage(cgImage: cg)
        // 100% ≈ a sigma of 1.6% of the long side; 50% is a soft frost that keeps shapes readable.
        let sigma = amount * Double(max(cg.width, cg.height)) * 0.016
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        guard let result = CIContext().createCGImage(output, from: input.extent) else { return NSImage(cgImage: cg, size: size) }
        return NSImage(cgImage: result, size: size)
    }

    nonisolated private static func downscaled(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Never ask for more pixels than the photo has; ImageIO logs an error when we do.
        var limit = maxPixels
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int, max(w, h) > 0 {
            limit = min(maxPixels, max(w, h))
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

// MARK: - Pager
//
// Paging runs in Core Animation, never through SwiftUI state. While dragging, only the container
// layer's sublayerTransform changes — no view frames move, so AppKit and SwiftUI do no layout or
// tracking-area work per event. Settling is a CASpringAnimation on that same transform, run by the
// render server at the display's refresh rate. Every animation starts from the on-screen
// (presentation) value and can be grabbed again mid-flight.

@MainActor
final class PagerController {
    weak var container: NSView?         // its layer's sublayerTransform carries the live offset
    weak var content: NSView?           // the wide strip of pages; its frame moves only once per page change
    var onPageChange: ((Int) -> Void)?
    var onPagingChange: ((Bool) -> Void)?
    private(set) var page = 0
    private(set) var width: CGFloat = 1
    private var token = 0

    private var restX: CGFloat { -CGFloat(page) * width }

    func layout(width w: CGFloat) {
        guard abs(w - width) > 0.5 || content?.frame.origin.x != restX else { return }
        width = max(1, w)
        container?.layer?.removeAnimation(forKey: "page")
        commit(translation: 0)
    }

    private func commit(translation: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content?.setFrameOrigin(NSPoint(x: restX, y: 0))
        container?.layer?.sublayerTransform = CATransform3DMakeTranslation(translation, 0, 0)
        CATransaction.commit()
    }

    /// Translation currently on screen, including any spring in flight.
    private var liveTranslation: CGFloat {
        guard let layer = container?.layer else { return 0 }
        if layer.animation(forKey: "page") != nil, let p = layer.presentation() { return p.sublayerTransform.m41 }
        return layer.sublayerTransform.m41
    }

    /// Catches the pages exactly where they are on screen; returns the offset from the nearest page.
    @discardableResult
    func grab() -> CGFloat {
        let x = restX + liveTranslation
        container?.layer?.removeAnimation(forKey: "page")
        token += 1
        page = min(UIState.pageCount - 1, max(0, Int((-x / width).rounded())))
        let offset = x - restX
        commit(translation: offset)
        onPagingChange?(true)
        return offset
    }

    func setOffset(_ o: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container?.layer?.sublayerTransform = CATransform3DMakeTranslation(o, 0, 0)
        CATransaction.commit()
    }

    func settle(to target: Int, velocity: CGFloat = 0) {
        let visualX = restX + liveTranslation
        container?.layer?.removeAnimation(forKey: "page")
        page = min(UIState.pageCount - 1, max(0, target))
        let delta = visualX - restX
        commit(translation: 0)
        onPageChange?(page)

        guard let layer = container?.layer, abs(delta) > 0.5 else { onPagingChange?(false); return }
        onPagingChange?(true)
        token += 1
        let mine = token

        let spring = CASpringAnimation(perceptualDuration: 0.42, bounce: 0)
        spring.keyPath = "sublayerTransform.translation.x"
        spring.isAdditive = true
        spring.fromValue = delta
        spring.toValue = 0
        // Hand the finger's speed to the spring, normalised by the distance left to travel.
        spring.initialVelocity = max(-60, min(60, -velocity / delta))
        spring.duration = spring.settlingDuration
        // Ask for the display's top rate (120 Hz on ProMotion) rather than letting the system throttle.
        spring.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.token == mine else { return }
                self.onPagingChange?(false)
            }
        }
        layer.add(spring, forKey: "page")
        CATransaction.commit()
    }
}

// MARK: - UI state

@MainActor
final class UIState: ObservableObject {
    static let pageCount = 3

    @Published private(set) var page = 0
    @Published var editing = false
    @Published var showCustomize = false
    @Published var chromeVisible = true
    @Published var fontDirection = 1
    @Published var fontToastID = 0
    /// True while pages are being dragged or are settling; the background pauses so the main thread stays free.
    @Published private(set) var paging = false
    let pager = PagerController()
    private var hideWork: DispatchWorkItem?

    init() {
        pager.onPageChange = { [weak self] p in
            guard let self, self.page != p else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 1)) { self.page = p }
        }
        pager.onPagingChange = { [weak self] on in
            guard let self, self.paging != on else { return }
            self.paging = on
        }
    }

    /// Any pointer activity reveals the floating controls; they fade away again when idle.
    func poke() {
        if !chromeVisible { withAnimation(.easeOut(duration: 0.25)) { chromeVisible = true } }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.idle() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    private func idle() {
        guard !editing, !showCustomize else { return }
        withAnimation(.easeInOut(duration: 0.6)) { chromeVisible = false }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func go(_ delta: Int) { jump(to: page + delta) }

    func jump(to p: Int) {
        guard !editing else { return }
        pager.settle(to: min(Self.pageCount - 1, max(0, p)))
    }

    func toggleEditing() {
        if !editing { jump(to: 0) }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            editing.toggle()
            showCustomize = false
        }
        poke()
    }

    func toggleCustomize() {
        let opening = !showCustomize
        holdBackground(for: opening ? 0.5 : 0.35)
        // Critically damped (no bounce: nothing was flicked); closing is a touch quicker than opening.
        withAnimation(.spring(response: opening ? 0.4 : 0.3, dampingFraction: 1)) { showCustomize.toggle() }
        poke()
    }

    /// Pauses the animated background for the length of a UI transition so every frame of the
    /// transition gets the full refresh budget.
    @Published private(set) var transitioning = false
    private var transitionWork: DispatchWorkItem?

    func holdBackground(for seconds: Double) {
        transitionWork?.cancel()
        if !transitioning { transitioning = true }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.transitioning = false } }
        transitionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func closeAll() {
        holdBackground(for: 0.35)
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
            showCustomize = false
            editing = false
        }
        poke()
    }

    func cycleFont(_ settings: AppSettings, _ delta: Int) {
        fontDirection = delta
        withAnimation(.spring(response: 0.45, dampingFraction: 1)) {
            settings.config.clockFont = settings.config.clockFont.step(delta)
            fontToastID += 1
        }
        poke()
    }

    // MARK: Trackpad paging
    //
    // Tracks the fingers 1:1, rubber-bands past the first/last page, and on release projects
    // the flick's momentum to choose a page, then hands the release velocity to the spring.

    private var tracking = false
    private var axis = 0               // 0 undecided, 1 horizontal, 2 vertical
    private var accum = CGSize.zero
    private var start: CGFloat = 0
    private var raw: CGFloat = 0
    private var samples: [(t: Double, x: CGFloat)] = []
    private var swallowMomentum = false
    private var wheelCooldown = Date.distantPast

    /// Returns true when the event was used for paging (and should not reach other views).
    func handleScroll(_ e: NSEvent) -> Bool {
        guard !editing, !showCustomize else { return false }
        if !e.momentumPhase.isEmpty { return swallowMomentum }

        // Classic mouse wheel tilt: one page per notch.
        if e.phase.isEmpty {
            if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY), abs(e.scrollingDeltaX) > 3, Date() > wheelCooldown {
                go(e.scrollingDeltaX > 0 ? -1 : 1)
                wheelCooldown = Date().addingTimeInterval(0.4)
                return true
            }
            return false
        }

        if e.phase.contains(.began) {
            tracking = true; axis = 0; accum = .zero; samples = []; swallowMomentum = false
        }
        guard tracking else { return false }

        if e.phase.contains(.began) || e.phase.contains(.changed) {
            if axis == 0 {
                accum.width += e.scrollingDeltaX
                accum.height += e.scrollingDeltaY
                guard hypot(accum.width, accum.height) > 4 else { return false }
                axis = abs(accum.width) > abs(accum.height) * 1.1 ? 1 : 2
                guard axis == 1 else { return false }
                start = pager.grab()           // catch a page that's still settling
                raw = accum.width
            } else if axis == 1 {
                raw += e.scrollingDeltaX
            } else {
                return false
            }
            pager.setOffset(rubberBanded(start + raw))
            let now = e.timestamp
            samples.append((now, raw))
            samples.removeAll { now - $0.t > 0.08 }
            return true
        }

        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            tracking = false
            guard axis == 1 else { return false }
            swallowMomentum = true
            var velocity: CGFloat = 0
            if let first = samples.first, let last = samples.last, last.t - first.t > 0.005 {
                velocity = (last.x - first.x) / CGFloat(last.t - first.t)
            }
            finish(velocity: velocity)
            poke()
            return true
        }
        return false
    }

    private func rubberBanded(_ o: CGFloat) -> CGFloat {
        let w = pager.width
        func band(_ x: CGFloat) -> CGFloat { (x * w * 0.55) / (w + 0.55 * x) }
        if pager.page == 0 && o > 0 { return band(o) }
        if pager.page == Self.pageCount - 1 && o < 0 { return -band(-o) }
        return o
    }

    private func finish(velocity v: CGFloat) {
        let w = pager.width
        let current = -CGFloat(pager.page) * w + rubberBanded(start + raw)
        let decel: CGFloat = 0.998
        let projected = current + (v / 1000) * decel / (1 - decel)
        var target = Int((-projected / w).rounded())
        target = min(pager.page + 1, max(pager.page - 1, target))
        pager.settle(to: target, velocity: v)
    }
}

// MARK: - Timer

/// The five things you can change on the timer tile.
struct TimerStyle: Codable, Equatable {
    enum Face: String, Codable, CaseIterable { case pulse, tide, halo }
    enum Hue: String, Codable, CaseIterable { case theme, ember, ocean, mint, violet }
    enum Rhythm: String, Codable, CaseIterable { case heartbeat, breathe, still }
    enum Sound: String, Codable, CaseIterable { case alarm, chime, silent }
    enum Cycle: String, Codable, CaseIterable { case once, focusBreak }

    var face = Face.pulse
    var hue = Hue.theme
    var rhythm = Rhythm.heartbeat
    var sound = Sound.alarm
    var cycle = Cycle.once
}

extension CaseIterable where Self: Equatable, AllCases.Index == Int {
    /// The next option, wrapping round: what a "tap to cycle" button switches to.
    var next: Self {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}

@MainActor
final class FocusTimer: ObservableObject {
    private static let key = "standby.focusMinutes"
    private static let styleKey = "standby.timerStyle.v1"

    enum Phase { case focus, rest }

    @Published var style: TimerStyle {
        didSet { if let d = try? JSONEncoder().encode(style) { UserDefaults.standard.set(d, forKey: Self.styleKey) } }
    }
    /// With the focus/break cycle on, alternates focus and a short break without stopping.
    @Published private(set) var phase = Phase.focus
    private var focusLength: TimeInterval

    @Published private(set) var total: TimeInterval
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval
    @Published private(set) var ringing = false
    @Published private(set) var ringStarted = Date()
    private var finishTimer: Timer?
    private var autoStop: Timer?
    private var sound: NSSound?

    init() {
        LegacySettings.migrateIfNeeded()
        let saved = UserDefaults.standard.double(forKey: Self.key)
        let seconds = (saved > 0 ? saved : 25) * 60
        total = seconds
        pausedRemaining = seconds
        focusLength = seconds
        if let d = UserDefaults.standard.data(forKey: Self.styleKey), let s = try? JSONDecoder().decode(TimerStyle.self, from: d) {
            style = s
        } else {
            style = TimerStyle()
        }
    }

    /// Break length for the focus/break cycle: a fifth of the focus time, at least 5 minutes.
    var breakMinutes: Int { max(5, Int((focusLength / 60 / 5).rounded())) }

    var running: Bool { endDate != nil }
    var minutes: Int { Int((total / 60).rounded()) }

    func remaining(at date: Date) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(date)) }
        return pausedRemaining
    }

    /// Sets a new length (1–180 minutes) and resets the countdown to it.
    func set(minutes: Double, start: Bool = false) {
        let m = max(1, min(180, minutes.rounded()))
        UserDefaults.standard.set(m, forKey: Self.key)
        finishTimer?.invalidate()
        endDate = nil
        total = m * 60
        focusLength = total
        phase = .focus
        pausedRemaining = total
        if start { toggle() }
    }

    func toggle() {
        if let endDate {
            pausedRemaining = max(0, endDate.timeIntervalSinceNow)
            self.endDate = nil
            finishTimer?.invalidate()
        } else {
            if pausedRemaining <= 0 { pausedRemaining = total }
            start(for: pausedRemaining)
        }
    }

    func reset() {
        finishTimer?.invalidate()
        endDate = nil
        if phase == .rest {
            phase = .focus
            total = focusLength
        }
        pausedRemaining = total
    }

    func add(minutes: Double) {
        let delta = minutes * 60
        total = min(total + delta, 3 * 3600)
        if let endDate {
            start(for: endDate.timeIntervalSinceNow + delta)
        } else {
            pausedRemaining = min(pausedRemaining + delta, 3 * 3600)
        }
    }

    // MARK: Alarm

    /// With the focus/break cycle on, the phase that starts when the alarm is answered (or by itself after 20 s).
    @Published private(set) var nextPhase: Phase?
    private var autoContinue: Timer?

    var nextPhaseMinutes: Int { nextPhase == .rest ? breakMinutes : Int((focusLength / 60).rounded()) }

    func stopAlarm() {
        silence()
        withAnimation(.spring(response: 0.5, dampingFraction: 1)) {
            ringing = false
            if nextPhase != nil {
                nextPhase = nil
                phase = .focus
                total = focusLength
            }
        }
        pausedRemaining = total
        restoreWindow()
    }

    func snooze(minutes: Double = 5) {
        silence()
        withAnimation(.spring(response: 0.5, dampingFraction: 1)) { ringing = false; nextPhase = nil }
        start(for: minutes * 60)
        restoreWindow()
    }

    /// Focus/break cycle: start the next phase now.
    func continueCycle() {
        guard let next = nextPhase else { stopAlarm(); return }
        silence()
        withAnimation(.spring(response: 0.6, dampingFraction: 1)) {
            ringing = false
            nextPhase = nil
            phase = next
            total = next == .rest ? TimeInterval(breakMinutes * 60) : focusLength
        }
        start(for: total)
        restoreWindow()
    }

    private func start(for seconds: TimeInterval) {
        let end = Date().addingTimeInterval(max(1, seconds))
        endDate = end
        finishTimer?.invalidate()
        finishTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, end.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.ring() }
        }
    }

    private func ring() {
        endDate = nil
        pausedRemaining = 0
        ringStarted = Date()
        withAnimation(.spring(response: 0.6, dampingFraction: 1)) {
            nextPhase = style.cycle == .focusBreak ? (phase == .focus ? .rest : .focus) : nil
            ringing = true
        }
        switch style.sound {
        case .alarm: sound = AlarmSound.make()
        case .chime:
            sound = NSSound(named: "Glass")
            sound?.loops = true
        case .silent: sound = nil
        }
        sound?.play()
        presentWindow()
        // Don't ring forever if nobody's around; in the cycle, carry on into the next phase.
        autoStop?.invalidate()
        autoStop = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.silence() }
        }
        autoContinue?.invalidate()
        if nextPhase != nil {
            autoContinue = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
                Task { @MainActor in if self?.ringing == true { self?.continueCycle() } }
            }
        }
    }

    /// Asks for Idle Mode to come forward too (the alarm windows already cover every screen).
    private func presentWindow() {
        NSApp.unhide(nil)
        NSApp.activate()
    }

    private func restoreWindow() {}

    private func silence() {
        sound?.stop()
        sound = nil
        autoStop?.invalidate()
        autoContinue?.invalidate()
    }
}

/// A classic alarm-clock pattern — four bright beeps, a pause, repeat — synthesised as a looping WAV.
enum AlarmSound {
    static func make() -> NSSound? {
        let rate = 44_100.0
        var samples: [Int16] = []

        func tone(_ freq: Double, _ dur: Double, _ amp: Double) {
            let n = Int(rate * dur), fade = rate * 0.006
            for i in 0..<n {
                let t = Double(i) / rate
                let env = min(1, Double(i) / fade, Double(n - i) / fade)
                let v = (sin(2 * .pi * freq * t) + 0.3 * sin(2 * .pi * freq * 2 * t) + 0.12 * sin(2 * .pi * freq * 3 * t)) / 1.42
                samples.append(Int16(max(-1, min(1, v * amp * env)) * 32_000))
            }
        }
        func silence(_ dur: Double) { samples += [Int16](repeating: 0, count: Int(rate * dur)) }

        for _ in 0..<4 { tone(1_318.5, 0.1, 0.9); silence(0.06) }
        silence(0.5)

        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate) * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        samples.forEach { put($0) }

        let sound = NSSound(data: data)
        sound?.loops = true
        return sound
    }
}

// MARK: - Environment

private struct AccentKey: EnvironmentKey { static let defaultValue: Color = .orange }

extension EnvironmentValues {
    var accent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder func `if`<T: View>(_ condition: Bool, _ transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}
