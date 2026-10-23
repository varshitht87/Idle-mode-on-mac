import SwiftUI
import AppKit
import ApplicationServices

// MARK: - Track

enum MediaSource: String, Sendable, Codable { case browser, music, spotify }

enum RepeatMode: String, Sendable { case off, all, one
    /// The mode a click moves to. Spotify's AppleScript only knows on/off; a plain YouTube video can only loop itself.
    func next(for track: MediaTrack) -> RepeatMode {
        if track.source == .spotify { return self == .off ? .all : .off }
        if track.source == .browser && track.site == "YouTube" { return self == .off ? .one : .off }
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

struct MediaTrack: Equatable, Sendable {
    var source: MediaSource
    var title: String
    var artist: String
    var site: String          // "YouTube", "Apple Music", "Spotify"…
    var browser: String       // "Chrome", "Safari"… (app name for desktop players)
    var bundleID: String
    var key: String           // tab URL, or a track id for desktop players
    var artworkURL: URL?
    var isPlaying: Bool?      // nil when a browser won't run JavaScript for us
    var position: Double?
    var duration: Double?
    var fetchedAt: Date
    var scriptable: Bool
    var shuffle: Bool? = nil
    var repeatMode: RepeatMode? = nil

    /// Desktop players always; in a browser only the players that have a shuffle button.
    var canShuffle: Bool {
        source != .browser || (scriptable && ["Spotify", "YouTube Music", "SoundCloud"].contains(site))
    }
    var canRepeat: Bool { source != .browser || scriptable }

    /// Interpolates playback position between polls so the progress bar moves smoothly.
    func livePosition(at date: Date) -> Double? {
        guard let position else { return nil }
        guard isPlaying == true else { return position }
        return min(position + date.timeIntervalSince(fetchedAt), duration ?? .greatestFiniteMagnitude)
    }

    var sourceLabel: String { source == .browser ? "\(site) in \(browser)" : site }
}

/// What played last, remembered across launches so "Resume" works after the source has gone away.
struct LastMedia: Codable, Equatable, Sendable {
    var source: MediaSource
    var title: String
    var artist: String
    var site: String
    var browser: String
    var bundleID: String
    var key: String
    var position: Double?

    init(_ t: MediaTrack) {
        source = t.source; title = t.title; artist = t.artist; site = t.site
        browser = t.browser; bundleID = t.bundleID; key = t.key
        position = t.livePosition(at: Date())
    }

    var appName: String { source == .browser ? browser : site }
}

// MARK: - Service

@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var track: MediaTrack?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artPalette: [RGB]?
    @Published private(set) var javascriptBlocked = false
    @Published private(set) var volume: Double = 0.5
    @Published private(set) var muted = false
    @Published private(set) var lastMedia: LastMedia?
    @Published private(set) var resuming = false
    /// Why the last Resume didn't work, in plain words (nil when it worked).
    @Published private(set) var resumeProblem: String?
    @Published private(set) var resumeNeedsPermission = false

    private var timer: Timer?
    private var polling = false
    private var misses = 0
    private var artworkKey: URL?
    private var optimistic: (playing: Bool, until: Date)?
    private var holdVolumeUntil = Date.distantPast
    private var pendingVolume: Double?
    private var sendingVolume = false
    private var optimisticShuffle: (value: Bool, until: Date)?
    private var optimisticRepeat: (value: RepeatMode, until: Date)?
    private var lastSaved = Date.distantPast
    private static let lastMediaKey = "standby.lastMedia.v1"

    init() {
        LegacySettings.migrateIfNeeded()
        if let data = UserDefaults.standard.data(forKey: Self.lastMediaKey) {
            lastMedia = try? JSONDecoder().decode(LastMedia.self, from: data)
        }
    }

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func poll() {
        guard !polling else { return }
        polling = true
        let running = MediaBridge.runningSources()
        let prefer = track?.key
        Task.detached(priority: .utility) {
            let result = MediaBridge.findMedia(browsers: running.browsers, apps: running.apps, prefer: prefer)
            let vol = MediaBridge.readVolume()
            await MainActor.run {
                self.apply(result)
                if let vol, Date() > self.holdVolumeUntil {
                    if abs(self.volume - vol.level) > 0.004 { self.volume = vol.level }
                    if self.muted != vol.muted { self.muted = vol.muted }
                }
                self.polling = false
            }
        }
    }

    private func apply(_ result: MediaBridge.Result) {
        if javascriptBlocked != result.javascriptBlocked { javascriptBlocked = result.javascriptBlocked }
        guard var t = result.track else {
            // Ride out a single failed poll (e.g. a slow browser) instead of flickering to empty.
            misses += 1
            if misses >= 2, track != nil {
                withAnimation(.spring(response: 0.5, dampingFraction: 1)) { track = nil }
                loadArtwork(nil)
            }
            return
        }
        misses = 0
        let sameSource = t.key == track?.key
        if let o = optimistic, Date() < o.until, sameSource { t.isPlaying = o.playing } else { optimistic = nil }
        if let o = optimisticShuffle, Date() < o.until, sameSource { t.shuffle = o.value } else { optimisticShuffle = nil }
        if let o = optimisticRepeat, Date() < o.until, sameSource { t.repeatMode = o.value } else { optimisticRepeat = nil }
        // Some web players don't expose their shuffle/repeat state: keep what we last set.
        if sameSource {
            if t.shuffle == nil { t.shuffle = track?.shuffle }
            if t.repeatMode == nil { t.repeatMode = track?.repeatMode }
        }
        remember(t)

        if track?.key != t.key || track?.title != t.title {
            withAnimation(.spring(response: 0.5, dampingFraction: 1)) { track = t }
        } else {
            track = t
        }
        loadArtwork(t.artworkURL)
    }

    // MARK: Controls

    func togglePlay() {
        guard track != nil else { resumeLast(); return }
        if let t = track, let playing = t.isPlaying {
            optimistic = (!playing, Date().addingTimeInterval(2.5))
            track?.isPlaying = !playing
            track?.position = t.livePosition(at: Date())
            track?.fetchedAt = Date()
        }
        perform(.toggle, mediaKey: MediaKeys.play)
    }

    func toggleShuffle() {
        guard let t = track, t.canShuffle else { return }
        let target = !(t.shuffle ?? false)
        optimisticShuffle = (target, Date().addingTimeInterval(2.5))
        track?.shuffle = target
        perform(.setShuffle(target), mediaKey: nil)
    }

    func cycleRepeat() {
        guard let t = track, t.canRepeat else { return }
        let target = (t.repeatMode ?? .off).next(for: t)
        optimisticRepeat = (target, Date().addingTimeInterval(2.5))
        track?.repeatMode = target
        perform(.setRepeat(target), mediaKey: nil)
    }

    func next() { perform(.next, mediaKey: MediaKeys.next) }
    func previous() { perform(.previous, mediaKey: MediaKeys.previous) }

    func seek(to seconds: Double) {
        track?.position = seconds
        track?.fetchedAt = Date()
        perform(.seek(seconds), mediaKey: nil)
    }

    private func perform(_ action: MediaBridge.Action, mediaKey: Int32?) {
        let t = track
        Task.detached(priority: .userInitiated) {
            var handled = false
            if let t, t.scriptable { handled = MediaBridge.run(action, on: t) }
            if !handled, let mediaKey {
                await MainActor.run { MediaKeys.post(mediaKey) }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            await MainActor.run { self.poll() }
        }
    }

    // MARK: Resume

    /// Saves what's playing now (on a change of track, otherwise at most every 10 s for the position).
    private func remember(_ t: MediaTrack) {
        let m = LastMedia(t)
        let changed = lastMedia?.key != m.key || lastMedia?.title != m.title
        guard changed || Date().timeIntervalSince(lastSaved) > 10 else { return }
        lastMedia = m
        lastSaved = Date()
        if let data = try? JSONEncoder().encode(m) { UserDefaults.standard.set(data, forKey: Self.lastMediaKey) }
    }

    /// Starts the last thing that played again: Music and Spotify resume; a closed browser tab is
    /// reopened (YouTube at the point it stopped) in the background, then told to play.
    func resumeLast() {
        guard !resuming else { return }
        resuming = true
        resumeProblem = nil
        resumeNeedsPermission = false
        let last = lastMedia
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        Task.detached(priority: .userInitiated) {
            let outcome = MediaBridge.resume(last, running: running)
            switch outcome {
            case .done:
                break
            case .failed(let error):
                await MainActor.run {
                    self.explain(error, app: last?.appName ?? "Music")
                    if AXIsProcessTrusted() { MediaKeys.post(MediaKeys.play) }
                }
            case .reopen(let url, let bundleID):
                await MainActor.run { Self.openInBackground(url, bundleID: bundleID) }
                if let last { _ = MediaBridge.playWhenLoaded(last) }
            }
            for delay in [0.6, 1.5, 3.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await MainActor.run { self.poll() }
            }
            await MainActor.run { self.resuming = false }
        }
    }

    private func explain(_ error: String, app: String) {
        if error.contains("-1743") || error.localizedCaseInsensitiveContains("not authori") {
            resumeNeedsPermission = true
            resumeProblem = "Allow Idle Mode to control \(app) in Privacy & Security › Automation."
        } else if error == "nothing-queued" {
            resumeProblem = "\(app) has nothing queued. Play a song once and Resume will remember it."
        } else if error.contains("-600") || error.localizedCaseInsensitiveContains("isn’t running") || error.localizedCaseInsensitiveContains("isn't running") {
            resumeProblem = "\(app) didn't start in time. Try again."
        } else if !error.isEmpty {
            resumeProblem = "Couldn't resume: " + error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
        } else {
            resumeProblem = "Couldn't resume \(app)."
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the page without bringing the browser in front of Idle Mode.
    private static func openInBackground(_ url: URL, bundleID: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, _ in }
    }

    // MARK: Volume (system output)

    /// Updates the slider at once and sends the newest value to the system, dropping stale ones mid-drag.
    func setVolume(_ v: Double) {
        let clamped = min(1, max(0, v))
        volume = clamped
        muted = false
        holdVolumeUntil = Date().addingTimeInterval(1.5)
        pendingVolume = clamped
        if !sendingVolume { sendNextVolume() }
    }

    func toggleMute() {
        muted.toggle()
        holdVolumeUntil = Date().addingTimeInterval(1.5)
        let m = muted
        Task.detached { _ = MediaBridge.osascript("set volume output muted \(m)") }
    }

    private func sendNextVolume() {
        guard let v = pendingVolume else { sendingVolume = false; return }
        pendingVolume = nil
        sendingVolume = true
        Task.detached(priority: .userInitiated) {
            _ = MediaBridge.osascript("set volume output volume \(Int((v * 100).rounded())) without output muted")
            await MainActor.run { self.sendNextVolume() }
        }
    }

    // MARK: Artwork

    private func loadArtwork(_ url: URL?) {
        guard url != artworkKey else { return }
        artworkKey = url
        guard let url else {
            withAnimation(.easeInOut(duration: 0.5)) { artwork = nil }
            artPalette = nil
            return
        }
        Task {
            let data: Data?
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else {
                data = try? await URLSession.shared.data(from: url).0
            }
            guard self.artworkKey == url, let data, let image = NSImage(data: data) else { return }
            withAnimation(.easeInOut(duration: 0.6)) { self.artwork = image }
            self.artPalette = ArtPalette.extract(image)
        }
    }
}

// MARK: - Bridge (AppleScript via osascript)

enum MediaBridge {
    struct Browser: Sendable {
        let bundleID: String
        let name: String
        let isSafari: Bool
    }

    struct Result: Sendable {
        var track: MediaTrack?
        var javascriptBlocked: Bool
    }

    enum Action: Sendable { case toggle, next, previous, seek(Double), setShuffle(Bool), setRepeat(RepeatMode) }

    enum ResumeOutcome: Sendable { case done, failed(String), reopen(URL, String) }

    static let musicID = "com.apple.Music"
    static let spotifyID = "com.spotify.client"

    static let knownBrowsers: [Browser] = [
        Browser(bundleID: "com.google.Chrome", name: "Chrome", isSafari: false),
        Browser(bundleID: "company.thebrowser.Browser", name: "Arc", isSafari: false),
        Browser(bundleID: "com.brave.Browser", name: "Brave", isSafari: false),
        Browser(bundleID: "com.microsoft.edgemac", name: "Edge", isSafari: false),
        Browser(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", isSafari: false),
        Browser(bundleID: "org.chromium.Chromium", name: "Chromium", isSafari: false),
        Browser(bundleID: "com.apple.Safari", name: "Safari", isSafari: true),
    ]

    /// Only talk to apps that are already running — `tell application` would otherwise launch them.
    static func runningSources() -> (browsers: [Browser], apps: [String]) {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return (knownBrowsers.filter { ids.contains($0.bundleID) }, [musicID, spotifyID].filter { ids.contains($0) })
    }

    static func site(for urlString: String) -> String? {
        guard let u = URL(string: urlString), let host = u.host?.lowercased() else { return nil }
        let path = u.path
        if host.hasSuffix("music.youtube.com") { return "YouTube Music" }
        if host.hasSuffix("youtube.com") && (path.hasPrefix("/watch") || path.hasPrefix("/shorts") || path.hasPrefix("/live")) { return "YouTube" }
        if host == "youtu.be" { return "YouTube" }
        if host.hasSuffix("open.spotify.com") { return "Spotify" }
        if host.hasSuffix("soundcloud.com") { return "SoundCloud" }
        if host.hasSuffix("music.apple.com") { return "Apple Music" }
        if host.hasSuffix("jiosaavn.com") { return "JioSaavn" }
        if host.hasSuffix("gaana.com") { return "Gaana" }
        if host.hasSuffix("twitch.tv") && path.count > 1 { return "Twitch" }
        if host.hasSuffix("vimeo.com") && path.count > 1 { return "Vimeo" }
        if host.hasSuffix("netflix.com") && path.hasPrefix("/watch") { return "Netflix" }
        return nil
    }

    // MARK: Discovery

    /// Gathers every source, then picks: something playing (sticking with the current one if it still is),
    /// else the current source if it's still around, else the most recent paused one.
    static func findMedia(browsers: [Browser], apps: [String], prefer: String?) -> Result {
        var all: [MediaTrack] = []
        for app in apps {
            if let t = app == musicID ? musicTrack() : spotifyTrack() { all.append(t) }
        }
        let web = browserTracks(browsers)
        all += web.tracks

        let playing = all.filter { $0.isPlaying == true }
        let chosen = playing.first { $0.key == prefer }
            ?? playing.first
            ?? all.first { $0.key == prefer }
            ?? all.first { $0.isPlaying == nil }
            ?? all.first
        return Result(track: chosen, javascriptBlocked: web.blocked)
    }

    private static func browserTracks(_ browsers: [Browser]) -> (tracks: [MediaTrack], blocked: Bool) {
        struct Candidate { let browser: Browser; let url: String; let title: String; let site: String }
        var candidates: [Candidate] = []

        for b in browsers {
            let r = osascript(listScript(b))
            guard r.ok else { continue }
            for line in r.out.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 2 else { continue }
                let url = f[0], title = f[1...].joined(separator: "\t")
                if let site = site(for: url) {
                    candidates.append(Candidate(browser: b, url: url, title: title, site: site))
                }
            }
        }

        var blocked = Set<String>()
        var tracks: [MediaTrack] = []
        for c in candidates.prefix(6) {
            let cleaned = cleanTitle(c.title, site: c.site)
            var t = MediaTrack(source: .browser, title: cleaned.title, artist: cleaned.artist, site: c.site,
                               browser: c.browser.name, bundleID: c.browser.bundleID, key: c.url,
                               artworkURL: youtubeThumbnail(c.url), isPlaying: nil, position: nil, duration: nil,
                               fetchedAt: Date(), scriptable: false)

            if !blocked.contains(c.browser.bundleID) {
                let r = osascript(jsScript(c.browser, url: c.url, js: infoJS))
                if r.ok, let info = decodeInfo(r.out) {
                    t.scriptable = true
                    if let title = info.t, !title.isEmpty { t.title = title }
                    if let artist = info.ar, !artist.isEmpty { t.artist = artist }
                    if let art = info.art, let u = URL(string: art), u.scheme?.hasPrefix("http") == true { t.artworkURL = u }
                    switch info.ps {
                    case "playing": t.isPlaying = true
                    case "paused": t.isPlaying = false
                    default: t.isPlaying = info.p.map { !$0 }
                    }
                    t.position = info.c
                    t.duration = (info.d ?? 0) > 0 ? info.d : nil
                    t.shuffle = info.sh
                    t.repeatMode = info.rp.flatMap(RepeatMode.init(rawValue:))
                } else if !r.ok, r.err.localizedCaseInsensitiveContains("javascript") {
                    blocked.insert(c.browser.bundleID)
                }
            }
            tracks.append(t)
        }
        return (tracks, !blocked.isEmpty)
    }

    // MARK: Desktop players

    private static func number(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private static func musicTrack() -> MediaTrack? {
        let r = osascript("""
        set TB to character id 9
        tell application id "\(musicID)"
            set pstate to player state as text
            if pstate is "stopped" then return "stopped"
            set trk to current track
            set sh to ""
            set rp to ""
            try
                set sh to shuffle enabled as text
                set rp to song repeat as text
            end try
            return pstate & TB & (name of trk) & TB & (artist of trk) & TB & (album of trk) & TB & (player position as text) & TB & (duration of trk as text) & TB & (persistent ID of trk) & TB & sh & TB & rp
        end tell
        """)
        guard r.ok else { return nil }
        let f = r.out.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        guard f.count >= 7 else { return nil }
        let id = f[6]
        var t = MediaTrack(source: .music, title: f[1], artist: f[2].isEmpty ? f[3] : f[2], site: "Apple Music",
                           browser: "Music", bundleID: musicID, key: "music:" + id,
                           artworkURL: musicArtwork(id: id), isPlaying: f[0] == "playing",
                           position: number(f[4]), duration: number(f[5]), fetchedAt: Date(), scriptable: true)
        if f.count >= 9 {
            t.shuffle = f[7] == "true" ? true : (f[7] == "false" ? false : nil)
            t.repeatMode = RepeatMode(rawValue: f[8])
        }
        return t
    }

    /// Music only hands out artwork as raw data, so it's written once per track to a temp file.
    private static func musicArtwork(id: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("IdleModeArtwork", isDirectory: true)
        let file = dir.appendingPathComponent(id.filter { $0.isLetter || $0.isNumber } + ".img")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = osascript("""
        tell application id "\(musicID)"
            set d to raw data of artwork 1 of current track
        end tell
        set f to open for access (POSIX file \(q(file.path))) with write permission
        try
            set eof f to 0
            write d to f
        end try
        close access f
        return "ok"
        """)
        return r.ok && FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private static func spotifyTrack() -> MediaTrack? {
        let r = osascript("""
        set TB to character id 9
        tell application id "\(spotifyID)"
            set pstate to player state as text
            if pstate is "stopped" then return "stopped"
            set trk to current track
            set sh to ""
            set rp to ""
            try
                set sh to shuffling as text
                set rp to repeating as text
            end try
            return pstate & TB & (name of trk) & TB & (artist of trk) & TB & (album of trk) & TB & (player position as text) & TB & (duration of trk as text) & TB & (id of trk) & TB & (artwork url of trk) & TB & sh & TB & rp
        end tell
        """)
        guard r.ok else { return nil }
        let f = r.out.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        guard f.count >= 8 else { return nil }
        var t = MediaTrack(source: .spotify, title: f[1], artist: f[2], site: "Spotify",
                           browser: "Spotify", bundleID: spotifyID, key: "spotify:" + f[6],
                           artworkURL: URL(string: f[7]), isPlaying: f[0] == "playing",
                           position: number(f[4]), duration: number(f[5]).map { $0 / 1000 },
                           fetchedAt: Date(), scriptable: true)
        if f.count >= 10 {
            t.shuffle = f[8] == "true" ? true : (f[8] == "false" ? false : nil)
            t.repeatMode = f[9] == "true" ? .all : (f[9] == "false" ? .off : nil)
        }
        return t
    }

    // MARK: Control

    static func run(_ action: Action, on track: MediaTrack) -> Bool {
        if track.source != .browser {
            let verb: String
            switch action {
            case .toggle: verb = "playpause"
            case .next: verb = "next track"
            case .previous: verb = track.source == .music ? "back track" : "previous track"
            case .seek(let s): verb = "set player position to \(max(0, s))"
            case .setShuffle(let on):
                verb = track.source == .music ? "set shuffle enabled to \(on)" : "set shuffling to \(on)"
            case .setRepeat(let mode):
                verb = track.source == .music ? "set song repeat to \(mode.rawValue)" : "set repeating to \(mode != .off)"
            }
            return osascript("tell application id \"\(track.bundleID)\" to \(verb)").ok
        }

        guard let browser = knownBrowsers.first(where: { $0.bundleID == track.bundleID }) else { return false }
        let js: String
        switch action {
        case .toggle: js = toggleJS
        case .next: js = nextJS
        case .previous: js = previousJS
        case .seek(let s): js = "(function(){var v=document.querySelector('video')||document.querySelector('audio');if(v){v.currentTime=\(max(0, s));return 'ok'}return 'none'})()"
        case .setShuffle: js = shuffleJS
        case .setRepeat(let mode): js = repeatJS(mode)
        }
        let r = osascript(jsScript(browser, url: track.key, js: js))
        return r.ok && r.out.contains("ok")
    }

    /// Runs off the main thread. With nothing remembered it resumes Spotify if it's open, else Music.
    static func resume(_ last: LastMedia?, running: Set<String>) -> ResumeOutcome {
        guard let last else {
            if running.contains(spotifyID) {
                let r = osascript("tell application id \"\(spotifyID)\" to play", timeout: 12)
                return r.ok ? .done : .failed(r.err)
            }
            return resumeMusic(persistentID: nil)
        }
        switch last.source {
        case .music:
            let id = last.key.hasPrefix("music:") ? String(last.key.dropFirst("music:".count)) : nil
            return resumeMusic(persistentID: id)
        case .spotify:
            if running.contains(spotifyID), osascript("tell application id \"\(spotifyID)\" to play").ok { return .done }
            // Spotify was closed: launch it and start the remembered track once it accepts commands.
            let trackID = last.key.hasPrefix("spotify:") ? String(last.key.dropFirst("spotify:".count)) : ""
            var lastError = ""
            for _ in 0..<8 {
                let verb = trackID.isEmpty ? "play" : "play track \(q(trackID))"
                let r = osascript("tell application id \"\(spotifyID)\" to \(verb)", timeout: 8)
                if r.ok { return .done }
                lastError = r.err
                if lastError.contains("-1743") { break }
                Thread.sleep(forTimeInterval: 1)
            }
            return .failed(lastError)
        case .browser:
            guard let browser = knownBrowsers.first(where: { $0.bundleID == last.bundleID }) else { return .failed("") }
            if running.contains(browser.bundleID) {
                let r = osascript(jsScript(browser, url: last.key, js: playJS))
                if r.ok, r.out.contains("ok") { return .done }
                // Tab still open but JavaScript is off (or not permitted): the media key is the only way in.
                if !r.ok { return .failed(r.err) }
            }
            // The tab (or the browser) is gone: reopen the page.
            guard let url = resumeURL(last) else { return .failed("") }
            return .reopen(url, browser.bundleID)
        }
    }

    /// `play` alone does nothing when Music has just launched with an empty queue, so if it isn't playing
    /// a moment later, start the remembered song from the library by its persistent ID.
    private static func resumeMusic(persistentID: String?) -> ResumeOutcome {
        let id = (persistentID ?? "").filter { $0.isLetter || $0.isNumber }
        let r = osascript("""
        tell application id "\(musicID)"
            play
            delay 0.8
            if player state is not playing and \(q(id)) is not "" then
                try
                    play (first track of library playlist 1 whose persistent ID is \(q(id)))
                end try
                delay 0.5
            end if
            return player state as text
        end tell
        """, timeout: 15)
        guard r.ok else { return .failed(r.err) }
        return r.out.contains("playing") ? .done : .failed("nothing-queued")
    }

    /// After reopening a page, presses play once its player exists (YouTube usually autoplays anyway).
    static func playWhenLoaded(_ last: LastMedia) -> Bool {
        guard let browser = knownBrowsers.first(where: { $0.bundleID == last.bundleID }) else { return false }
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 1.5)
            let r = osascript(jsScript(browser, url: last.key, js: playJS, matchPrefix: true))
            if r.ok, r.out.contains("ok") { return true }
        }
        return false
    }

    /// YouTube links reopen where they stopped.
    private static func resumeURL(_ last: LastMedia) -> URL? {
        guard var c = URLComponents(string: last.key) else { return nil }
        if last.site.hasPrefix("YouTube"), let pos = last.position, pos > 5 {
            var items = (c.queryItems ?? []).filter { $0.name != "t" }
            items.append(URLQueryItem(name: "t", value: "\(Int(pos))s"))
            c.queryItems = items
        }
        return c.url
    }

    static func readVolume() -> (level: Double, muted: Bool)? {
        let r = osascript("set v to get volume settings\nreturn ((output volume of v) as text) & \",\" & ((output muted of v) as text)")
        let parts = r.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        guard r.ok, parts.count == 2, let level = Double(parts[0]) else { return nil }
        return (level / 100, parts[1] == "true")
    }

    // MARK: Scripts

    private static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func listScript(_ b: Browser) -> String {
        let title = b.isSafari ? "name" : "title"
        return """
        set TB to character id 9
        set LF to character id 10
        set out to ""
        tell application id "\(b.bundleID)"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        try
                            set out to out & (URL of t as text) & TB & (\(title) of t as text) & LF
                        end try
                    end repeat
                end try
            end repeat
        end tell
        return out
        """
    }

    private static func jsScript(_ b: Browser, url: String, js: String, matchPrefix: Bool = false) -> String {
        let run = b.isSafari ? "do JavaScript \(q(js)) in t" : "execute t javascript \(q(js))"
        let test = matchPrefix ? "starts with" : "is"
        return """
        tell application id "\(b.bundleID)"
            repeat with w in windows
                repeat with t in tabs of w
                    if (URL of t as text) \(test) \(q(url)) then
                        return (\(run))
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """
    }

    // All JavaScript uses single quotes only so it can be embedded in an AppleScript string.
    private static let infoJS = "(function(){var m=navigator.mediaSession&&navigator.mediaSession.metadata;var v=document.querySelector('video')||document.querySelector('audio');var a='';if(m&&m.artwork&&m.artwork.length){a=m.artwork[m.artwork.length-1].src}" + shuffleRepeatStateJS + "return JSON.stringify({t:m?m.title:'',ar:m?m.artist:'',art:a,p:v?v.paused:null,c:v?v.currentTime:null,d:v&&isFinite(v.duration)?v.duration:null,ps:navigator.mediaSession?navigator.mediaSession.playbackState:'',sh:sh,rp:rp})})()"

    /// Reads shuffle/repeat from Spotify Web, SoundCloud and YouTube Music; a plain video reports its loop flag.
    private static let shuffleRepeatStateJS = "var sh=null,rp=null;var sb=document.querySelector('[data-testid=control-button-shuffle]');if(sb){sh=sb.getAttribute('aria-checked')=='true'}var sc=document.querySelector('.shuffleControl');if(sh===null&&sc){sh=sc.classList.contains('m-shuffling')}var rb=document.querySelector('[data-testid=control-button-repeat]');if(rb){var ck=rb.getAttribute('aria-checked');rp=ck=='true'?'all':(ck=='mixed'?'one':'off')}var rc=document.querySelector('.repeatControl');if(rp===null&&rc){rp=rc.classList.contains('m-one')?'one':(rc.classList.contains('m-all')?'all':'off')}var bar=document.querySelector('ytmusic-player-bar');if(rp===null&&bar&&bar.getAttribute('repeat-mode_')){var rm=bar.getAttribute('repeat-mode_');rp=rm=='ONE'?'one':(rm=='ALL'?'all':'off')}if(rp===null&&v){rp=v.loop?'one':'off'}"

    private static let shuffleJS = "(function(){var s=['[data-testid=control-button-shuffle]','ytmusic-player-bar .shuffle','.shuffleControl'];for(var i=0;i<s.length;i++){var b=document.querySelector(s[i]);if(b){b.click();return 'ok'}}return 'none'})()"

    private static func repeatJS(_ target: RepeatMode) -> String {
        "(function(){var s=['[data-testid=control-button-repeat]','ytmusic-player-bar .repeat','.repeatControl'];for(var i=0;i<s.length;i++){var b=document.querySelector(s[i]);if(b){b.click();return 'ok'}}var v=document.querySelector('video')||document.querySelector('audio');if(v){v.loop=\(target == .one ? "true" : "false");return 'ok'}return 'none'})()"
    }

    private static let playJS = "(function(){var b=document.querySelector('[data-testid=control-button-playpause]');if(b&&location.host.indexOf('spotify')>=0){var l=(b.getAttribute('aria-label')||'').toLowerCase();if(l.indexOf('play')>=0){b.click()}return 'ok'}var v=document.querySelector('video')||document.querySelector('audio');if(v){if(v.paused){v.play()}return 'ok'}return 'none'})()"

    private static let toggleJS = "(function(){var b=document.querySelector('[data-testid=control-button-playpause]');if(b&&location.host.indexOf('spotify')>=0){b.click();return 'ok'}var v=document.querySelector('video')||document.querySelector('audio');if(v){if(v.paused){v.play()}else{v.pause()}return 'ok'}return 'none'})()"

    private static let nextJS = "(function(){var s=['.ytp-next-button','ytmusic-player-bar .next-button','[data-testid=control-button-skip-forward]','.skipControl__next'];for(var i=0;i<s.length;i++){var b=document.querySelector(s[i]);if(b){b.click();return 'ok'}}return 'none'})()"

    private static let previousJS = "(function(){var s=['ytmusic-player-bar .previous-button','[data-testid=control-button-skip-back]','.skipControl__previous'];for(var i=0;i<s.length;i++){var b=document.querySelector(s[i]);if(b){b.click();return 'ok'}}var v=document.querySelector('video')||document.querySelector('audio');if(v){v.currentTime=0;return 'ok'}return 'none'})()"

    // MARK: Helpers

    private struct JSInfo: Decodable {
        var t: String?; var ar: String?; var art: String?
        var p: Bool?; var c: Double?; var d: Double?; var ps: String?
        var sh: Bool?; var rp: String?
    }

    private static func decodeInfo(_ s: String) -> JSInfo? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSInfo.self, from: data)
    }

    static func cleanTitle(_ raw: String, site: String) -> (title: String, artist: String) {
        var t = raw.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        for suffix in [" - YouTube Music", " - YouTube", " | Spotify", " | Free Listening on SoundCloud", " on SoundCloud", " on Apple Music", " - Twitch", " | Netflix"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        if t.contains(" • ") {
            let parts = t.components(separatedBy: " • ")
            return (parts[0], parts.dropFirst().joined(separator: " • "))
        }
        if site.hasPrefix("YouTube"), let r = t.range(of: " - ") {
            let artist = String(t[..<r.lowerBound]), title = String(t[r.upperBound...])
            if !artist.isEmpty, !title.isEmpty { return (title, artist) }
        }
        return (t.isEmpty ? site : t, site)
    }

    static func youtubeThumbnail(_ url: String) -> URL? {
        guard let c = URLComponents(string: url), let host = c.host, host.contains("youtu") else { return nil }
        var id = c.queryItems?.first(where: { $0.name == "v" })?.value
        let parts = c.path.split(separator: "/").map(String.init)
        if id == nil, parts.count >= 2, ["shorts", "live"].contains(parts[0]) { id = parts[1] }
        if id == nil, host == "youtu.be", let first = parts.first { id = first }
        guard let id, !id.isEmpty else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }

    /// True in the App Store / TestFlight build, which runs in the App Sandbox.
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    static func osascript(_ source: String, timeout: TimeInterval = 4) -> (ok: Bool, out: String, err: String) {
        // A sandboxed app can't send Apple events through the osascript tool, so it runs them itself.
        if isSandboxed { return InProcessAppleScript.run(source, timeout: timeout) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"]
        let input = Pipe(), output = Pipe(), error = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = error
        do { try p.run() } catch { return (false, "", "\(error)") }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus == 0, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}

// MARK: - AppleScript inside the app (sandboxed builds)

/// Runs AppleScript with NSAppleScript, one script at a time on its own queue. Apple events time out
/// after `timeout` seconds, so a stuck browser can't hold the queue.
enum InProcessAppleScript {
    private static let queue = DispatchQueue(label: "idlemode.applescript", qos: .userInitiated)

    static func run(_ source: String, timeout: TimeInterval) -> (ok: Bool, out: String, err: String) {
        let wrapped = "with timeout of \(max(1, Int(timeout.rounded(.up)))) seconds\n\(source)\nend timeout"
        return queue.sync {
            guard let script = NSAppleScript(source: wrapped) else { return (false, "", "Couldn't compile the script") }
            var info: NSDictionary?
            let result = script.executeAndReturnError(&info)
            if let info {
                let message = info[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
                let number = info[NSAppleScript.errorNumber] as? Int ?? 0
                return (false, "", "\(message) (\(number))")
            }
            return (true, result.stringValue ?? "", "")
        }
    }
}

// MARK: - Media keys (fallback when the browser won't run JavaScript)

enum MediaKeys {
    static let play: Int32 = 16, next: Int32 = 17, previous: Int32 = 18

    @MainActor static func post(_ key: Int32) {
        // Sandboxed apps can't post system media keys.
        guard !MediaBridge.isSandboxed else { return }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Artwork palette

enum ArtPalette {
    /// Pulls five background-friendly tones out of the artwork: [deep, mid, vivid, light, shadow].
    static func extract(_ image: NSImage) -> [RGB]? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let n = 16
        var data = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            // Skip the letterbox bars YouTube thumbnails carry at top and bottom.
            ctx.draw(cg, in: CGRect(x: 0, y: -Double(n) * 0.16, width: Double(n), height: Double(n) * 1.32))
            return true
        }
        guard ok else { return nil }

        var pixels: [RGB] = []
        for i in stride(from: 0, to: data.count, by: 4) {
            pixels.append(RGB(r: Double(data[i]) / 255, g: Double(data[i + 1]) / 255, b: Double(data[i + 2]) / 255))
        }
        let avg = pixels.reduce(RGB(r: 0, g: 0, b: 0)) { RGB(r: $0.r + $1.r, g: $0.g + $1.g, b: $0.b + $1.b) }
        let mean = RGB(r: avg.r / Double(pixels.count), g: avg.g / Double(pixels.count), b: avg.b / Double(pixels.count))

        let ranked = pixels.sorted {
            let a = $0.hsv, b = $1.hsv
            return a.s * 0.7 + a.v * 0.3 > b.s * 0.7 + b.v * 0.3
        }
        var picks: [RGB] = []
        for p in ranked where picks.allSatisfy({ $0.distance(p) > 0.25 }) {
            picks.append(p)
            if picks.count == 3 { break }
        }
        let vivid = picks.first ?? mean
        let second = picks.count > 1 ? picks[1] : RGB(h: vivid.hsv.h + 0.08, s: vivid.hsv.s, v: vivid.hsv.v)
        let third = picks.count > 2 ? picks[2] : mean

        return [
            mean.toned(v: 0.14, sat: 1.1),
            second.toned(v: 0.48, sat: 1.05),
            vivid.toned(v: 0.72, sat: 1.15),
            third.toned(v: 0.88, sat: 0.6),
            vivid.toned(v: 0.24, sat: 0.9),
        ]
    }
}
