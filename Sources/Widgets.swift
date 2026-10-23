import SwiftUI
import AppKit
import IOKit
import IOKit.ps
import CoreAudio
import IOBluetooth
import UniformTypeIdentifiers

// MARK: - Router

struct WidgetView: View {
    let kind: WidgetKind
    let size: BlockSize

    var body: some View {
        switch kind {
        case .clock: DigitalClockWidget(size: size)
        case .analog: AnalogClockWidget(size: size)
        case .calendar: CalendarWidget(size: size)
        case .nowPlaying: NowPlayingWidget(size: size)
        case .battery: BatteryWidget(size: size)
        case .timer: TimerWidget(size: size)
        case .worldClock: WorldClockWidget(size: size)
        case .system: SystemWidget(size: size)
        case .note: NoteWidget(size: size)
        case .redirect: RedirectWidget(size: size)
        }
    }
}

// MARK: - Shared pieces

struct WidgetHeader: View {
    let symbol: String
    let title: String
    var active = false
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: active)
            Text(title.uppercased())
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .tracking(0.9)
        .foregroundStyle(accent)
    }
}

struct Ring: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

/// Feedback on press, not on release — the label dips the instant the pointer goes down.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.9
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 1), value: configuration.isPressed)
    }
}

enum ClockFormat {
    static func parts(_ d: Date, use24h: Bool, seconds: Bool) -> (time: String, ampm: String?) {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: d)
        var h = c.hour ?? 0
        var ampm: String?
        if !use24h {
            ampm = h < 12 ? "AM" : "PM"
            h %= 12
            if h == 0 { h = 12 }
        }
        var s = use24h ? String(format: "%02d:%02d", h, c.minute ?? 0) : String(format: "%d:%02d", h, c.minute ?? 0)
        if seconds { s += String(format: ":%02d", c.second ?? 0) }
        return (s, ampm)
    }
}

func formatDuration(_ t: Double) -> String {
    let s = Int(max(0, t).rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Digital clock

/// Fills its block: tall blocks stack hours over minutes, wide ones run on one line — in the chosen clock font.
struct DigitalClockWidget: View {
    let size: BlockSize
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accent) private var accent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            GeometryReader { geo in
                let font = settings.config.clockFont
                let parts = ClockFormat.parts(ctx.date, use24h: settings.config.use24h, seconds: false)
                let pieces = parts.time.split(separator: ":").map(String.init)
                let header: CGFloat = 22
                let w = geo.size.width, h = max(1, geo.size.height - header)
                let stacked = h > w * 0.95 && pieces.count == 2

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(ctx.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased())
                        Spacer(minLength: 0)
                        if settings.config.showSeconds {
                            Text(String(format: ":%02d", Calendar.current.component(.second, from: ctx.date)))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        if let ampm = parts.ampm { Text(ampm) }
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(accent)
                    .frame(height: header, alignment: .top)

                    if stacked {
                        // Two lines of digits; each line's glyphs are ~0.74 of the point size tall.
                        let digits = CGFloat(max(pieces[0].count, pieces[1].count, 2))
                        let fs = min(h / 1.62, w / (digits * font.widthFactor))
                        VStack(spacing: -fs * 0.26) {
                            line(pieces[0], fs, font)
                            line(pieces[1], fs, font)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        let fs = min(h * 1.15, w / (CGFloat(max(parts.time.count, 4)) * font.widthFactor))
                        line(parts.time, fs, font)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 1), value: parts.time)
                .animation(.spring(response: 0.45, dampingFraction: 1), value: font)
            }
        }
    }

    private func line(_ text: String, _ fs: CGFloat, _ font: ClockFont) -> some View {
        Text(text)
            .font(font.font(fs))
            .monospacedDigit()
            .tracking(fs * font.tracking)
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .shadow(color: .black.opacity(0.2), radius: fs * 0.08, y: fs * 0.03)
    }
}

// MARK: - Analog clock

struct AnalogClockWidget: View {
    let size: BlockSize
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30)) { ctx in
            Canvas { g, sz in
                let d = min(sz.width, sz.height), r = d / 2
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                func pt(_ radius: Double, _ angle: Double) -> CGPoint {
                    CGPoint(x: c.x + sin(angle) * radius, y: c.y - cos(angle) * radius)
                }

                g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: d, height: d)), with: .color(.white.opacity(0.05)))
                for i in 0..<60 {
                    let a = Double(i) / 60 * 2 * .pi
                    let major = i % 5 == 0
                    var p = Path()
                    p.move(to: pt(r * 0.93, a))
                    p.addLine(to: pt(r * (major ? 0.82 : 0.88), a))
                    g.stroke(p, with: .color(.white.opacity(major ? 0.9 : 0.28)),
                             style: StrokeStyle(lineWidth: major ? max(2, r * 0.025) : 1, lineCap: .round))
                }

                let t = ctx.date.timeIntervalSince(Calendar.current.startOfDay(for: ctx.date))
                let secs = reduceMotion ? floor(t).truncatingRemainder(dividingBy: 60) : t.truncatingRemainder(dividingBy: 60)
                let mins = (t / 60).truncatingRemainder(dividingBy: 60)
                let hrs = (t / 3600).truncatingRemainder(dividingBy: 12)

                func hand(_ angle: Double, _ length: Double, _ width: Double, _ color: Color, tail: Double = 0.1) {
                    var p = Path()
                    p.move(to: pt(-r * tail, angle))
                    p.addLine(to: pt(r * length, angle))
                    g.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
                hand(hrs / 12 * 2 * .pi, 0.5, max(4, r * 0.06), .white)
                hand(mins / 60 * 2 * .pi, 0.74, max(3, r * 0.04), .white)
                hand(secs / 60 * 2 * .pi, 0.82, max(1.5, r * 0.015), accent, tail: 0.18)
                let dot = max(5, r * 0.05)
                g.fill(Path(ellipseIn: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2)), with: .color(accent))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Calendar

struct CalendarWidget: View {
    let size: BlockSize
    @Environment(\.accent) private var accent

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let date = ctx.date
            let cal = Calendar.current
            let today = cal.component(.day, from: date)
            let first = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
            let days = cal.range(of: .day, in: .month, for: date)?.count ?? 30
            let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
            let symbols = rotatedSymbols(cal)

            GeometryReader { geo in
                if geo.size.height < 230 {
                    // Mini tile: today's date, big, instead of an unreadable month grid.
                    VStack(alignment: .leading, spacing: 0) {
                        Text(date.formatted(.dateTime.weekday(.wide)).uppercased())
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .tracking(0.9)
                            .foregroundStyle(accent)
                        Text("\(today)")
                            .font(.system(size: min(geo.size.height * 0.62, geo.size.width * 0.55), weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .frame(maxHeight: .infinity, alignment: .leading)
                        Text(date.formatted(.dateTime.month(.wide).year()))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                monthGrid(date: date, today: today, days: days, lead: lead, symbols: symbols, size: geo.size)
                }
            }
        }
    }

    private func monthGrid(date: Date, today: Int, days: Int, lead: Int, symbols: [String], size: CGSize) -> some View {
        let cell = min(size.width / 7, (size.height - 30) / 7.2)
        let fs = cell * 0.42
        return VStack(alignment: .leading, spacing: cell * 0.12) {
            HStack(alignment: .firstTextBaseline) {
                Text(date.formatted(.dateTime.month(.wide)).uppercased())
                    .font(.system(size: max(11, fs * 0.85), weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(accent)
                Spacer()
                Text(date.formatted(.dateTime.year()))
                    .font(.system(size: max(11, fs * 0.8), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Grid(horizontalSpacing: 0, verticalSpacing: cell * 0.08) {
                GridRow {
                    ForEach(0..<7, id: \.self) { i in
                        Text(symbols[i])
                            .font(.system(size: fs * 0.8, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: cell)
                    }
                }
                let total = lead + days
                ForEach(0..<Int(ceil(Double(total) / 7)), id: \.self) { row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { col in
                            let n = row * 7 + col - lead + 1
                            if n >= 1 && n <= days {
                                Text("\(n)")
                                    .font(.system(size: fs, weight: n == today ? .bold : .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(n == today ? Color.black : .white.opacity(col == 0 || col == 6 ? 0.5 : 0.9))
                                    .frame(width: cell * 0.86, height: cell * 0.86)
                                    .background(Circle().fill(n == today ? accent : .clear))
                                    .frame(width: cell)
                            } else {
                                Color.clear.frame(width: cell, height: cell * 0.86)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rotatedSymbols(_ cal: Calendar) -> [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        let k = cal.firstWeekday - 1
        return Array(s[k...] + s[..<k])
    }
}

// MARK: - Now Playing

struct NowPlayingWidget: View {
    let size: BlockSize
    @EnvironmentObject private var np: NowPlayingService

    var body: some View {
        if let t = np.track {
            GeometryReader { geo in
                content(t, plan: Plan(size: geo.size))
            }
        } else {
            NowPlayingEmpty(compact: size == .small)
        }
    }

    /// Works out, for this exact tile size, which arrangement gives the artwork the most room: beside the title,
    /// above it, or (in wide tiles) full height on the left. The art and the title then grow to fill the tile
    /// instead of leaving empty space.
    struct Plan {
        enum Kind { case beside, stacked, wide }
        var kind: Kind
        var side: CGFloat
        var roomy: Bool
        var gap: CGFloat
        var titleSize: CGFloat
        var titleLines: Int

        init(size s: CGSize) {
            let w = s.width, h = s.height
            roomy = h >= 300 && w >= 320
            gap = roomy ? 16 : 10
            let tag: CGFloat = 14
            let controls: CGFloat = roomy ? 112 : 84      // progress + transport + volume
            let controlsWidth: CGFloat = 290               // the five transport buttons need this much
            let free = h - tag - controls - gap * 2        // height left for the artwork row

            let beside = min(free, w * 0.5)
            let stacked = min(w, free - (roomy ? 80 : 58) - gap)
            let wide = h >= 200 ? min(h, w - controlsWidth - 22) : 0

            if wide >= max(beside, stacked) * 1.1 {
                kind = .wide; side = wide
            } else if stacked >= beside * 1.15 {
                kind = .stacked; side = stacked
            } else {
                kind = .beside; side = beside
            }
            side = max(44, side)

            switch kind {
            case .beside:
                titleSize = min(30, max(15, side * 0.1)); titleLines = side > 140 ? 3 : 2
            case .stacked:
                titleSize = min(28, max(16, w * 0.055)); titleLines = 2
            case .wide:
                titleSize = min(30, max(17, side * 0.09)); titleLines = 3
            }
        }
    }

    @ViewBuilder
    private func content(_ t: MediaTrack, plan p: Plan) -> some View {
        switch p.kind {
        case .wide:
            HStack(spacing: 22) {
                ArtworkView(side: p.side)
                VStack(alignment: .leading, spacing: p.gap) {
                    NowPlayingTag(track: t)
                    Spacer(minLength: 0)
                    details(t, plan: p)
                    Spacer(minLength: 0)
                    controls(t, roomy: p.roomy)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .beside:
            VStack(alignment: .leading, spacing: p.gap) {
                NowPlayingTag(track: t)
                HStack(alignment: .center, spacing: p.roomy ? 20 : 12) {
                    ArtworkView(side: p.side)
                    details(t, plan: p)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                controls(t, roomy: p.roomy)
            }
        case .stacked:
            VStack(alignment: .leading, spacing: p.gap) {
                NowPlayingTag(track: t)
                ArtworkView(side: p.side)
                    .frame(maxWidth: .infinity)
                details(t, plan: p)
                Spacer(minLength: 0)
                controls(t, roomy: p.roomy)
            }
        }
    }

    private func details(_ t: MediaTrack, plan p: Plan) -> some View {
        VStack(alignment: .leading, spacing: p.titleSize * 0.18) {
            Text(t.title)
                .font(.system(size: p.titleSize, weight: .bold, design: .rounded))
                .tracking(-0.3)
                .lineLimit(p.titleLines)
                .minimumScaleFactor(0.75)
            Text(t.artist)
                .font(.system(size: max(12, p.titleSize * 0.66), weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .animation(.spring(response: 0.4, dampingFraction: 1), value: p.titleSize)
    }

    private func controls(_ t: MediaTrack, roomy: Bool) -> some View {
        VStack(spacing: 10) {
            ProgressScrubber(track: t, compact: !roomy)
            TransportControls(track: t, scale: roomy ? 1 : 0.85)
                .frame(maxWidth: .infinity)
            VolumeSlider(compact: !roomy)
        }
    }
}

/// System output volume. Tracks the pointer 1:1 while dragging and thickens under the pointer, like iOS.
struct VolumeSlider: View {
    var compact: Bool
    var glass = false
    @EnvironmentObject private var np: NowPlayingService
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        let level = np.muted ? 0 : np.volume
        let active = hovering || dragging
        HStack(spacing: 10) {
            Button { np.toggleMute() } label: {
                Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .frame(width: 18)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(np.muted ? "Unmute" : "Mute")

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(.white.opacity(active ? 0.95 : 0.75))
                        .frame(width: max(active ? 8 : 4, geo.size.width * level))
                }
                .frame(height: active ? (compact ? 8 : 10) : (compact ? 4 : 6))
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            dragging = true
                            np.setVolume(v.location.x / max(1, geo.size.width))
                        }
                        .onEnded { _ in dragging = false }
                )
            }
            .frame(height: 22)
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.3, dampingFraction: 1), value: active)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: compact ? 11 : 13, weight: .semibold))
                .frame(width: 22)
                .onTapGesture { np.setVolume(np.volume + 0.1) }

            AudioOutputButton(compact: compact)
        }
        .padding(.horizontal, glass ? 16 : 0)
        .padding(.vertical, glass ? 8 : 0)
        .background { if glass { GlassBackground(shape: Capsule(), shadow: false) } }
        .foregroundStyle(.white.opacity(0.75))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(level * 100)) percent")
        .accessibilityAdjustableAction { dir in
            np.setVolume(np.volume + (dir == .increment ? 0.06 : -0.06))
        }
    }
}

struct NowPlayingTag: View {
    let track: MediaTrack
    var body: some View {
        HStack(spacing: 6) {
            WidgetHeader(symbol: "waveform", title: "Now Playing", active: track.isPlaying == true)
            Text("· \(track.sourceLabel)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
    }
}

struct NowPlayingEmpty: View {
    var compact: Bool
    @EnvironmentObject private var np: NowPlayingService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(symbol: "waveform", title: "Now Playing")
            Spacer(minLength: 0)
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: compact ? 30 : 44, weight: .regular))
                .foregroundStyle(.white.opacity(0.35))
            Text("Nothing playing")
                .font(.system(size: compact ? 17 : 22, weight: .semibold, design: .rounded))
            if let last = np.lastMedia {
                Text("Last played: \(last.title) · \(last.appName)")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            } else {
                Text("Play something in Chrome or on YouTube and it shows up here.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { np.resumeLast() } label: {
                HStack(spacing: 6) {
                    if np.resuming {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(np.resuming ? "Resuming…" : "Resume last media")
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.12)))
            }
            .buttonStyle(PressableStyle(scale: 0.95))
            .disabled(np.resuming)
            .padding(.top, 4)
            if let problem = np.resumeProblem {
                HStack(spacing: 8) {
                    Text(problem)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                    if np.resumeNeedsPermission {
                        Button("Open Settings") { np.openAutomationSettings() }
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ArtworkView: View {
    let side: CGFloat
    @EnvironmentObject private var np: NowPlayingService
    @Environment(\.accent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.16, style: .continuous)
        ZStack {
            if let image = np.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.34, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: side * 0.1, y: side * 0.05)
    }
}

struct ProgressScrubber: View {
    let track: MediaTrack
    var compact: Bool
    @EnvironmentObject private var np: NowPlayingService
    @Environment(\.accent) private var accent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            if let pos = track.livePosition(at: ctx.date), let dur = track.duration, dur > 0 {
                VStack(spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule().fill(accent).frame(width: max(4, geo.size.width * pos / dur))
                        }
                        .contentShape(Rectangle().inset(by: -8))
                        .onTapGesture(coordinateSpace: .local) { p in
                            np.seek(to: max(0, min(1, p.x / geo.size.width)) * dur)
                        }
                        .animation(.linear(duration: 0.5), value: pos)
                    }
                    .frame(height: compact ? 4 : 6)
                    if !compact {
                        HStack {
                            Text(formatDuration(pos))
                            Spacer()
                            Text("-" + formatDuration(dur - pos))
                        }
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                    }
                }
            } else if !compact && np.javascriptBlocked {
                Text("For progress and controls, turn on View ▸ Developer ▸ Allow JavaScript from Apple Events in \(track.browser).")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct TransportControls: View {
    let track: MediaTrack
    var scale: CGFloat
    /// Puts each control on its own Liquid Glass circle (the Now Playing page).
    var glass = false
    @EnvironmentObject private var np: NowPlayingService
    @Environment(\.accent) private var accent

    var body: some View {
        let repeatMode = track.repeatMode ?? .off
        HStack(spacing: 18 * scale) {
            toggle(symbol: "shuffle", on: track.shuffle == true, enabled: track.canShuffle,
                   label: track.shuffle == true ? "Shuffle on" : "Shuffle off") { np.toggleShuffle() }
            button("backward.fill", size: 20, label: "Previous") { np.previous() }
            button(track.isPlaying == true ? "pause.fill" : (track.isPlaying == false ? "play.fill" : "playpause.fill"),
                   size: 30, label: "Play or pause") { np.togglePlay() }
            button("forward.fill", size: 20, label: "Next") { np.next() }
            toggle(symbol: repeatMode == .one ? "repeat.1" : "repeat", on: repeatMode != .off, enabled: track.canRepeat,
                   label: repeatMode == .off ? "Repeat off" : (repeatMode == .one ? "Repeat one" : "Repeat all")) { np.cycleRepeat() }
        }
    }

    /// Shuffle / repeat: smaller than the transport buttons, tinted with the accent and a dot when on, like Music.
    private func toggle(symbol: String, on: Bool, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        let side = (glass ? 46 : 34) * scale
        return Button(action: action) {
            VStack(spacing: 3 * scale) {
                Image(systemName: symbol)
                    .font(.system(size: 15 * scale, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Circle()
                    .frame(width: 4 * scale, height: 4 * scale)
                    .opacity(on ? 1 : 0)
            }
            .foregroundStyle(on ? accent : .white.opacity(0.6))
            .frame(width: side, height: side)
            .background { if glass { GlassBackground(shape: Circle(), shadow: false) } }
            .contentShape(Circle())
            .animation(.spring(response: 0.3, dampingFraction: 1), value: on)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(enabled ? label : "Not available for \(track.sourceLabel)")
        .accessibilityLabel(label)
    }

    private func button(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * scale, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: (glass ? (size > 24 ? 64 : 52) : 44) * scale, height: (glass ? (size > 24 ? 64 : 52) : 44) * scale)
                .background { if glass { GlassBackground(shape: Circle(), shadow: false) } }
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - Battery

enum PowerInfo {
    struct Snapshot { var level: Double?; var charging: Bool; var onAC: Bool }

    static func read() -> Snapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return Snapshot(level: nil, charging: false, onAC: true)
        }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let mx = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let state = desc[kIOPSPowerSourceStateKey] as? String
            return Snapshot(level: Double(cur) / Double(max(mx, 1)), charging: charging, onAC: state == kIOPSACPowerValue)
        }
        return Snapshot(level: nil, charging: false, onAC: true)
    }
}

struct BatteryWidget: View {
    let size: BlockSize
    @ObservedObject private var accessories = DeviceBatteries.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { _ in
            let info = PowerInfo.read()
            let items = [mac(info)] + accessories.devices
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(symbol: info.charging ? "bolt.fill" : "battery.75percent", title: "Batteries")
                if items.count == 1 {
                    macOnly(info)
                } else {
                    GeometryReader { geo in
                        let layout = ringLayout(count: items.count, in: geo.size)
                        VStack(spacing: 0) {
                            ForEach(0..<layout.rows, id: \.self) { r in
                                HStack(spacing: 0) {
                                    ForEach(Array(items.enumerated().filter { $0.offset / layout.columns == r }), id: \.element.id) { _, item in
                                        DeviceRing(device: item, diameter: layout.diameter)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { accessories.start() }
    }

    private func mac(_ info: PowerInfo.Snapshot) -> BatteryDevice {
        BatteryDevice(id: "mac", name: "This Mac", symbol: info.level == nil ? "desktopcomputer" : "laptopcomputer",
                      level: info.level ?? 1, charging: info.charging, detail: info.level == nil ? "On power" : nil)
    }

    /// The single big ring, as before, when no accessories are connected.
    private func macOnly(_ info: PowerInfo.Snapshot) -> some View {
        let level = info.level ?? 1
        let color: Color = info.charging || info.level == nil ? .green : (level < 0.2 ? .red : .white)
        return ZStack {
            Ring(progress: level, color: color, lineWidth: size == .large ? 18 : 12)
            VStack(spacing: 2) {
                if let l = info.level {
                    Text("\(Int((l * 100).rounded()))%")
                        .font(.system(size: size == .large ? 56 : 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                } else {
                    Image(systemName: "powerplug.fill").font(.system(size: 30))
                }
                Text(info.level == nil ? "On power" : (info.charging ? "Charging" : (info.onAC ? "Plugged in" : "On battery")))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Like iPhone's Batteries widget: as many rings across as keeps each one biggest.
    private func ringLayout(count n: Int, in size: CGSize) -> (columns: Int, rows: Int, diameter: CGFloat) {
        var best = (columns: n, rows: 1, diameter: CGFloat(0))
        for columns in 1...max(1, min(n, 4)) {
            let rows = Int(ceil(Double(n) / Double(columns)))
            let w = size.width / CGFloat(columns), h = size.height / CGFloat(rows)
            let d = min(w * 0.78, (h - 34) * 0.92, 150)     // leave room for the % and name below
            if d > best.diameter { best = (columns, rows, d) }
        }
        return best
    }
}

struct DeviceRing: View {
    let device: BatteryDevice
    let diameter: CGFloat

    var body: some View {
        let low = device.level < 0.2 && !device.charging
        let color: Color = device.charging ? .green : (low ? .red : .white)
        VStack(spacing: 4) {
            ZStack {
                Ring(progress: device.level, color: color, lineWidth: max(4, diameter * 0.085))
                Image(systemName: device.symbol)
                    .font(.system(size: diameter * 0.3, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                if device.charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: max(9, diameter * 0.14), weight: .bold))
                        .foregroundStyle(.green)
                        .offset(y: diameter * 0.3)
                }
            }
            .frame(width: diameter, height: diameter)
            Text("\(Int((device.level * 100).rounded()))%")
                .font(.system(size: max(12, diameter * 0.17), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(device.detail ?? device.name)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .help(device.detail.map { "\(device.name): \($0)" } ?? device.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.name), \(Int((device.level * 100).rounded())) percent\(device.charging ? ", charging" : "")")
    }
}

// MARK: - Focus timer

/// The timer is a living thing: its face beats like a heart, lub-dub, once for every second that ticks
/// away (twice a second in the last ten), breathes slowly when paused, and races when it rings.
/// Drag round the face to set it like a kitchen dial; hover and it leans toward the pointer.
struct TimerWidget: View {
    let size: BlockSize
    @EnvironmentObject private var timer: FocusTimer
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing = false
    @State private var lean = LeanFollower()
    @State private var toast: String?
    @State private var toastID = 0

    var body: some View {
        GeometryReader { geo in
            if geo.size.height < 260 || geo.size.width < 300 {
                // Mini tile: the face takes the whole height, the two buttons stand beside it.
                HStack(spacing: 10) {
                    face(compact: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 10) {
                        playButton(size: 38)
                        control("plus", "Add 5 minutes") { timer.add(minutes: 5) }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    header(compact: false)
                    face(compact: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    transport(compact: false)
                }
            }
        }
    }

    // MARK: Header and the five options

    private func header(compact: Bool) -> some View {
        HStack(spacing: 6) {
            WidgetHeader(symbol: timer.phase == .rest ? "cup.and.saucer.fill" : "waveform.path.ecg",
                         title: timer.phase == .rest ? "Break" : "Timer", active: timer.running)
            Spacer(minLength: 4)
            if compact {
                Text("\(timer.minutes) min")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                options
            }
        }
    }

    private var options: some View {
        let s = timer.style
        return HStack(spacing: 5) {
            option(symbol: s.face.symbol, help: "Face: \(s.face.title)") { change("Face · \(s.face.next.title)") { $0.face = s.face.next } }
            Button { change("Colour · \(s.hue.next.title)") { $0.hue = s.hue.next } } label: {
                Circle()
                    .fill(LinearGradient(colors: s.hue.colors(accent: accent), startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.1)))
            }
            .buttonStyle(PressableStyle())
            .help("Colour: \(s.hue.title)")
            .accessibilityLabel("Colour: \(s.hue.title)")
            option(symbol: s.rhythm.symbol, help: "Rhythm: \(s.rhythm.title)") { change("Rhythm · \(s.rhythm.next.title)") { $0.rhythm = s.rhythm.next } }
            option(symbol: s.sound.symbol, help: "Sound: \(s.sound.title)") { change("Sound · \(s.sound.next.title)") { $0.sound = s.sound.next } }
            option(symbol: "arrow.triangle.2.circlepath", on: s.cycle == .focusBreak,
                   help: s.cycle == .focusBreak ? "Focus + break cycle: on" : "Focus + break cycle: off") {
                change(s.cycle == .once ? "Cycle · Focus \(timer.minutes) + break \(timer.breakMinutes)" : "Cycle · Off") { $0.cycle = s.cycle.next }
            }
        }
    }

    private func option(symbol: String, on: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(on ? Color.black : .white.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(Circle().fill(on ? AnyShapeStyle(timer.style.hue.colors(accent: accent)[0]) : AnyShapeStyle(.white.opacity(0.1))))
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func change(_ message: String, _ edit: (inout TimerStyle) -> Void) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
            edit(&timer.style)
            toast = message
        }
        toastID += 1
        let id = toastID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if toastID == id { withAnimation(.easeOut(duration: 0.4)) { toast = nil } }
        }
    }

    // MARK: Face

    private func face(compact: Bool) -> some View {
        let still = reduceMotion || (timer.style.rhythm == .still && !timer.ringing)
        return TimelineView(.animation(minimumInterval: 1.0 / 60, paused: still && !timer.running)) { ctx in
            let now = ctx.date
            let rem = timer.remaining(at: now)
            let beat = TimerPulse.beat(still ? TimerStyle.Rhythm.still : timer.style.rhythm,
                                       running: timer.running, ringing: timer.ringing, remaining: rem, at: now)
            let urgent = timer.running && rem < 10
            let colors = urgent ? [Color(red: 1, green: 0.27, blue: 0.3), Color(red: 1, green: 0.6, blue: 0.2)]
                                : timer.style.hue.colors(accent: accent)
            let leanNow = lean.step()

            GeometryReader { g in
                let d = min(g.size.width, g.size.height)
                ZStack {
                    TimerFaceCanvas(face: timer.style.face, fill: timer.total > 0 ? min(1, rem / timer.total) : 0, beat: beat,
                                    time: now.timeIntervalSinceReferenceDate, colors: colors, lean: leanNow)
                    centre(rem: rem, diameter: d, beat: beat.level, compact: compact)
                    if let toast {
                        Text(toast)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(.black.opacity(0.35)))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
                .contentShape(Rectangle())
                .gesture(dial(in: g.size))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        lean.target = CGPoint(x: (p.x - g.size.width / 2) / max(1, d / 2),
                                              y: (p.y - g.size.height / 2) / max(1, d / 2))
                    case .ended:
                        lean.target = .zero
                    }
                }
            }
        }
    }

    private func centre(rem: TimeInterval, diameter d: CGFloat, beat: Double, compact: Bool) -> some View {
        let secs = Int(rem.rounded(.up))
        return Button { editing = true } label: {
            VStack(spacing: d * 0.012) {
                Text(formatDuration(TimeInterval(secs)))
                    .font(.system(size: d * (secs >= 3600 ? 0.15 : 0.2), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.35, dampingFraction: 0.9), value: secs)
                    .shadow(color: .black.opacity(0.35), radius: d * 0.03, y: d * 0.01)
                if !compact {
                    Text(caption)
                        .font(.system(size: max(10, d * 0.045), weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                        .contentTransition(.opacity)
                }
            }
            .scaleEffect(1 + 0.03 * beat)
        }
        .buttonStyle(PressableStyle(scale: 0.95))
        .help("Type a length, or drag round the dial")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            FocusLengthPicker(isPresented: $editing)
        }
    }

    private var caption: String {
        if timer.ringing { return "Time's up" }
        if let end = timer.endDate { return "Ends \(end.formatted(date: .omitted, time: .shortened))" }
        if timer.pausedRemaining < timer.total { return "Paused" }
        return "Drag the dial · tap to type"
    }

    /// Kitchen-timer dial: the angle from 12 o'clock is the number of minutes (1–60).
    private func dial(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                guard !timer.running, !timer.ringing else { return }
                let dx = v.location.x - size.width / 2, dy = v.location.y - size.height / 2
                var a = atan2(dx, -dy)
                if a < 0 { a += 2 * .pi }
                let m = max(1, (a / (2 * .pi) * 60).rounded())
                if Int(m) != timer.minutes || timer.total > 3600 {
                    timer.set(minutes: m)
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
    }

    // MARK: Transport

    private func transport(compact: Bool) -> some View {
        HStack(spacing: 18) {
            control("arrow.counterclockwise", "Reset") { timer.reset() }
            playButton(size: 44)
            control("plus", "Add 5 minutes") { timer.add(minutes: 5) }
        }
        .frame(maxWidth: .infinity)
    }

    private func playButton(size: CGFloat) -> some View {
        let tint = timer.style.hue.colors(accent: accent)[0]
        return Button { timer.toggle() } label: {
            Image(systemName: timer.running ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.36, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.black)
                .frame(width: size, height: size)
                .background(Circle().fill(tint))
                .shadow(color: tint.opacity(timer.running ? 0.6 : 0), radius: 12)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(timer.running ? "Pause timer" : "Start timer")
        .animation(.spring(response: 0.4, dampingFraction: 1), value: timer.running)
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

/// Eases the face's lean toward the pointer a little every frame, so it drifts rather than snaps.
final class LeanFollower {
    var target = CGPoint.zero
    private var current = CGPoint.zero
    func step() -> CGPoint {
        current.x += (max(-1, min(1, target.x)) - current.x) * 0.08
        current.y += (max(-1, min(1, target.y)) - current.y) * 0.08
        return current
    }
}

enum TimerPulse {
    struct Beat { var level: Double; var phase: Double; var ripples: Bool }

    /// Lub-dub: a strong beat and a softer echo, as one smooth curve over a beat (x in 0…1).
    static func heart(_ x: Double) -> Double {
        exp(-pow((x - 0.06) / 0.05, 2)) + 0.55 * exp(-pow((x - 0.27) / 0.06, 2))
    }

    static func beat(_ rhythm: TimerStyle.Rhythm, running: Bool, ringing: Bool, remaining: TimeInterval, at date: Date) -> Beat {
        let t = date.timeIntervalSinceReferenceDate
        if ringing {
            let x = (t * 2.2).truncatingRemainder(dividingBy: 1)
            return Beat(level: heart(x) * 1.4, phase: x, ripples: true)
        }
        switch rhythm {
        case .still:
            return Beat(level: 0, phase: 0, ripples: false)
        case .breathe:
            let x = (t / (running ? 4 : 6)).truncatingRemainder(dividingBy: 1)
            return Beat(level: 0.5 - 0.5 * cos(x * 2 * .pi), phase: x, ripples: false)
        case .heartbeat:
            if running {
                // Synced to the countdown: the main beat lands as each second ticks over.
                let urgent = remaining < 10
                var x = 1 - (remaining * (urgent ? 2 : 1)).truncatingRemainder(dividingBy: 1)
                if x >= 1 { x -= 1 }
                return Beat(level: heart(x) * (urgent ? 1.35 : 1), phase: x, ripples: true)
            }
            let x = (t / 1.5).truncatingRemainder(dividingBy: 1)     // a resting heart
            return Beat(level: heart(x) * 0.45, phase: x, ripples: false)
        }
    }
}

/// Draws one of the three faces. `fill` is the share of the timer still to run: full at the start, empty at the end.
struct TimerFaceCanvas: View {
    let face: TimerStyle.Face
    let fill: Double
    let beat: TimerPulse.Beat
    let time: Double
    let colors: [Color]
    let lean: CGPoint

    var body: some View {
        Canvas { g, size in
            let r = min(size.width, size.height) / 2 * 0.96
            let c = CGPoint(x: size.width / 2 + lean.x * r * 0.05, y: size.height / 2 + lean.y * r * 0.05)
            switch face {
            case .pulse: pulse(&g, c, r)
            case .tide: tide(&g, c, r)
            case .halo: halo(&g, c, r)
            }
        }
        .accessibilityHidden(true)
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    /// Angle measured clockwise from 12 o'clock.
    private func point(_ c: CGPoint, _ r: CGFloat, _ turn: Double) -> CGPoint {
        let a = turn * 2 * .pi - .pi / 2
        return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    }

    private func glow(_ g: inout GraphicsContext, at p: CGPoint, radius: CGFloat, color: Color) {
        g.drawLayer { l in
            l.addFilter(.blur(radius: radius * 0.9))
            l.fill(circle(p, radius * 1.6), with: .color(color.opacity(0.8)))
        }
        g.fill(circle(p, radius * 0.55), with: .color(.white))
    }

    // Pulse: an ECG trace bent into a ring around a beating orb; the bright part is the time left.
    private func pulse(_ g: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat) {
        let base = r * 0.8
        let orb = r * 0.5 * (1 + 0.07 * beat.level)
        g.drawLayer { l in
            l.addFilter(.blur(radius: r * 0.1))
            l.fill(circle(c, orb), with: .radialGradient(
                Gradient(colors: [colors[0].opacity(0.75 + 0.25 * beat.level), colors[1].opacity(0.4), .clear]),
                center: c, startRadius: 0, endRadius: orb))
        }
        if beat.ripples {
            for k in 0..<2 {
                let x = beat.phase - Double(k) * 0.3
                guard x > 0 else { continue }
                let rr = r * 0.42 + (base - r * 0.42) * x
                g.stroke(circle(c, rr), with: .color(.white.opacity(0.45 * (1 - x))), lineWidth: max(1.5, r * 0.014))
            }
        }

        let n = 540
        let amp = r * 0.08 * (0.3 + 0.7 * beat.level)
        func trace(_ x: Double) -> Double {
            exp(-pow((x - 0.5) / 0.022, 2)) - 0.45 * exp(-pow((x - 0.56) / 0.03, 2)) + 0.18 * exp(-pow((x - 0.3) / 0.05, 2))
        }
        func path(to end: Int) -> Path {
            var p = Path()
            for i in 0...end {
                let u = Double(i) / Double(n)
                var x = (u * 6 + time * 0.22).truncatingRemainder(dividingBy: 1)
                if x < 0 { x += 1 }
                let pt = point(c, base + amp * trace(x), u)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            return p
        }
        let style = StrokeStyle(lineWidth: max(2.5, r * 0.03), lineCap: .round, lineJoin: .round)
        g.stroke(path(to: n), with: .color(.white.opacity(0.25)), style: style)
        let lit = Int(Double(n) * fill)
        if lit > 1 {
            g.drawLayer { l in
                l.addFilter(.shadow(color: colors[0].opacity(0.8), radius: r * 0.04))
                l.stroke(path(to: lit), with: .conicGradient(Gradient(colors: [.white, colors[0]]), center: c, angle: .degrees(-90)), style: style)
            }
            glow(&g, at: point(c, base, fill), radius: r * (0.035 + 0.02 * beat.level), color: colors[0])
        }
    }

    // Tide: the time left is water in a glass; it sways, tilts toward the pointer and surges on each beat.
    private func tide(_ g: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat) {
        let rim = r * 0.9
        let glass = circle(c, rim)
        g.fill(glass, with: .color(.white.opacity(0.06)))
        g.drawLayer { l in
            l.clip(to: glass)
            let top = c.y - rim, bottom = c.y + rim
            let level = bottom - (bottom - top) * fill
            let a = r * (0.025 + 0.045 * beat.level)
            let tilt = lean.x * r * 0.22
            for layer in 0..<2 {
                let k = Double(layer)
                var p = Path()
                p.move(to: CGPoint(x: c.x - rim, y: bottom + 2))
                var x = c.x - rim
                while x <= c.x + rim + 4 {
                    let u = Double((x - c.x) / rim)
                    let wave: Double = sin(u * 3.2 + time * (1.3 + 0.6 * k) + k * 1.7) + 0.5 * sin(u * 7.1 - time * 2.1)
                    let y: CGFloat = level + tilt * CGFloat(u) + a * CGFloat(wave)
                    p.addLine(to: CGPoint(x: x, y: y))
                    x += 4
                }
                p.addLine(to: CGPoint(x: c.x + rim, y: bottom + 2))
                p.closeSubpath()
                l.fill(p, with: .linearGradient(
                    Gradient(colors: [colors[0].opacity(layer == 0 ? 0.4 : 0.85), colors[1].opacity(layer == 0 ? 0.25 : 0.7)]),
                    startPoint: CGPoint(x: c.x, y: level), endPoint: CGPoint(x: c.x, y: bottom)))
            }
            // A few bubbles drifting up through the water.
            for i in 0..<7 {
                let seed = Double(i) * 1.618
                let rise = (time * (0.08 + 0.03 * Double(i % 3)) + seed).truncatingRemainder(dividingBy: 1)
                let y = bottom - (bottom - level) * rise
                guard y > level + 4 else { continue }
                let x = c.x + rim * 0.75 * sin(seed * 2.3 + time * 0.4)
                l.fill(circle(CGPoint(x: x, y: y), r * (0.012 + 0.008 * Double(i % 2))), with: .color(.white.opacity(0.35 * (1 - rise))))
            }
        }
        g.stroke(glass, with: .color(.white.opacity(0.2)), lineWidth: 1.5)
    }

    // Halo: sixty seconds of light round a ring; the lit ones are the time left, and the head glows on each beat.
    private func halo(_ g: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat) {
        g.drawLayer { l in
            l.addFilter(.blur(radius: r * 0.18))
            l.fill(circle(c, r * (0.45 + 0.05 * beat.level)), with: .color(colors[1].opacity(0.25 + 0.2 * beat.level)))
        }
        let ring = r * 0.78
        g.stroke(circle(c, ring), with: .color(.black.opacity(0.15)), lineWidth: max(4, r * 0.06))
        if fill > 0.001 {
            var arc = Path()
            arc.addArc(center: c, radius: ring, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fill), clockwise: false)
            g.stroke(arc, with: .conicGradient(Gradient(colors: [.white, colors[0]]), center: c, angle: .degrees(-90)),
                     style: StrokeStyle(lineWidth: max(4, r * 0.06), lineCap: .round))
            glow(&g, at: point(c, ring, fill), radius: r * (0.04 + 0.025 * beat.level), color: colors[0])
        }
        for i in 0..<60 {
            let u = Double(i) / 60
            let lit = u < fill
            let near = max(0, 1 - abs(u - fill) * 12)
            let dot = r * (i % 5 == 0 ? 0.016 : 0.009) * (1 + CGFloat(near * beat.level))
            g.fill(circle(point(c, r * 0.94, u), dot), with: .color(lit ? colors[0].opacity(0.9) : .white.opacity(0.18)))
        }
    }
}

extension TimerStyle.Face {
    var title: String { switch self {
        case .pulse: "Pulse"
        case .tide: "Tide"
        case .halo: "Halo"
        } }
    var symbol: String { switch self {
        case .pulse: "waveform.path.ecg"
        case .tide: "drop.fill"
        case .halo: "circle.dotted"
        } }
}

extension TimerStyle.Hue {
    var title: String {
        switch self {
        case .theme: "Theme"
        case .ember: "Ember"
        case .ocean: "Ocean"
        case .mint: "Mint"
        case .violet: "Violet"
        }
    }
    func colors(accent: Color) -> [Color] {
        switch self {
        case .theme: [accent, accent.opacity(0.55)]
        case .ember: [Color(red: 1, green: 0.27, blue: 0.36), Color(red: 1, green: 0.62, blue: 0.04)]
        case .ocean: [Color(red: 0.39, green: 0.82, blue: 1), Color(red: 0.04, green: 0.52, blue: 1)]
        case .mint: [Color(red: 0.19, green: 0.82, blue: 0.35), Color(red: 0, green: 0.78, blue: 0.75)]
        case .violet: [Color(red: 0.75, green: 0.35, blue: 0.95), Color(red: 0.37, green: 0.36, blue: 0.9)]
        }
    }
}

extension TimerStyle.Rhythm {
    var title: String { switch self {
        case .heartbeat: "Heartbeat"
        case .breathe: "Breathe"
        case .still: "Still"
        } }
    var symbol: String { switch self {
        case .heartbeat: "heart.fill"
        case .breathe: "wind"
        case .still: "pause.circle"
        } }
}

extension TimerStyle.Sound {
    var title: String { switch self {
        case .alarm: "Alarm"
        case .chime: "Chime"
        case .silent: "Silent"
        } }
    var symbol: String { switch self {
        case .alarm: "alarm.fill"
        case .chime: "bell.fill"
        case .silent: "bell.slash.fill"
        } }
}

struct FocusLengthPicker: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var timer: FocusTimer
    @Environment(\.accent) private var accent
    @State private var text = ""
    @FocusState private var focused: Bool

    private let presets: [Int] = [5, 10, 15, 25, 30, 45, 60, 90]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Timer length")
                .font(.system(size: 13, weight: .bold, design: .rounded))
            HStack(spacing: 8) {
                TextField("Minutes", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 90)
                    .focused($focused)
                    .onSubmit { apply(start: true) }
                    .onChange(of: text) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(3))
                        if digits != new { text = digits }
                    }
                Text("minutes").foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(presets, id: \.self) { m in
                    Button { text = "\(m)" } label: {
                        Text("\(m)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(text == "\(m)" ? accent.opacity(0.35) : Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(PressableStyle(scale: 0.94))
                }
            }
            HStack {
                Button("Set") { apply(start: false) }
                Spacer()
                Button("Start") { apply(start: true) }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled((Int(text) ?? 0) < 1)
            Text("1 to 180 minutes")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 250)
        .onAppear {
            text = "\(timer.minutes)"
            focused = true
        }
    }

    private func apply(start: Bool) {
        guard let m = Int(text), m >= 1 else { return }
        timer.set(minutes: Double(m), start: start)
        isPresented = false
    }
}

// MARK: - World clock

struct WorldClockWidget: View {
    let size: BlockSize
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accent) private var accent
    @State private var picking = false
    @State private var hovered: WorldCity?

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    WidgetHeader(symbol: "globe", title: "World Clock")
                    Spacer()
                    Button { picking = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(.white.opacity(0.14)))
                    }
                    .buttonStyle(PressableStyle())
                    .help("Add or remove cities")
                    .accessibilityLabel("Add city")
                    .popover(isPresented: $picking, arrowEdge: .bottom) { CityPicker() }
                }

                if settings.config.worldCities.isEmpty {
                    Spacer(minLength: 0)
                    Text("Tap + to add cities")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                } else {
                    GeometryReader { geo in
                        let layout = ClockGridLayout.best(count: settings.config.worldCities.count, in: geo.size)
                        if layout.timeSize >= 20 {
                            grid(at: ctx.date, layout: layout)
                        } else {
                            // Too many cities for this tile: fall back to a scrolling list.
                            ScrollView(.vertical) {
                                VStack(spacing: size == .large ? 14 : 9) {
                                    ForEach(settings.config.worldCities) { city in row(city, at: ctx.date) }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .scrollIndicators(.never)
                        }
                    }
                }
            }
        }
    }

    /// Cities laid out in whichever grid gives the biggest time for this tile and this many cities,
    /// so one city fills the tile and ten still fit. No dividers: spacing alone separates them.
    private func grid(at date: Date, layout: ClockGridLayout) -> some View {
        let cities = settings.config.worldCities
        let t = layout.timeSize
        let nameSize = min(max(t * 0.34, 12), 24)
        let offsetSize = min(max(t * 0.24, 10), 15)
        return VStack(spacing: 0) {
            ForEach(0..<layout.rows, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(Array(cities.enumerated().filter { $0.offset / layout.columns == r }), id: \.element.id) { _, city in
                        let tz = TimeZone(identifier: city.tz) ?? .current
                        let time = Text(WorldClockFormat.time(date, tz, use24h: settings.config.use24h))
                            .font(.system(size: t, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .tracking(-t * 0.03)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .contentTransition(.numericText())
                        let labels = VStack(alignment: .leading, spacing: 1) {
                            Text(city.name)
                                .font(.system(size: nameSize, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                            Text(WorldClockFormat.offset(tz, at: date))
                                .font(.system(size: offsetSize, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        Group {
                            if layout.horizontal {
                                HStack(alignment: .center, spacing: 10) { labels; Spacer(minLength: 6); time }
                            } else {
                                VStack(alignment: .leading, spacing: t * 0.06) { time; labels }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Remove \(city.name)", role: .destructive) { settings.removeCity(city) }
                        }
                    }
                    ForEach(0..<(layout.columns - min(layout.columns, cities.count - r * layout.columns)), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 1), value: layout)
    }

    private func row(_ city: WorldCity, at date: Date) -> some View {
        let tz = TimeZone(identifier: city.tz) ?? .current
        let showRemove = hovered == city
        return HStack(alignment: .center, spacing: 8) {
            if showRemove {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 1)) { settings.removeCity(city) }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.red.opacity(0.9))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Remove \(city.name)")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(city.name)
                    .font(.system(size: size == .large ? 17 : 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(WorldClockFormat.offset(tz, at: date))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(WorldClockFormat.time(date, tz, use24h: settings.config.use24h))
                .font(.system(size: size == .large ? 30 : 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
                if inside { hovered = city } else if hovered == city { hovered = nil }
            }
        }
        .contextMenu {
            Button("Remove \(city.name)", role: .destructive) { settings.removeCity(city) }
        }
    }
}

/// Picks columns × rows (or one city per row, time beside the name) to give the largest legible time.
struct ClockGridLayout: Equatable {
    var columns: Int
    var rows: Int
    var horizontal: Bool
    var timeSize: CGFloat

    static func best(count n: Int, in size: CGSize) -> ClockGridLayout {
        guard n > 0, size.width > 0, size.height > 0 else { return ClockGridLayout(columns: 1, rows: 1, horizontal: false, timeSize: 0) }
        var best = ClockGridLayout(columns: 1, rows: n, horizontal: false, timeSize: 0)
        for columns in 1...min(n, 4) {
            let rows = Int(ceil(Double(n) / Double(columns)))
            let w = size.width / CGFloat(columns), h = size.height / CGFloat(rows)
            // Stacked: time above name + offset (≈ 1.9 time-heights tall, ~3.4 time-heights wide for "12:45p").
            let stacked = min(w / 3.6, h / 1.95, 120)
            if stacked > best.timeSize { best = ClockGridLayout(columns: columns, rows: rows, horizontal: false, timeSize: stacked) }
            // Side by side: name on the left, time on the right — good for one wide column.
            if columns == 1 {
                let side = min((w * 0.55) / 3.4, h * 0.72, 120)
                if side > best.timeSize * 1.1 { best = ClockGridLayout(columns: 1, rows: rows, horizontal: true, timeSize: side) }
            }
        }
        best.timeSize = floor(best.timeSize)
        return best
    }
}

enum WorldClockFormat {
    static func time(_ d: Date, _ tz: TimeZone, use24h: Bool) -> String {
        var cal = Calendar.current
        cal.timeZone = tz
        let c = cal.dateComponents([.hour, .minute], from: d)
        let h = c.hour ?? 0, m = c.minute ?? 0
        if use24h { return String(format: "%02d:%02d", h, m) }
        return String(format: "%d:%02d", h % 12 == 0 ? 12 : h % 12, m) + (h < 12 ? "a" : "p")
    }

    /// "Today, +5:30 hrs" style label relative to this Mac's time zone.
    static func offset(_ tz: TimeZone, at d: Date) -> String {
        let diffSeconds = tz.secondsFromGMT(for: d) - TimeZone.current.secondsFromGMT(for: d)
        var there = Calendar.current
        there.timeZone = tz
        let dayThere = there.component(.day, from: d)
        let dayHere = Calendar.current.component(.day, from: d)
        let day: String
        if dayThere == dayHere { day = "Today" } else { day = diffSeconds > 0 ? "Tomorrow" : "Yesterday" }
        if diffSeconds == 0 { return "\(day), same time" }
        let diff = Double(diffSeconds) / 3600
        let h = Int(diff), m = Int((abs(diff - Double(h)) * 60).rounded())
        return "\(day), " + (diff > 0 ? "+" : "−") + "\(abs(h))" + (m > 0 ? ":\(String(format: "%02d", m))" : "") + " hrs"
    }
}

struct CityPicker: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accent) private var accent
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [WorldCity] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let popular = (WorldCity.popular + WorldCity.extras).filter { $0.name.lowercased().contains(q) }
        let zones = TimeZone.knownTimeZoneIdentifiers
            .filter { $0.lowercased().replacingOccurrences(of: "_", with: " ").contains(q) || (TimeZone(identifier: $0)?.abbreviation()?.lowercased() == q) }
            .map { WorldCity(name: WorldCity.cityName(for: $0), tz: $0) }
        var seen = Set<String>()
        return (popular + zones).filter { seen.insert($0.name + $0.tz).inserted }.prefix(40).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search city or time zone", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)

            if query.isEmpty {
                Text("Popular")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
                    ForEach(WorldCity.popular) { city in chip(city) }
                }
                Text("\(settings.config.worldCities.count) of 10 · hover a city on the clock to remove it")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results) { city in resultRow(city) }
                        if results.isEmpty {
                            Text("No matching time zones")
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                        }
                    }
                }
                .frame(height: 260)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private func isAdded(_ c: WorldCity) -> Bool { settings.config.worldCities.contains(c) }

    private func chip(_ city: WorldCity) -> some View {
        let added = isAdded(city)
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 1)) { settings.toggleCity(city) }
        } label: {
            HStack(spacing: 4) {
                if added { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                Text(city.name).lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(Capsule().fill(added ? accent.opacity(0.35) : Color.primary.opacity(0.08)))
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .accessibilityLabel(added ? "Remove \(city.name)" : "Add \(city.name)")
    }

    private func resultRow(_ city: WorldCity) -> some View {
        let tz = TimeZone(identifier: city.tz) ?? .current
        let added = isAdded(city)
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 1)) { settings.toggleCity(city) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(city.name).font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(WorldCity.region(for: city.tz).replacingOccurrences(of: "_", with: " ") + " · " + WorldClockFormat.offset(tz, at: Date()))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(WorldClockFormat.time(Date(), tz, use24h: settings.config.use24h))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(added ? accent : .secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }
}

// MARK: - System

enum SystemStats {
    static func read() -> (cpu: Double, memUsed: Double, memTotal: Double) {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let cpu = min(1, load[0] / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)))

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = Double(sysconf(_SC_PAGESIZE))
        let used = kr == KERN_SUCCESS
            ? Double(UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
            : 0
        return (cpu, used, Double(ProcessInfo.processInfo.physicalMemory))
    }
}

struct SystemWidget: View {
    let size: BlockSize
    @Environment(\.accent) private var accent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            let s = SystemStats.read()
            VStack(alignment: .leading) {
                WidgetHeader(symbol: "cpu", title: "System")
                Spacer(minLength: 6)
                HStack(spacing: 18) {
                    gauge(value: s.cpu, label: "CPU", text: "\(Int(s.cpu * 100))%")
                    gauge(value: s.memTotal > 0 ? s.memUsed / s.memTotal : 0, label: "Memory",
                          text: String(format: "%.1f GB", s.memUsed / 1_073_741_824))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func gauge(value: Double, label: String, text: String) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Ring(progress: value, color: accent, lineWidth: size == .large ? 12 : 8)
                    .animation(.spring(response: 0.6, dampingFraction: 1), value: value)
                Text(text)
                    .font(.system(size: size == .large ? 20 : 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .padding(8)
            }
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

// MARK: - Note

struct NoteWidget: View {
    let size: BlockSize
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(symbol: "note.text", title: "Note")
            TextEditor(text: $settings.config.note)
                .font(.system(size: size == .large ? 22 : 17, weight: .medium, design: .rounded))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
        }
    }
}

// MARK: - Accessory batteries

struct BatteryDevice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var symbol: String
    var level: Double
    var charging: Bool
    var detail: String?
}

/// Batteries of accessories connected to this Mac: AirPods / Beats (left, right, case) from the Bluetooth
/// report, and Magic Keyboard / Mouse / Trackpad from the HID registry. An iPhone's battery isn't available to
/// Mac apps (Apple's own widget uses private system access), so it isn't listed.
@MainActor
final class DeviceBatteries: ObservableObject {
    static let shared = DeviceBatteries()
    @Published private(set) var devices: [BatteryDevice] = []
    private var timer: Timer?
    private var loading = false

    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .utility) {
            let found = Self.read()
            await MainActor.run {
                if found != self.devices {
                    withAnimation(.spring(response: 0.45, dampingFraction: 1)) { self.devices = found }
                }
                self.loading = false
            }
        }
    }

    nonisolated static func read() -> [BatteryDevice] {
        var byName: [String: BatteryDevice] = [:]
        for d in hidAccessories() { byName[d.name] = d }
        // The Bluetooth report knows AirPods' left / right / case; prefer it when it has more detail.
        for d in bluetoothReport() where byName[d.name] == nil || d.detail != nil { byName[d.name] = d }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// Magic Keyboard, Mouse and Trackpad publish BatteryPercent in the IO registry.
    nonisolated private static func hidAccessories() -> [BatteryDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [BatteryDevice] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            func prop(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let pct = (prop("BatteryPercent") as? NSNumber)?.intValue,
                  let name = prop("Product") as? String, !name.isEmpty else { continue }
            result.append(BatteryDevice(id: "hid:" + name, name: name, symbol: symbol(for: name, type: nil),
                                        level: Double(pct) / 100, charging: false, detail: nil))
        }
        return result
    }

    /// `system_profiler SPBluetoothDataType -json` lists connected devices with device_batteryLevel* keys.
    nonisolated private static func bluetoothReport() -> [BatteryDevice] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 12, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var result: [BatteryDevice] = []
        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let props = value as? [String: Any] else { continue }
                    func level(_ key: String) -> Int? {
                        guard let s = props[key] as? String else { return nil }
                        return Int(s.filter(\.isNumber))
                    }
                    let main = level("device_batteryLevelMain")
                    let left = level("device_batteryLevelLeft"), right = level("device_batteryLevelRight")
                    let caseLevel = level("device_batteryLevelCase")
                    let buds = [left, right].compactMap { $0 }
                    guard let shown = main ?? buds.min() ?? caseLevel else { continue }
                    var parts: [String] = []
                    if let left { parts.append("L \(left)%") }
                    if let right { parts.append("R \(right)%") }
                    if let caseLevel { parts.append("Case \(caseLevel)%") }
                    let type = props["device_minorType"] as? String
                    result.append(BatteryDevice(id: "bt:" + name, name: name, symbol: symbol(for: name, type: type),
                                                level: Double(shown) / 100, charging: false,
                                                detail: parts.isEmpty ? nil : parts.joined(separator: " · ")))
                }
            }
        }
        return result
    }

    nonisolated static func symbol(for name: String, type: String?) -> String {
        let n = name.lowercased(), t = (type ?? "").lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        if n.contains("keyboard") || t.contains("keyboard") { return "keyboard" }
        if n.contains("mouse") || t.contains("mouse") { return "magicmouse" }
        if n.contains("trackpad") || t.contains("trackpad") { return "hand.point.up.left" }
        if n.contains("pencil") { return "applepencil" }
        if n.contains("controller") || t.contains("gamepad") { return "gamecontroller" }
        if t.contains("headphone") || t.contains("headset") { return "headphones" }
        if t.contains("speaker") { return "hifispeaker" }
        return "dot.radiowaves.left.and.right"
    }
}

// MARK: - Sound output (Continuity-style picker)

struct AudioOutput: Identifiable, Equatable {
    enum Kind: Equatable { case device, airPlay(source: UInt32), bluetoothPaired(address: String) }
    var id: String
    var deviceID: AudioDeviceID
    var name: String
    var symbol: String
    var kind: Kind
    var isCurrent: Bool
}

/// Lists where sound can go — this Mac, connected headphones and speakers, displays, AirPlay receivers —
/// switches the system output, and connects paired Bluetooth headphones that aren't connected yet.
@MainActor
final class AudioOutputs: ObservableObject {
    static let shared = AudioOutputs()
    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var paired: [AudioOutput] = []
    @Published private(set) var connecting: String?
    @Published private(set) var currentSymbol = "hifispeaker.fill"
    @Published private(set) var currentName = ""
    private var listening = false
    private var connector: BluetoothConnector?

    /// Cheap: CoreAudio only. Bluetooth (which asks for permission the first time) is read when the picker opens.
    func start() {
        refresh()
        guard !listening else { return }
        listening = true
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in
                Task { @MainActor in AudioOutputs.shared.refresh() }
            }
        }
    }

    func refresh(includeBluetooth: Bool = false) {
        let current = CoreAudioBridge.defaultOutput()
        var list: [AudioOutput] = []
        for id in CoreAudioBridge.deviceIDs() where CoreAudioBridge.hasOutput(id) {
            let name = CoreAudioBridge.name(id) ?? "Output"
            let transport = CoreAudioBridge.transport(id)
            if transport == kAudioDeviceTransportTypeAirPlay {
                let active = CoreAudioBridge.currentDataSource(id)
                for source in CoreAudioBridge.dataSources(id) {
                    let receiver = CoreAudioBridge.dataSourceName(id, source) ?? name
                    list.append(AudioOutput(id: "airplay:\(source)", deviceID: id, name: receiver, symbol: "airplayaudio",
                                            kind: .airPlay(source: source), isCurrent: id == current && active == source))
                }
                continue
            }
            if transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate { continue }
            list.append(AudioOutput(id: "dev:\(id)", deviceID: id, name: name, symbol: Self.symbol(name: name, transport: transport),
                                    kind: .device, isCurrent: id == current))
        }
        outputs = list
        if let now = list.first(where: \.isCurrent) {
            currentSymbol = now.symbol
            currentName = now.name
        }
        if includeBluetooth {
            let connectedNames = Set(list.map(\.name))
            paired = BluetoothConnector.pairedAudio()
                .filter { !$0.connected && !connectedNames.contains($0.name) }
                .map { AudioOutput(id: "bt:\($0.address)", deviceID: 0, name: $0.name,
                                   symbol: DeviceBatteries.symbol(for: $0.name, type: "headphones"),
                                   kind: .bluetoothPaired(address: $0.address), isCurrent: false) }
        }
    }

    func select(_ output: AudioOutput) {
        switch output.kind {
        case .device:
            CoreAudioBridge.setDefaultOutput(output.deviceID)
        case .airPlay(let source):
            CoreAudioBridge.setDataSource(output.deviceID, source)
            CoreAudioBridge.setDefaultOutput(output.deviceID)
        case .bluetoothPaired(let address):
            connect(address: address, name: output.name)
            return
        }
        refresh()
    }

    /// Connects paired headphones, then switches sound to them once they show up as an output.
    private func connect(address: String, name: String) {
        guard connecting == nil else { return }
        connecting = address
        let c = BluetoothConnector()
        connector = c
        c.connect(address: address) { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                if ok {
                    for _ in 0..<12 {
                        self.refresh()
                        if let out = self.outputs.first(where: { $0.name == name }) {
                            CoreAudioBridge.setDefaultOutput(out.deviceID)
                            break
                        }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                self.connecting = nil
                self.connector = nil
                self.refresh(includeBluetooth: true)
            }
        }
    }

    static func symbol(name: String, transport: UInt32) -> String {
        let n = name.lowercased()
        if n.contains("airpods") || n.contains("beats") { return DeviceBatteries.symbol(for: name, type: nil) }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return n.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return n.contains("speaker") ? "hifispeaker.fill" : "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeUSB:
            return "hifispeaker.fill"
        default:
            return "speaker.wave.2.fill"
        }
    }
}

/// Thin wrappers over the CoreAudio property API.
enum CoreAudioBridge {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func deviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func name(_ id: AudioDeviceID) -> String? {
        var addr = address(kAudioObjectPropertyName)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func transport(_ id: AudioDeviceID) -> UInt32 { uint32(id, kAudioDevicePropertyTransportType) ?? 0 }

    static func defaultOutput() -> AudioDeviceID { uint32(system, kAudioHardwarePropertyDefaultOutputDevice) ?? 0 }

    static func setDefaultOutput(_ id: AudioDeviceID) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }

    static func dataSources(_ id: AudioDeviceID) -> [UInt32] {
        var addr = address(kAudioDevicePropertyDataSources, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var sources = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &sources) == noErr else { return [] }
        return sources
    }

    static func currentDataSource(_ id: AudioDeviceID) -> UInt32? {
        uint32(id, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
    }

    static func setDataSource(_ id: AudioDeviceID, _ source: UInt32) {
        var addr = address(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
        var value = source
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func dataSourceName(_ id: AudioDeviceID, _ source: UInt32) -> String? {
        var addr = address(kAudioDevicePropertyDataSourceNameForIDCFString, kAudioDevicePropertyScopeOutput)
        var input = source
        var output: Unmanaged<CFString>?
        let status: OSStatus = withUnsafeMutablePointer(to: &input) { inPtr in
            withUnsafeMutablePointer(to: &output) { outPtr in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(inPtr), mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(outPtr), mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &translation)
            }
        }
        guard status == noErr, let output else { return nil }
        return output.takeRetainedValue() as String
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }
}

/// Paired Bluetooth audio devices, and an asynchronous connect that reports back on the main thread.
final class BluetoothConnector: NSObject {
    struct Paired { var address: String; var name: String; var connected: Bool }
    private var completion: ((Bool) -> Void)?
    private var device: IOBluetoothDevice?

    static func pairedAudio() -> [Paired] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return devices.compactMap { d in
            guard d.deviceClassMajor == 0x04, let address = d.addressString else { return nil }   // 0x04 = audio/video
            return Paired(address: address, name: d.name ?? address, connected: d.isConnected())
        }
    }

    func connect(address: String, completion: @escaping (Bool) -> Void) {
        guard let d = IOBluetoothDevice(addressString: address) else { completion(false); return }
        self.completion = completion
        device = d
        if d.openConnection(self) != 0 { finish(false) }
    }

    @objc(connectionComplete:status:)
    func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        finish(status == 0)
    }

    private func finish(_ ok: Bool) {
        let c = completion
        completion = nil
        c?(ok)
    }
}

struct AudioOutputButton: View {
    var compact: Bool
    @ObservedObject private var audio = AudioOutputs.shared
    @Environment(\.accent) private var accent
    @State private var open = false

    var body: some View {
        let routed = audio.currentSymbol != "laptopcomputer"
        Button { open.toggle() } label: {
            Image(systemName: audio.currentSymbol)
                .font(.system(size: compact ? 12 : 14, weight: .semibold))
                .foregroundStyle(routed ? accent : .white.opacity(0.75))
                .frame(width: compact ? 22 : 26, height: 22)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableStyle())
        .help(audio.currentName.isEmpty ? "Sound output" : "Playing on \(audio.currentName)")
        .accessibilityLabel("Sound output: \(audio.currentName)")
        .popover(isPresented: $open, arrowEdge: .bottom) { AudioOutputPicker() }
        .onAppear { audio.start() }
    }
}

struct AudioOutputPicker: View {
    @ObservedObject private var audio = AudioOutputs.shared
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sound Output")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .padding(.horizontal, 10).padding(.bottom, 4)
            ForEach(audio.outputs) { row($0) }
            if !audio.paired.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Bluetooth")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                ForEach(audio.paired) { row($0) }
            }
            Divider().padding(.vertical, 4)
            Button("Sound Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
        }
        .padding(10)
        .frame(width: 280)
        .onAppear { audio.refresh(includeBluetooth: true) }
    }

    private func row(_ o: AudioOutput) -> some View {
        Button { audio.select(o) } label: {
            HStack(spacing: 10) {
                Image(systemName: o.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(o.isCurrent ? accent : Color.primary.opacity(0.1)))
                    .foregroundStyle(o.isCurrent ? Color.black : Color.primary)
                Text(o.name)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if case .bluetoothPaired(let address) = o.kind {
                    if audio.connecting == address {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                } else if o.isCurrent {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .disabled(audio.connecting != nil)
        .accessibilityLabel(o.name + (o.isCurrent ? ", selected" : ""))
    }
}

// MARK: - Redirect

/// Four shortcuts to favourite apps: click one to jump straight to it. Empty slots ask for an app;
/// right-click a shortcut to change or remove it.
struct RedirectWidget: View {
    let size: BlockSize
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        GeometryReader { geo in
            let n = min(4, max(1, settings.config.redirectCount))
            let w = geo.size.width, h = geo.size.height
            let header: CGFloat = h < 200 ? 0 : 26
            let avail = CGSize(width: w, height: max(1, h - header))
            let layout = Self.layout(count: n, in: avail)
            VStack(alignment: .leading, spacing: 0) {
                if header > 0 {
                    HStack {
                        WidgetHeader(symbol: "arrow.up.forward.app", title: "Redirect")
                        Spacer()
                        IconStyleButton()
                    }
                    .frame(height: header, alignment: .top)
                }
                VStack(spacing: 0) {
                    ForEach(0..<layout.rows, id: \.self) { r in
                        HStack(spacing: 0) {
                            // A short last row stays centred.
                            ForEach(Array(stride(from: r * layout.cols, to: min(n, (r + 1) * layout.cols), by: 1)), id: \.self) { i in
                                AppSlot(index: i, side: layout.cell)
                                    .frame(width: avail.width / CGFloat(layout.cols), height: avail.height / CGFloat(layout.rows))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: n)
            }
        }
    }

    /// The grid (columns × rows) that gives each of `n` icons the most room in this tile.
    static func layout(count n: Int, in size: CGSize) -> (cols: Int, rows: Int, cell: CGFloat) {
        var best = (cols: n, rows: 1, cell: CGFloat(0))
        for cols in 1...n {
            let rows = Int(ceil(Double(n) / Double(cols)))
            let cell = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
            if cell > best.cell + 0.5 { best = (cols, rows, cell) }
        }
        return best
    }
}

/// Cycles the icon appearance: Theme → Dark → Clear → Original.
struct IconStyleButton: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let style = settings.config.redirectIconStyle
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { settings.config.redirectIconStyle = style.next }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: style.symbol).contentTransition(.symbolEffect(.replace))
                Text(style.title)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.1)))
        }
        .buttonStyle(PressableStyle(scale: 0.95))
        .help("Icon style: \(style.title) (click to change)")
    }
}

/// Pulls the glyph out of an app icon: every pixel is scored by how far its colour is from the icon's
/// background, giving a white mask (alpha = glyph strength) that can be tinted or laid on glass.
@MainActor
enum IconGlyph {
    private static var cache: [String: CGImage] = [:]

    static func mask(for path: String) -> CGImage? {
        if let hit = cache[path] { return hit }
        let n = 256
        let icon = NSWorkspace.shared.icon(forFile: path)
        var rect = CGRect(x: 0, y: 0, width: n, height: n)
        guard let source = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: n, height: n))
        let px = data.bindMemory(to: UInt8.self, capacity: n * n * 4)

        typealias RGBA = (r: Double, g: Double, b: Double, a: Double)
        func at(_ x: Int, _ y: Int) -> RGBA {
            let i = (y * n + x) * 4
            let a = Double(px[i + 3]) / 255
            guard a > 0.01 else { return (0, 0, 0, 0) }
            return (Double(px[i]) / 255 / a, Double(px[i + 1]) / 255 / a, Double(px[i + 2]) / 255 / a, a)
        }
        func distance(_ p: RGBA, _ q: RGBA) -> Double {
            ((p.r - q.r) * (p.r - q.r) + (p.g - q.g) * (p.g - q.g) + (p.b - q.b) * (p.b - q.b)).squareRoot()
        }

        // The background is whichever of four just-inside-the-edge samples agrees most with the others.
        let m = Int(Double(n) * 0.13), mid = n / 2
        let samples = [at(mid, m), at(mid, n - 1 - m), at(m, mid), at(n - 1 - m, mid)]
        let bg = samples.min { a, b in
            samples.reduce(0) { $0 + distance(a, $1) } < samples.reduce(0) { $0 + distance(b, $1) }
        } ?? (1, 1, 1, 1)
        let solidBackground = bg.a > 0.5

        // macOS icons sit on an 824/1024 square in the middle; ignore the drop shadow outside it.
        let lo = Int(Double(n) * 0.09), hi = Int(Double(n) * 0.91)
        var out = [UInt8](repeating: 0, count: n * n * 4)
        for y in lo..<hi {
            for x in lo..<hi {
                let p = at(x, y)
                guard p.a > 0.01 else { continue }
                let v = solidBackground ? min(1, max(0, (distance(p, bg) - 0.07) / 0.3)) * p.a : p.a
                let byte = UInt8(max(0, min(255, v * 255)))
                let i = (y * n + x) * 4
                out[i] = byte; out[i + 1] = byte; out[i + 2] = byte; out[i + 3] = byte
            }
        }
        let image: CGImage? = out.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        if let image { cache[path] = image }
        return image
    }
}

/// An app icon drawn in the chosen appearance, like iPhone's icon styles.
struct StyledAppIcon: View {
    let path: String
    let size: CGFloat
    let style: AppIconStyle
    @Environment(\.accent) private var accent

    var body: some View {
        let original = Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high)
        // macOS icons sit on an 824/1024 rounded square in the middle of the image.
        let plateSide = size * 0.805
        let plate = RoundedRectangle(cornerRadius: plateSide * 0.225, style: .continuous)
        let mask = style == .original ? nil : IconGlyph.mask(for: path)
        ZStack {
            if style == .original || mask == nil {
                original
            } else if let mask {
                let glyph = Image(decorative: mask, scale: 1).resizable().interpolation(.high)
                switch style {
                case .theme:
                    // Dark plate, glyph glowing in the theme colour.
                    plate
                        .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                        .overlay(plate.strokeBorder(.white.opacity(0.08), lineWidth: 1))
                        .frame(width: plateSide, height: plateSide)
                    LinearGradient(colors: [accent, accent.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                        .mask(glyph)
                case .dark:
                    // Dark plate, the glyph keeps its own colours.
                    plate
                        .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                        .overlay(plate.strokeBorder(.white.opacity(0.08), lineWidth: 1))
                        .frame(width: plateSide, height: plateSide)
                    original.mask(glyph)
                case .clear, .original:
                    // Frosted glass with a white glyph.
                    plate
                        .fill(.white.opacity(0.12))
                        .overlay(plate.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.08)],
                                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
                        .frame(width: plateSide, height: plateSide)
                    Color.white.opacity(0.92).mask(glyph)
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(style == .clear ? 0.12 : 0.3), radius: size * 0.08, y: size * 0.04)
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: style)
    }
}

struct AppSlot: View {
    let index: Int
    let side: CGFloat
    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false
    @State private var launched = false

    /// The chosen app, if it's still installed.
    private var path: String? { settings.redirectPath(index) }

    var body: some View {
        let showName = side >= 96
        let icon = min(240, side * (showName ? 0.6 : 0.74))
        Button {
            if let path { open(path) } else { settings.chooseRedirectApp(slot: index) }
        } label: {
            VStack(spacing: side * 0.05) {
                if let path {
                    StyledAppIcon(path: path, size: icon, style: settings.config.redirectIconStyle)
                        .scaleEffect(launched ? 0.82 : (hovering ? 1.08 : 1))
                    if showName {
                        Text(name(path))
                            .font(.system(size: max(10, min(18, side * 0.1)), weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                } else {
                    let shape = RoundedRectangle(cornerRadius: icon * 0.22, style: .continuous)
                    Image(systemName: "plus")
                        .font(.system(size: icon * 0.28, weight: .semibold))
                        .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.6))
                        .frame(width: icon * 0.84, height: icon * 0.84)
                        .background(shape.fill(.white.opacity(hovering ? 0.14 : 0.06)))
                        .overlay(shape.strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                        .frame(width: icon, height: icon)
                    if showName {
                        Text("Add app")
                            .font(.system(size: max(10, min(14, side * 0.1)), weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h } }
        .contextMenu {
            Button(path == nil ? "Choose App…" : "Change App…") { settings.chooseRedirectApp(slot: index) }
            if path != nil {
                Button("Remove Shortcut", role: .destructive) { settings.setRedirectApp(slot: index, path: nil) }
            }
            Divider()
            Picker("Icon Style", selection: Binding(get: { settings.config.redirectIconStyle },
                                                    set: { settings.config.redirectIconStyle = $0 })) {
                ForEach(AppIconStyle.allCases) { Text($0.title).tag($0) }
            }
        }
        .help(path.map { "Open \(name($0)) · change it from Edit Blocks" } ?? "Choose an app for this shortcut")
        .accessibilityLabel(path.map { "Open \(name($0))" } ?? "Add an app shortcut")
    }

    private func name(_ path: String) -> String { AppSettings.appName(path) }

    private func open(_ path: String) {
        withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { launched = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { launched = false }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { _, _ in }
    }
}
