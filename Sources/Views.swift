import SwiftUI
import AppKit

// MARK: - Glass
//
// Real Liquid Glass (macOS 26+). One setting runs from Clear — the see-through glass that shows the
// wallpaper, like Apple's "Clear" appearance — to Tinted, which frosts and colours the glass so text
// reads over busy photos. Older systems fall back to a material.

struct GlassStyle {
    let tint: Double          // 0 clear … 1 tinted
    let accent: Color

    /// Darkening layer laid over the glass for legibility; grows with tint.
    var dim: Double { 0.03 + 0.32 * tint }

    @available(macOS 26.0, *)
    var glass: Glass {
        (tint < 0.5 ? Glass.clear : Glass.regular).tint(accent.opacity(0.04 + 0.26 * tint))
    }
}

struct GlassBackground<S: InsettableShape>: View {
    let shape: S
    var highlighted = false
    var shadow = true
    var fixedTint: Double? = nil
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accent) private var accent

    var body: some View {
        let style = GlassStyle(tint: fixedTint ?? settings.config.glassTint, accent: accent)
        Group {
            if #available(macOS 26.0, *) {
                shape
                    .fill(Color.black.opacity(style.dim))
                    .glassEffect(style.glass, in: shape)
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(Color.black.opacity(0.1 + style.dim)))
                    .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 1))
            }
        }
        .overlay {
            if highlighted { shape.strokeBorder(.white.opacity(0.75), lineWidth: 2) }
        }
        .shadow(color: .black.opacity(shadow ? 0.12 + 0.16 * style.tint : 0), radius: 24, y: 12)
        .animation(.easeInOut(duration: 0.3), value: style.tint)
    }
}

struct GlassCard: View {
    var radius: CGFloat = 34
    var highlighted = false
    /// Panels pass 1 so they stay frosted and readable whatever the tiles are set to.
    var fixedTint: Double? = nil

    var body: some View {
        GlassBackground(shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                        highlighted: highlighted, fixedTint: fixedTint)
    }
}

struct GlassCapsuleLabel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(GlassBackground(shape: Capsule(), shadow: false))
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var np: NowPlayingService
    @EnvironmentObject private var ui: UIState
    @EnvironmentObject private var timer: FocusTimer
    @EnvironmentObject private var awake: DisplayAwake
    @State private var engine = BackgroundEngine()
    @State private var monitor: Any?

    var body: some View {
        let accent = settings.accent(adaptive: np.artPalette).color
        GeometryReader { geo in
            ZStack {
                LiveBackground(engine: engine)

                PagerHost(controller: ui.pager, accent: accent, pages: { pagesRoot(accent) })

                topBar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 14).padding(.trailing, 20)
                    .opacity(chromeShown ? 1 : 0)
                    .allowsHitTesting(chromeShown)

                bottomBar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 12)

                if ui.showCustomize {
                    // Non-blocking panel: no dimming scrim; clicking outside closes it.
                    Color.black.opacity(0.001)
                        .onTapGesture { ui.toggleCustomize() }
                }
                // The panel is built once and stays mounted; showing it only animates scale and
                // opacity (compositor work), so nothing is constructed mid-animation.
                CustomizePanel()
                    .frame(width: 360)
                    .frame(maxHeight: geo.size.height - 80)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(ui.showCustomize ? 1 : 0.88, anchor: .topTrailing)
                    .opacity(ui.showCustomize ? 1 : 0)
                    .offset(y: ui.showCustomize ? 0 : -6)
                    .allowsHitTesting(ui.showCustomize)
                    .accessibilityHidden(!ui.showCustomize)
                    .padding(.top, 58).padding(.trailing, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .zIndex(2)

                if timer.ringing {
                    AlarmOverlay()
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 1.08)),
                            removal: .opacity.combined(with: .scale(scale: 0.96))))
                        .zIndex(10)
                }
            }
        }
        .ignoresSafeArea()
        .environment(\.accent, accent)
        .tint(accent)
        .onAppear {
            np.start()
            awake.start(mode: settings.config.keepAwake)
            installMonitor()
            ui.poke()
        }
        .onChange(of: settings.config.keepAwake) { _, mode in awake.mode = mode }
        .onChange(of: timer.ringing) { _, ringing in
            if ringing { AlarmWindows.shared.show(timer: timer, accent: accent) } else { AlarmWindows.shared.hide() }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    /// The pages live in their own hosting view, so they need the environment handed over explicitly.
    private func pagesRoot(_ accent: Color) -> AnyView {
        AnyView(
            PagesRow()
                .environmentObject(settings)
                .environmentObject(np)
                .environmentObject(ui)
                .environmentObject(timer)
                .environmentObject(awake)
                .environment(\.accent, accent)
                .tint(accent)
                .preferredColorScheme(.dark)
        )
    }

    private var chromeShown: Bool { ui.chromeVisible || ui.editing || ui.showCustomize }

    private var topBar: some View {
        HStack(spacing: 10) {
            NowPlayingButton()
            Button { ui.toggleEditing() } label: {
                GlassCapsuleLabel {
                    Label(ui.editing ? "Done" : "Edit Blocks", systemImage: ui.editing ? "checkmark" : "square.grid.2x2")
                }
            }
            .buttonStyle(PressableStyle(scale: 0.95))
            .help("Rearrange, add and change the blocks (E)")
            Button { ui.toggleCustomize() } label: {
                GlassCapsuleLabel { Image(systemName: "slider.horizontal.3") }
            }
            .buttonStyle(PressableStyle(scale: 0.95))
            .help("Theme, texture, photo and motion (C)")
            .accessibilityLabel("Customize")
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if ui.editing {
            GlassCapsuleLabel {
                HStack(spacing: 12) {
                    Text(settings.newTileSlot == nil
                         ? "Drag tiles anywhere · click a label to change it or its size"
                         : "Drag tiles anywhere · click a label to change it · + adds a tile")
                        .foregroundStyle(.white.opacity(0.75))
                    Button { ui.toggleEditing() } label: {
                        Text("Done")
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(PressableStyle(scale: 0.95))
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            PageDots()
                .opacity(chromeShown ? 1 : 0)
                .transition(.opacity)
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .scrollWheel, .mouseMoved, .leftMouseDragged]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [engine, ui, np, settings, timer] event in
            // Local monitors always run on the main thread. NSEvent isn't Sendable, so the result
            // leaves assumeIsolated in a box instead of as a bare NSEvent (a Swift 6 error otherwise).
            MainActor.assumeIsolated { () -> MainThreadBox<NSEvent?> in
                @MainActor func handle() -> NSEvent? {
                    @MainActor func normalized() -> CGPoint? {
                        guard let view = event.window?.contentView else { return nil }
                        let b = view.bounds, p = event.locationInWindow
                        return CGPoint(x: p.x / max(1, b.width), y: 1 - p.y / max(1, b.height))
                    }
                    switch event.type {
                    case .scrollWheel:
                        return ui.handleScroll(event) ? nil : event
                    case .mouseMoved, .leftMouseDragged:
                        engine.pointerTarget = normalized()
                        ui.poke()
                        return event
                    case .leftMouseDown:
                        if let p = normalized() { engine.addRipple(p) }
                        ui.poke()
                        return event
                    default: break
                    }

                    // While the alarm rings, the keyboard answers it first.
                    if timer.ringing {
                        switch event.keyCode {
                        case 49, 36, 76:                                    // space, return, enter
                            if timer.nextPhase != nil { timer.continueCycle() } else { timer.stopAlarm() }
                            return nil
                        case 53: timer.stopAlarm(); return nil              // esc
                        default:
                            if event.charactersIgnoringModifiers?.lowercased() == "s" { timer.snooze(); return nil }
                            return nil
                        }
                    }

                    if event.window?.firstResponder is NSTextView { return event }
                    if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
                    ui.poke()
                    switch event.keyCode {
                    case 123: ui.go(-1); return nil
                    case 124: ui.go(1); return nil
                    case 49: np.togglePlay(); return nil
                    case 126 where ui.page == 1 && !ui.editing: ui.cycleFont(settings, -1); return nil
                    case 125 where ui.page == 1 && !ui.editing: ui.cycleFont(settings, 1); return nil
                    case 53:
                        if ui.showCustomize || ui.editing { ui.closeAll(); return nil }
                        return event
                    default: break
                    }
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "e": ui.toggleEditing(); return nil
                    case "c": ui.toggleCustomize(); return nil
                    case "n": ui.jump(to: 2); return nil
                    case "1", "2", "3":
                        ui.jump(to: Int(event.charactersIgnoringModifiers!)! - 1); return nil
                    default: return event
                    }
                }
                return MainThreadBox(value: handle())
            }.value
        }
    }
}

/// Carries a non-Sendable value out of `MainActor.assumeIsolated` on the main thread.
struct MainThreadBox<Value>: @unchecked Sendable {
    let value: Value
}

// MARK: - Pager host

struct PagesRow: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / CGFloat(UIState.pageCount)
            HStack(spacing: 0) {
                DashboardPage().frame(width: w, height: geo.size.height)
                ClockPage().frame(width: w, height: geo.size.height)
                NowPlayingPage().frame(width: w, height: geo.size.height)
            }
        }
    }
}

/// Hosts all pages in one wide layer-backed view that the PagerController moves directly.
struct PagerHost: NSViewRepresentable {
    let controller: PagerController
    let accent: Color
    let pages: () -> AnyView

    func makeNSView(context: Context) -> PagerContainer {
        let view = PagerContainer(controller: controller, root: pages())
        view.accent = accent
        return view
    }

    // The pages observe their own data; the root is only rebuilt when the handed-down accent changes,
    // so Now Playing polls never re-render the whole strip.
    func updateNSView(_ view: PagerContainer, context: Context) {
        guard view.accent != accent else { return }
        view.accent = accent
        view.hosting.rootView = pages()
    }
}

final class PagerContainer: NSView {
    let content = NSView()
    let hosting: NSHostingView<AnyView>
    private let controller: PagerController
    var accent: Color?

    init(controller: PagerController, root: AnyView) {
        self.controller = controller
        hosting = NSHostingView(rootView: root)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        content.wantsLayer = true
        hosting.sizingOptions = []
        addSubview(content)
        content.addSubview(hosting)
        controller.content = content
        controller.container = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let size = NSSize(width: bounds.width * CGFloat(UIState.pageCount), height: bounds.height)
        if content.frame.size != size {
            content.setFrameSize(size)
            hosting.frame = NSRect(origin: .zero, size: size)
        }
        controller.layout(width: bounds.width)
    }
}

// MARK: - Alarm

/// Full-screen alarm when the timer ends: heavy type, big Snooze/Stop targets, and a glow that breathes.
/// The alarm pops up in its own borderless window on every display, above every app and on whatever
/// Space you're in (even another app's full screen), because macOS won't let Idle Mode pull itself forward.
@MainActor
final class AlarmWindows {
    static let shared = AlarmWindows()
    private var windows: [NSWindow] = []
    /// macOS only lets an app's windows into another app's full-screen Space while it's an
    /// "accessory" app, so Idle Mode becomes one for as long as the alarm is up.
    private var switchedPolicy = false

    /// A borderless panel that can take the keyboard (Space / Return / Esc) without switching Spaces.
    private final class AlarmPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    func show(timer: FocusTimer, accent: Color) {
        hide()
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
            switchedPolicy = true
        }
        for screen in NSScreen.screens {
            let panel = AlarmPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false

            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            let host = NSHostingView(rootView: AlarmOverlay()
                .environmentObject(timer)
                .environment(\.accent, accent)
                .preferredColorScheme(.dark))
            host.frame = blur.bounds
            host.autoresizingMask = [.width, .height]
            blur.addSubview(host)
            panel.contentView = blur
            panel.setFrame(screen.frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                panel.animator().alphaValue = 1
            }
            windows.append(panel)
        }
        // The panel on the screen with the pointer takes the keyboard.
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
    }

    func hide() {
        let closing = windows
        windows = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            Task { @MainActor in
                closing.forEach { $0.orderOut(nil) }
                if self.switchedPolicy && self.windows.isEmpty {
                    self.switchedPolicy = false
                    NSApp.setActivationPolicy(.regular)
                }
            }
        })
    }
}

struct AlarmOverlay: View {
    @EnvironmentObject private var timer: FocusTimer
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSince(timer.ringStarted)
            let pulse = reduceMotion ? 0 : (0.5 + 0.5 * sin(t * 2 * .pi / 1.2))
            GeometryReader { geo in
                let big = min(geo.size.width * 0.14, geo.size.height * 0.24)
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Color.black.opacity(0.45)
                    RadialGradient(colors: [accent.opacity(0.35 + 0.25 * pulse), .clear], center: .center,
                                   startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * (0.45 + 0.05 * pulse))
                        .blendMode(.plusLighter)

                    VStack(spacing: big * 0.12) {
                        Image(systemName: "alarm.fill")
                            .font(.system(size: big * 0.42, weight: .bold))
                            .foregroundStyle(accent)
                            .rotationEffect(.degrees(reduceMotion ? 0 : sin(t * 2 * .pi * 3) * 9 * pulse))
                        Text(timer.nextPhase == .rest ? "BREAK TIME" : (timer.nextPhase == .focus ? "BACK TO FOCUS" : "TIME'S UP"))
                            .font(.system(size: big, weight: .black, design: .rounded))
                            .tracking(-big * 0.03)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .scaleEffect(1 + 0.025 * pulse)
                        Text(timer.nextPhase != nil
                             ? "\(timer.nextPhase == .rest ? "Break" : "Focus") of \(timer.nextPhaseMinutes) min starts in \(max(0, 20 - Int(t)))s"
                             : "\(timer.minutes) min timer · \(formatDuration(t)) ago")
                            .font(.system(size: max(18, big * 0.2), weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.65))

                        HStack(spacing: 20) {
                            if timer.nextPhase != nil {
                                Button { timer.stopAlarm() } label: {
                                    Label("Stop", systemImage: "stop.fill")
                                        .font(.system(size: max(20, big * 0.2), weight: .heavy, design: .rounded))
                                        .padding(.horizontal, 40).padding(.vertical, 22)
                                        .background(Capsule().fill(.white.opacity(0.16)))
                                        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                                }
                                .buttonStyle(PressableStyle(scale: 0.95))
                                Button { timer.continueCycle() } label: {
                                    Label(timer.nextPhase == .rest ? "Start Break" : "Start Focus",
                                          systemImage: timer.nextPhase == .rest ? "cup.and.saucer.fill" : "play.fill")
                                        .font(.system(size: max(20, big * 0.2), weight: .heavy, design: .rounded))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 56).padding(.vertical, 22)
                                        .background(Capsule().fill(accent))
                                }
                                .buttonStyle(PressableStyle(scale: 0.95))
                            } else {
                            Button { timer.snooze() } label: {
                                Label("Snooze 5 min", systemImage: "zzz")
                                    .font(.system(size: max(20, big * 0.2), weight: .heavy, design: .rounded))
                                    .padding(.horizontal, 40).padding(.vertical, 22)
                                    .background(Capsule().fill(.white.opacity(0.16)))
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                            }
                            .buttonStyle(PressableStyle(scale: 0.95))
                            .keyboardShortcut("s", modifiers: [])

                            Button { timer.stopAlarm() } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .font(.system(size: max(20, big * 0.2), weight: .heavy, design: .rounded))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 56).padding(.vertical, 22)
                                    .background(Capsule().fill(accent))
                            }
                            .buttonStyle(PressableStyle(scale: 0.95))
                            }
                        }
                        .padding(.top, big * 0.2)

                        Text(timer.nextPhase != nil ? "Space or Return to start now · Esc to stop" : "Space or Return to stop · S to snooze")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(40)
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Now Playing button

struct NowPlayingButton: View {
    @EnvironmentObject private var np: NowPlayingService
    @EnvironmentObject private var ui: UIState
    @Environment(\.accent) private var accent

    var body: some View {
        Button {
            ui.jump(to: ui.page == 2 ? 0 : 2)
        } label: {
            GlassCapsuleLabel {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: np.track?.isPlaying == true)
                        .foregroundStyle(np.track == nil ? Color.white.opacity(0.6) : accent)
                    Text("Now Playing")
                    if let t = np.track {
                        Text(t.title)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .frame(maxWidth: 200, alignment: .leading)
                            .transition(.opacity)
                    }
                }
            }
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .help(np.track.map { $0.sourceLabel } ?? "Plays from Chrome, YouTube and other browser tabs (N)")
        .animation(.spring(response: 0.4, dampingFraction: 1), value: np.track?.title)
    }
}

struct PageDots: View {
    @EnvironmentObject private var ui: UIState
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<UIState.pageCount, id: \.self) { i in
                let on = ui.page == i
                Button { ui.jump(to: i) } label: {
                    Capsule()
                        .fill(.white.opacity(on ? 0.9 : 0.3))
                        .frame(width: on ? 20 : 7, height: 7)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(["Blocks", "Clock", "Now Playing"][i])
            }
        }
        .padding(.horizontal, 12)
        .background(GlassBackground(shape: Capsule(), shadow: false))
        .animation(.spring(response: 0.35, dampingFraction: 1), value: ui.page)
    }
}

// MARK: - Page 1: five blocks

/// Cell geometry for the 6×4 home grid.
struct GridMetrics {
    let size: CGSize
    let gap: CGFloat = 16
    var cellW: CGFloat { (size.width - gap * CGFloat(GridLayout.cols - 1)) / CGFloat(GridLayout.cols) }
    var cellH: CGFloat { (size.height - gap * CGFloat(GridLayout.rows - 1)) / CGFloat(GridLayout.rows) }
    var stepX: CGFloat { cellW + gap }
    var stepY: CGFloat { cellH + gap }

    func rect(_ b: Block) -> CGRect {
        CGRect(x: CGFloat(b.col) * stepX, y: CGFloat(b.row) * stepY,
               width: CGFloat(b.w) * cellW + CGFloat(b.w - 1) * gap,
               height: CGFloat(b.h) * cellH + CGFloat(b.h - 1) * gap)
    }
}

struct DashboardPage: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState

    /// The tile being carried: where it was grabbed, where it is now, and the live reflowed layout.
    private struct Carry {
        let id: UUID
        let grab: CGSize
        var origin: CGPoint
        var layout: [Block]
    }
    @State private var carry: Carry?

    var body: some View {
        GeometryReader { geo in
            let m = GridMetrics(size: geo.size)
            let blocks = carry?.layout ?? settings.config.blocks

            ZStack(alignment: .topLeading) {
                // Where the carried tile will land.
                if let c = carry, let b = blocks.first(where: { $0.id == c.id }) {
                    let r = m.rect(b)
                    RoundedRectangle(cornerRadius: b.size == .large ? 38 : 32, style: .continuous)
                        .strokeBorder(.white.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [8, 7]))
                        .background(RoundedRectangle(cornerRadius: b.size == .large ? 38 : 32, style: .continuous).fill(.white.opacity(0.06)))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .transition(.opacity)
                }

                // Free space on the page: offer a new tile there.
                if ui.editing, carry == nil, let slot = settings.newTileSlot {
                    let r = m.rect(slot)
                    AddTileGhost(mini: slot.w * slot.h <= 1)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                ForEach(Array(blocks.enumerated()), id: \.element.id) { i, b in
                    let r = m.rect(b)
                    let lifted = carry?.id == b.id
                    let origin = lifted ? (carry?.origin ?? r.origin) : r.origin
                    BlockView(block: b, index: i, size: b.size, lifted: lifted)
                        .frame(width: r.width, height: r.height)
                        .offset(x: origin.x, y: origin.y)
                        .zIndex(lifted ? 10 : 0)
                        .gesture(carryGesture(b, m), including: ui.editing ? .all : .subviews)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: "grid")
        }
        .padding(.horizontal, 28)
        .padding(.top, 62)
        .padding(.bottom, 44)
    }

    /// Pick up a tile: it follows the pointer 1:1 from where it was grabbed; the rest reflow around
    /// the cell under it; on release it springs into that cell.
    private func carryGesture(_ b: Block, _ m: GridMetrics) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("grid"))
            .onChanged { v in
                if carry == nil {
                    let r = m.rect(b)
                    withAnimation(.spring(response: 0.28, dampingFraction: 1)) {
                        carry = Carry(id: b.id,
                                      grab: CGSize(width: v.startLocation.x - r.minX, height: v.startLocation.y - r.minY),
                                      origin: r.origin, layout: settings.config.blocks)
                    }
                }
                guard var c = carry, let i = c.layout.firstIndex(where: { $0.id == c.id }) else { return }
                c.origin = CGPoint(x: v.location.x - c.grab.width, y: v.location.y - c.grab.height)
                let tile = c.layout[i]
                let col = min(GridLayout.cols - tile.w, max(0, Int((c.origin.x / m.stepX).rounded())))
                let row = min(GridLayout.rows - tile.h, max(0, Int((c.origin.y / m.stepY).rounded())))
                if col != tile.col || row != tile.row {
                    var candidate = c.layout
                    candidate[i].col = col
                    candidate[i].row = row
                    if let packed = GridLayout.reflow(candidate, pinned: i) {
                        c.layout = packed
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { carry = c }
                        return
                    }
                }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { carry = c }
            }
            .onEnded { _ in
                guard let c = carry else { return }
                // A little bounce here is earned: the tile was thrown into place.
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    settings.config.blocks = c.layout
                    carry = nil
                }
            }
    }
}

struct BlockView: View {
    let block: Block
    let index: Int
    let size: BlockSize
    var lifted = false
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mini: Bool { block.w * block.h <= 1 }
    private var radius: CGFloat { size == .large ? 38 : (mini ? 26 : 32) }

    var body: some View {
        WidgetView(kind: block.kind, size: size)
            .padding(size == .large ? 28 : (mini ? 14 : 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Nothing a widget draws may spill past its tile.
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(ui.editing ? 0.45 : 1)
            .allowsHitTesting(!ui.editing)
            .background(GlassCard(radius: radius, highlighted: lifted))
            .overlay(alignment: .topLeading) {
                if ui.editing {
                    KindMenu(index: index, block: block)
                        .padding(mini ? 10 : 14)
                        .transition(.scale(scale: 0.8, anchor: .topLeading).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                if ui.editing && settings.config.blocks.count > 1 {
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { settings.removeTile(at: index) }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.black.opacity(0.8))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.white.opacity(0.9)))
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    }
                    .buttonStyle(PressableStyle())
                    .padding(mini ? 8 : 12)
                    .help("Remove this tile")
                    .accessibilityLabel("Remove \(block.kind.title) tile")
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .scaleEffect(lifted ? 1.05 : (ui.editing ? 0.965 : 1))
            .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: lifted ? 30 : 0, y: lifted ? 18 : 0)
            .modifier(Wiggle(active: ui.editing && !lifted && !reduceMotion, seed: index))
            .simultaneousGesture(
                // Long-press any block to start editing, like StandBy on iPhone.
                LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                    if !ui.editing { ui.toggleEditing() }
                },
                including: ui.editing ? .subviews : .all
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: ui.editing)
            .animation(.spring(response: 0.28, dampingFraction: 1), value: lifted)
    }
}

/// The dashed "+" placeholder shown in free space while editing; click it to pick a tile.
struct AddTileGhost: View {
    let mini: Bool
    @State private var picking = false
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: mini ? 26 : 32, style: .continuous)
        Button { picking = true } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: mini ? 20 : 26, weight: .semibold))
                    .frame(width: mini ? 44 : 56, height: mini ? 44 : 56)
                    .background(Circle().fill(.white.opacity(hovering ? 0.22 : 0.14)))
                Text("Add Tile")
                    .font(.system(size: mini ? 12 : 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(.white.opacity(hovering ? 0.1 : 0.05)))
            .overlay(shape.strokeBorder(.white.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [8, 7])))
            .contentShape(shape)
            .scaleEffect(hovering ? 1.015 : 1)
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 1)) { hovering = h } }
        .popover(isPresented: $picking, arrowEdge: .bottom) { AddTilePicker(isPresented: $picking, mini: mini) }
        .help("Add a tile in this free space")
    }
}

struct AddTilePicker: View {
    @Binding var isPresented: Bool
    let mini: Bool
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let onPage = Set(settings.config.blocks.map(\.kind))
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a tile")
                .font(.system(size: 13, weight: .bold, design: .rounded))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(WidgetKind.allCases) { k in
                    Button {
                        isPresented = false
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { settings.addTile(k) }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: k.symbol).font(.system(size: 18, weight: .medium))
                            Text(k.title).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 62)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(onPage.contains(k) ? 0.05 : 0.1)))
                        .overlay(alignment: .topTrailing) {
                            if onPage.contains(k) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .padding(5)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.95))
                }
            }
            Text(mini ? "There's room for a Mini (1×1) tile here." : "Adds a Small (2×2) tile. You can resize it after.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
    }
}

struct KindMenu: View {
    let index: Int
    let block: Block
    @EnvironmentObject private var settings: AppSettings

    private var mini: Bool { block.w * block.h <= 1 }

    private func sizeTitle(_ shape: TileShape, _ fit: AppSettings.ResizeFit) -> String {
        let base = "\(shape.title) (\(shape.cells.w)×\(shape.cells.h))"
        switch fit {
        case .fits: return base
        case .shrinksOthers: return base + " – makes the other tiles Mini"
        case .noRoom: return base + " – no room"
        }
    }

    var body: some View {
        Menu {
            ForEach(WidgetKind.allCases) { k in
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 1)) { settings.setKind(k, at: index) }
                } label: {
                    Label(k.title, systemImage: k == block.kind ? "checkmark" : k.symbol)
                }
            }
            if block.kind == .redirect {
                Divider()
                Section("Shortcuts") {
                    Picker("Number of Apps", selection: Binding(get: { settings.config.redirectCount },
                                                                set: { n in withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { settings.config.redirectCount = n } })) {
                        ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                    }
                    ForEach(0..<min(4, max(1, settings.config.redirectCount)), id: \.self) { i in
                        let path = settings.redirectPath(i)
                        Menu(path.map { "\(i + 1). \(AppSettings.appName($0))" } ?? "\(i + 1). Empty") {
                            Button(path == nil ? "Choose App…" : "Change App…") { settings.chooseRedirectApp(slot: i) }
                            if path != nil {
                                Button("Remove") { settings.setRedirectApp(slot: i, path: nil) }
                            }
                        }
                    }
                    Picker("Icon Style", selection: Binding(get: { settings.config.redirectIconStyle },
                                                            set: { s in withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { settings.config.redirectIconStyle = s } })) {
                        ForEach(AppIconStyle.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            Divider()
            Section("Size") {
                ForEach(TileShape.allCases) { shape in
                    let current = shape.cells.w == block.w && shape.cells.h == block.h
                    let fit: AppSettings.ResizeFit = current ? .fits : settings.fit(index, to: shape)
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { _ = settings.resize(index, to: shape) }
                    } label: {
                        Label(sizeTitle(shape, fit), systemImage: current ? "checkmark" : shape.symbol)
                    }
                    .disabled(fit == .noRoom)
                }
            }
        } label: {
            if mini {
                Image(systemName: block.kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
            } else {
                Label(block.kind.title, systemImage: block.kind.symbol)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .controlSize(mini ? .small : .regular)
        .fixedSize()
        .help("Change this tile or its size")
    }
}

struct Wiggle: ViewModifier {
    let active: Bool
    let seed: Int

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !active)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            content.rotationEffect(.degrees(active ? sin(t * 8 + Double(seed) * 1.9) * 0.5 : 0))
        }
    }
}

// MARK: - Page 2: clock

struct ClockPage: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var np: NowPlayingService
    @EnvironmentObject private var ui: UIState
    @Environment(\.accent) private var accent

    var body: some View {
        let font = settings.config.clockFont
        // Next font slides in from below, previous from above — the content moves the way the arrow points.
        let edge: Edge = ui.fontDirection > 0 ? .bottom : .top

        VStack(spacing: 0) {
            arrow("chevron.up", "Previous font") { ui.cycleFont(settings, -1) }

            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                GeometryReader { geo in
                    let parts = ClockFormat.parts(ctx.date, use24h: settings.config.use24h, seconds: settings.config.showSeconds)
                    let fs = min(geo.size.height * 0.5, geo.size.width / (CGFloat(max(parts.time.count, 4)) * font.widthFactor + 0.6))
                    VStack(spacing: 6) {
                        Text(ctx.date.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                            .font(.system(size: max(14, fs * 0.09), weight: .bold, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(accent)
                        HStack(alignment: .firstTextBaseline, spacing: fs * 0.05) {
                            Text(parts.time)
                                .font(font.font(fs))
                                .monospacedDigit()
                                .tracking(fs * font.tracking)
                                .contentTransition(.numericText())
                                .lineLimit(1)
                                .minimumScaleFactor(0.4)
                            if let ampm = parts.ampm {
                                Text(ampm)
                                    .font(.system(size: fs * 0.14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
                        .id(font)
                        .transition(.push(from: edge))
                        if let t = np.track {
                            HStack(spacing: 8) {
                                Image(systemName: "waveform")
                                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: t.isPlaying == true)
                                    .foregroundStyle(accent)
                                Text("\(t.title) — \(t.artist)").lineLimit(1)
                            }
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(maxWidth: geo.size.width * 0.6)
                            .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .animation(.spring(response: 0.45, dampingFraction: 1), value: parts.time)
                }
            }

            ZStack {
                // The font's name shows briefly after each change.
                Text(font.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(GlassBackground(shape: Capsule(), shadow: false))
                    .opacity(ui.chromeVisible ? 1 : 0)
                    .id(ui.fontToastID)
                    .transition(.opacity)
                    .offset(y: -6)
            }
            .frame(height: 24)

            arrow("chevron.down", "Next font") { ui.cycleFont(settings, 1) }
        }
        .padding(.horizontal, 40)
        .padding(.top, 54)
        .padding(.bottom, 40)
    }

    private func arrow(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .frame(width: 44, height: 44)
                .background(GlassBackground(shape: Circle(), shadow: false))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .opacity(ui.chromeVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.4), value: ui.chromeVisible)
        .help("\(label) (\(symbol == "chevron.up" ? "↑" : "↓"))")
        .accessibilityLabel(label)
    }
}

// MARK: - Page 3: Now Playing

struct NowPlayingPage: View {
    @EnvironmentObject private var np: NowPlayingService

    var body: some View {
        GeometryReader { geo in
            let art = min(geo.size.height * 0.68, geo.size.width * 0.36)
            Group {
                if let t = np.track {
                    HStack(spacing: 48) {
                        ZStack {
                            if let image = np.artwork {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: art, height: art)
                                    .blur(radius: 60)
                                    .opacity(0.65)
                            }
                            ArtworkView(side: art)
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            NowPlayingTag(track: t)
                            Text(t.title)
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .tracking(-0.8)
                                .lineLimit(3)
                                .minimumScaleFactor(0.6)
                            Text(t.artist)
                                .font(.system(size: 22, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                            ProgressScrubber(track: t, compact: false)
                                .padding(.top, 18)
                            TransportControls(track: t, scale: 1.1, glass: true)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 6)
                            VolumeSlider(compact: false, glass: true)
                                .padding(.top, 10)
                        }
                        .frame(maxWidth: 460)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    NowPlayingEmpty(compact: false)
                        .frame(width: 340, height: 260)
                        .padding(28)
                        .background(GlassCard())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 48)
        .padding(.top, 60)
        .padding(.bottom, 44)
    }
}
