import SwiftUI
import AppKit
import IOKit.pwr_mgt
import IOKit.ps

@main
struct IdleModeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings = AppSettings()
    @StateObject private var nowPlaying = NowPlayingService()
    @StateObject private var ui = UIState()
    @StateObject private var timer = FocusTimer()
    @StateObject private var awake = DisplayAwake()

    var body: some Scene {
        WindowGroup("Idle Mode") {
            RootView()
                .environmentObject(settings)
                .environmentObject(nowPlaying)
                .environmentObject(ui)
                .environmentObject(timer)
                .environmentObject(awake)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
                .background(EnterFullScreenOnLaunch())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - Keeping the display on

/// Holds the display awake only while the chosen conditions are met (by default: on mains power or with an
/// external display connected). Otherwise it holds nothing, so the Mac's own display-sleep timer applies.
/// Re-checks when power or displays change, and every 30 s as a safety net.
@MainActor
final class DisplayAwake: ObservableObject {
    @Published private(set) var onPower = false
    @Published private(set) var externalDisplay = false
    @Published private(set) var keepingAwake = false
    var mode: KeepAwakeMode = .chargingOrExternal {
        didSet { if oldValue != mode { evaluate() } }
    }

    private var assertion: IOPMAssertionID = 0
    private var activity: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var powerSource: CFRunLoopSource?
    private var timer: Timer?

    func start(mode: KeepAwakeMode) {
        self.mode = mode
        guard timer == nil else { return }

        // Keep running at full speed in the background until the user quits (no App Nap, no automatic termination).
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Idle Mode shows live information")
        ProcessInfo.processInfo.disableAutomaticTermination("Idle Mode is open")

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<DisplayAwake>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in me.evaluate() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        evaluate()
    }

    func evaluate() {
        let ac = PowerInfo.read().onAC     // Macs without a battery report mains power
        let external = NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) == 0
        }
        if onPower != ac { onPower = ac }
        if externalDisplay != external { externalDisplay = external }

        let keep: Bool
        switch mode {
        case .chargingOrExternal: keep = ac || external
        case .chargingAndExternal: keep = ac && external
        case .always: keep = true
        case .never: keep = false
        }
        setAssertion(keep)
    }

    private func setAssertion(_ on: Bool) {
        if on, assertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Idle Mode is on screen" as CFString, &id)
            if result == 0 { assertion = id }   // kIOReturnSuccess
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        if keepingAwake != (assertion != 0) { keepingAwake = assertion != 0 }
    }

    /// Plain-language status for the Customise panel.
    var status: String {
        var reasons: [String] = []
        if onPower { reasons.append("plugged in") }
        if externalDisplay { reasons.append("external display") }
        if keepingAwake {
            return reasons.isEmpty ? "Screen stays on while Idle Mode is open."
                                   : "Screen stays on (\(reasons.joined(separator: " · ")))."
        }
        return "Following your Mac's display-sleep setting."
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Puts the window into full screen once, as soon as it's on screen.
struct EnterFullScreenOnLaunch: NSViewRepresentable {
    final class Probe: NSView {
        private var done = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !done, let window else { return }
            done = true
            window.collectionBehavior.insert(.fullScreenPrimary)
            DispatchQueue.main.async {
                if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}
