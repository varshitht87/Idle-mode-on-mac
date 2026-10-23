import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CustomizePanel: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var np: NowPlayingService
    @EnvironmentObject private var awake: DisplayAwake
    @Environment(\.accent) private var accent

    private let slotNames = ["Tile 1", "Tile 2", "Tile 3", "Tile 4", "Tile 5"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Theme") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                        ForEach(Palette.presets) { p in
                            swatch(id: p.id, name: p.name, colors: p.colors)
                        }
                        swatch(id: Palette.adaptiveID, name: "Artwork",
                               colors: np.artPalette ?? Palette.presets[0].colors, sparkle: true)
                    }
                    if settings.isAdaptive {
                        Text(np.artPalette == nil ? "Colours follow the artwork of whatever is playing. Nothing is playing yet."
                                                  : "Colours follow the artwork of what's playing now.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                section("Glass") {
                    let tint = settings.config.glassTint
                    HStack(spacing: 8) {
                        glassPreset("Clear", value: 0, selected: tint < 0.05)
                        glassPreset("Tinted", value: 1, selected: tint > 0.95)
                    }
                    HStack(spacing: 10) {
                        Text("Clear")
                        Slider(value: $settings.config.glassTint, in: 0...1)
                        Text("Tinted")
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                }

                section("Texture") {
                    HStack(spacing: 8) {
                        ForEach(TextureKind.allCases) { t in texture(t) }
                    }
                    slider("Strength", value: $settings.config.textureAmount, icon: "circle.dotted")
                        .disabled(settings.config.texture == .smooth)
                }

                section("Background") {
                    Picker("Background", selection: Binding(
                        get: { settings.showsPhoto },
                        set: { usePhoto in
                            if usePhoto && settings.photo == nil { choosePhoto() }
                            else { withAnimation(.easeInOut(duration: 0.6)) { settings.config.usePhoto = usePhoto } }
                        }
                    )) {
                        Text("Gradient").tag(false)
                        Text("Photo").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if let photo = settings.photo {
                        HStack(spacing: 12) {
                            Image(nsImage: photo)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 72, height: 46)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.2)))
                            VStack(alignment: .leading, spacing: 4) {
                                Button("Choose Another…") { choosePhoto() }
                                Button("Remove Photo", role: .destructive) {
                                    withAnimation(.easeInOut(duration: 0.6)) { settings.removePhoto() }
                                }
                                .foregroundStyle(.red.opacity(0.9))
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                    } else {
                        Button { choosePhoto() } label: {
                            Label("Import Photo…", systemImage: "photo.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.regular)
                    }
                    if settings.showsPhoto {
                        let blur = settings.config.photoBlur
                        let half = abs(blur - 0.5) < 0.01
                        HStack(spacing: 10) {
                            Button {
                                settings.setPhotoBlur(half ? 0 : 0.5)
                            } label: {
                                Label("Blur 50%", systemImage: half ? "drop.fill" : "drop")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(half ? Color.black : .white)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Capsule().fill(half ? accent : Color.white.opacity(0.12)))
                            }
                            .buttonStyle(PressableStyle(scale: 0.95))
                            .help(half ? "Remove the blur" : "Blur the wallpaper by 50%")
                            Slider(value: Binding(get: { settings.config.photoBlur },
                                                  set: { settings.setPhotoBlur($0) }), in: 0...1)
                            Text("\(Int((blur * 100).rounded()))%")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 34, alignment: .trailing)
                        }
                        Text("Accent colours come from the photo. Texture and grain still apply on top.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    slider("Motion", value: $settings.config.motion, icon: "wind")
                    Toggle(isOn: $settings.config.interactive) {
                        Label("Follow pointer & ripple on click", systemImage: "hand.point.up.left")
                    }
                }

                section("Clock") {
                    Toggle(isOn: $settings.config.use24h) { Label("24-hour time", systemImage: "clock") }
                    Toggle(isOn: $settings.config.showSeconds) { Label("Show seconds", systemImage: "stopwatch") }
                }

                section("Keep Screen On") {
                    Picker("Keep screen on", selection: $settings.config.keepAwake) {
                        ForEach(KeepAwakeMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    Label(awake.status, systemImage: awake.keepingAwake ? "sun.max.fill" : "moon.zzz.fill")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }

                section("Blocks") {
                    ForEach(0..<5, id: \.self) { i in
                        HStack {
                            Text(slotNames[i])
                                .foregroundStyle(.white.opacity(0.6))
                            Spacer()
                            Picker(slotNames[i], selection: Binding(
                                get: { settings.config.blocks[i].kind },
                                set: { k in withAnimation(.spring(response: 0.4, dampingFraction: 1)) { settings.setKind(k, at: i) } }
                            )) {
                                ForEach(WidgetKind.allCases) { k in
                                    Label(k.title, systemImage: k.symbol).tag(k)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    Button("Reset layout") {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { settings.resetLayout() }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(accent)
                }

                section("Now Playing") {
                    Text("Reads media tabs in Chrome, Arc, Brave, Edge and Safari: YouTube, YouTube Music, Spotify, SoundCloud and more.")
                    Text("For artwork, progress and play/pause, turn on View ▸ Developer ▸ Allow JavaScript from Apple Events in Chrome (Develop menu in Safari).")
                        .foregroundStyle(np.javascriptBlocked ? accent : .white.opacity(0.5))
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))

                Text("Shortcuts: ← → pages · Space play/pause · E edit · C customise · N now playing")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(20)
        }
        .scrollIndicators(.never)
        .toggleStyle(.switch)
        .controlSize(.small)
        .background(GlassCard(radius: 26, fixedTint: 1))
    }

    // MARK: Pieces

    private func glassPreset(_ title: String, value: Double, selected: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) { settings.config.glassTint = value }
        } label: {
            VStack(spacing: 5) {
                GlassStylePreview(tint: value)
                    .frame(height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(selected ? 0.95 : 0.15), lineWidth: selected ? 2 : 1))
                Text(title)
                    .font(.system(size: 11, weight: selected ? .bold : .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
            }
        }
        .buttonStyle(PressableStyle(scale: 0.95))
        .accessibilityLabel("\(title) glass")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Opens a standard image picker (it includes the Photos library in its sidebar).
    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a photo for the Idle Mode background"
        panel.prompt = "Use Photo"
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            settings.importPhoto(from: url)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handler) }
        else { panel.begin(completionHandler: handler) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(.white.opacity(0.45))
            content()
        }
    }

    private func swatch(id: String, name: String, colors: [RGB], sparkle: Bool = false) -> some View {
        let selected = settings.config.paletteID == id
        return Button {
            // Picking a theme always shows it: from a photo background this switches to the gradient.
            // The photo stays saved, so the Photo switch brings it straight back.
            withAnimation(.easeInOut(duration: 0.6)) {
                settings.config.paletteID = id
                settings.config.usePhoto = false
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(AngularGradient(colors: colors.map(\.color) + [colors[0].color], center: .center))
                    if sparkle {
                        Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 40, height: 40)
                .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.95 : 0.15), lineWidth: selected ? 2.5 : 1).padding(-4))
                Text(name)
                    .font(.system(size: 11, weight: selected ? .bold : .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
            }
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .accessibilityLabel("\(name) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func texture(_ t: TextureKind) -> some View {
        let selected = settings.config.texture == t
        let colors = settings.colors(adaptive: np.artPalette)
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 1)) { settings.config.texture = t }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    LinearGradient(colors: [colors[1].color, colors[2].color, colors[3].color],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let img = TextureFactory.image(t) {
                        Image(decorative: img, scale: 2)
                            .resizable(resizingMode: .tile)
                            .blendMode(.overlay)
                            .opacity(t == .smooth ? 0.12 : 0.9)
                    }
                }
                .compositingGroup()
                .frame(width: 56, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.95 : 0.15), lineWidth: selected ? 2 : 1))
                Text(t.title)
                    .font(.system(size: 10, weight: selected ? .bold : .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .accessibilityLabel("\(t.title) texture")
    }

    private func slider(_ title: String, value: Binding<Double>, icon: String) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: icon)
                .frame(width: 96, alignment: .leading)
            Slider(value: value, in: 0...1)
        }
    }
}

/// A small swatch showing what Clear or Tinted glass looks like over the current theme colours.
private struct GlassStylePreview: View {
    let tint: Double
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var np: NowPlayingService
    @Environment(\.accent) private var accent

    var body: some View {
        let colors = settings.colors(adaptive: np.artPalette)
        let style = GlassStyle(tint: tint, accent: accent)
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        ZStack {
            LinearGradient(colors: [colors[1].color, colors[2].color, colors[3].color],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Group {
                if #available(macOS 26.0, *) {
                    shape.fill(Color.black.opacity(style.dim)).glassEffect(style.glass, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial).overlay(shape.fill(Color.black.opacity(style.dim)))
                }
            }
            .padding(7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
