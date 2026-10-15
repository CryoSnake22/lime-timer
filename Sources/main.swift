import Cocoa
import Combine
import SwiftUI
import Carbon.HIToolbox
import AVFoundation
import ServiceManagement

// MARK: - Shortcuts (all use ⌃⌥ + key — change here if they clash with another app)

let hotkeyModifiers = UInt32(controlKey | optionKey)

enum Action: UInt32 { case new = 1, pause, stop, restart, next, prev, toggle, settings, edit }

let hotkeys: [(Action, Int)] = [
    (.new, kVK_ANSI_N),      // new timer
    (.pause, kVK_ANSI_P),    // pause / resume
    (.stop, kVK_ANSI_S),     // stop (remove) timer
    (.restart, kVK_ANSI_R),  // restart timer
    (.next, kVK_ANSI_J),     // select next timer
    (.prev, kVK_ANSI_K),     // select previous timer
    (.toggle, kVK_ANSI_H),   // hide / show panel
    (.settings, kVK_ANSI_Comma), // settings (⌘, also works while QuickTimer is focused)
    (.edit, kVK_ANSI_E),     // edit the current timer's time
]

enum HotKeyCenter {
    static var handler: ((Action) -> Void)?

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let action = Action(rawValue: id.id) {
                HotKeyCenter.handler?(action) // already on the main thread; no extra hop
            }
            return noErr
        }, 1, &spec, nil, nil)

        for (action, key) in hotkeys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5154_4D52), id: action.rawValue) // 'QTMR'
            let status = RegisterEventHotKey(UInt32(key), hotkeyModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status != noErr { NSLog("QuickTimer: could not register hotkey for \(action)") }
        }
    }
}

// MARK: - Window-server blur (private but long-stable API, same one iTerm2 uses)
// Applies a true Gaussian blur behind the window, masked to its non-transparent pixels (the card).

#if !APPSTORE // App Store builds may only use public APIs (guideline 2.5.1)
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetWindowBackgroundBlurRadius")
func CGSSetWindowBackgroundBlurRadius(_ cid: Int32, _ wid: Int32, _ radius: Int32) -> Int32
#endif

let maxBlurRadius = 40.0

/// "QuickTimer" for the dev build, "Lime Timer" for the App Store build (from Info.plist).
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "QuickTimer"

let privacyPolicyURL = URL(string: "https://cryosnake22.github.io/lime-timer/privacy.html")!

// The ONLY difference between the dev build and the App Store build (-D APPSTORE) is the blur:
// dev uses a private window-server call (adjustable radius); App Store uses public APIs only.
// Every other feature must stay identical in both — don't add other #if APPSTORE blocks.
#if APPSTORE

/// Public-API blur: the standard NSVisualEffectView with its tint layers hidden, which leaves a
/// true-colour Gaussian blur (fixed strength). If a future macOS renames those layers, this
/// simply falls back to Apple's normal tinted blur.
final class ClearBlurView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        maskImage = ClearBlurView.roundedMask(radius: 6)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); hideTint() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hideTint() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); hideTint() }

    private func hideTint() {
        func walk(_ l: CALayer) {
            if ["fill", "tone", "desktop tint"].contains(l.name ?? "") { l.isHidden = true }
            l.sublayers?.forEach(walk)
        }
        if let l = layer { walk(l) }
    }

    /// Stretchable rounded-rect mask so the blur matches the card's corners.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

struct NativeBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> ClearBlurView { ClearBlurView(frame: .zero) }
    func updateNSView(_ v: ClearBlurView, context: Context) {}
}
#endif

// MARK: - Sounds

enum Sounds {
    /// "Ta-ding!" played when a timer is stopped — synthesized, so no sound file to ship.
    static let tading: AVAudioPlayer? = {
        let player = try? AVAudioPlayer(data: synthesizeTading())
        player?.volume = 0.6
        player?.prepareToPlay()
        return player
    }()

    static func playTading() {
        tading?.currentTime = 0
        tading?.play()
    }

    /// Short "ta" (C6) then a ringing bell-like "ding" (G6), as 16-bit mono WAV data.
    private static func synthesizeTading() -> Data {
        let rate = 44_100.0, length = 0.9
        let notes: [(start: Double, freq: Double, decay: Double, gain: Double)] = [
            (0.00, 1046.5, 0.07, 0.45), // ta
            (0.10, 1568.0, 0.32, 0.6),  // ding
        ]
        var samples = [Int16](repeating: 0, count: Int(rate * length))
        for i in samples.indices {
            let t = Double(i) / rate
            var v = 0.0
            for n in notes where t >= n.start {
                let dt = t - n.start
                let env = min(1, dt / 0.004) * exp(-dt / n.decay) // 4ms attack, exponential ring-out
                // Fundamental + octave + a slightly inharmonic partial for a bell-ish shimmer.
                v += n.gain * env * (sin(2 * .pi * n.freq * dt)
                    + 0.35 * sin(2 * .pi * n.freq * 2 * dt)
                    + 0.12 * sin(2 * .pi * n.freq * 2.76 * dt))
            }
            samples[i] = Int16(max(-1, min(1, v * 0.5)) * Double(Int16.max))
        }
        var data = Data()
        func put<T: FixedWidthInteger>(_ x: T) { withUnsafeBytes(of: x.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate) * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        samples.forEach { put($0) }
        return data
    }
}

// MARK: - Model

final class TimerItem: Identifiable {
    let id = UUID()
    let label: String
    private(set) var duration: TimeInterval? // nil = stopwatch
    private var accumulated: TimeInterval = 0
    private var startedAt: Date? = Date()
    private var pausedAccumulated: TimeInterval = 0
    private var pausedAt: Date?
    var alerted = false
    /// Stopped while other timers are running: shows a checkmark in the list, then leaves it.
    var stopped = false

    init(label: String, duration: TimeInterval?) {
        self.label = label
        self.duration = duration
    }

    var running: Bool { startedAt != nil }
    var elapsed: TimeInterval { accumulated + (startedAt.map { Date().timeIntervalSince($0) } ?? 0) }
    var remaining: TimeInterval? { duration.map { $0 - elapsed } }
    var finished: Bool { (remaining ?? 1) <= 0 }
    var progress: Double { duration.map { min(1, elapsed / $0) } ?? 0 }

    var hasBeenPaused: Bool { pausedAt != nil || pausedAccumulated > 0 }

    /// Total time spent paused, including the current pause.
    var pausedTotal: TimeInterval { pausedAccumulated + (pausedAt.map { Date().timeIntervalSince($0) } ?? 0) }

    func pause() { accumulated = elapsed; startedAt = nil; pausedAt = Date() }
    func resume() { pausedAccumulated = pausedTotal; pausedAt = nil; startedAt = Date() }
    func reset() { accumulated = 0; startedAt = Date(); pausedAccumulated = 0; pausedAt = nil; alerted = false }

    /// Freeze/unfreeze without counting it as paused time (used while editing).
    func hold() { accumulated = elapsed; startedAt = nil }
    func unhold() { startedAt = Date() }

    /// Restart at a new time: countdowns get a fresh duration, stopwatches jump to that elapsed time.
    func restart(at time: TimeInterval) {
        reset()
        if duration != nil { duration = time } else { accumulated = time }
    }

    var display: String {
        guard let remaining else { return format(Int(elapsed)) }
        return remaining > 0 ? format(Int(remaining.rounded(.up))) : "+" + format(Int(-remaining))
    }
}

func format(_ seconds: Int) -> String {
    let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

/// "25m focus", "1h30 deep work", "90s", "1:30", "45" (minutes), "" → stopwatch
func parseInput(_ input: String) -> (TimeInterval?, String) {
    var duration: TimeInterval?
    var words: [String] = []
    for token in input.split(separator: " ").map(String.init) {
        if duration == nil, let d = parseDuration(token) { duration = d } else { words.append(token) }
    }
    return (duration, words.joined(separator: " "))
}

func parseDuration(_ token: String) -> TimeInterval? {
    let s = token.lowercased() as NSString
    if s.contains(":") {
        let parts = s.components(separatedBy: ":").map { Double($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let total = parts.reduce(0) { $0 * 60 + $1! }
        return total > 0 ? total : nil
    }
    if let minutes = Double(s as String) { return minutes > 0 ? minutes * 60 : nil }

    let re = try! NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)([hms])")
    var total = 0.0, consumed = 0, lastUnit = ""
    for m in re.matches(in: s as String, range: NSRange(location: 0, length: s.length)) {
        guard m.range.location == consumed else { return nil }
        let n = Double(s.substring(with: m.range(at: 1)))!
        lastUnit = s.substring(with: m.range(at: 2))
        total += n * (lastUnit == "h" ? 3600 : lastUnit == "m" ? 60 : 1)
        consumed = m.range.location + m.range.length
    }
    let rest = s.substring(from: consumed)
    if !rest.isEmpty {
        guard consumed > 0, lastUnit == "h", let n = Double(rest) else { return nil } // "1h30" → 1h 30m
        total += n * 60
    }
    return total > 0 ? total : nil
}

final class Store: ObservableObject {
    @Published var timers: [TimerItem] = []
    @Published var selectedID: UUID?
    @Published var inputActive = false
    @Published var settingsOpen = false
    @Published var hovering = false  // layout: card is at its expanded size
    @Published var revealed = false  // extras (header, buttons, footer, help) are visible — follows `hovering` in a second phase
    @Published var now = Date()

    /// Shown for a moment after stopping a timer: animated checkmark, then fade out.
    struct Closing { let id = UUID(); let label: String; let time: String }
    @Published var closing: Closing?
    /// Lime border for the "done" card — shown a beat after `closing`, once the old UI has faded out.
    @Published var closingBorder = false
    @Published var fadingOut = false
    var cardSize: CGSize = .zero // measured by the view; used for hover hit-testing

    // Settings
    @Published var opacity: Double = UserDefaults.standard.object(forKey: "opacity") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(opacity, forKey: "opacity") }
    }
    @Published var shakeEnabled: Bool = UserDefaults.standard.object(forKey: "shakeEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(shakeEnabled, forKey: "shakeEnabled") }
    }
    /// Bumped (animated) to play one shake; see `Shake`.
    @Published var shakes = 0
    /// Red border while a finished timer is still on screen (part of the shake alert).
    var alerting: Bool { shakeEnabled && active.contains { $0.finished } }
    /// Timers that are still running/paused (excludes ones on their way out of the list).
    var active: [TimerItem] { timers.filter { !$0.stopped } }
    @Published var soundEnabled: Bool = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }
    /// Frosted blur behind the card (0 = none). Visible whenever the background opacity is below 100%.
    @Published var blur: Double = UserDefaults.standard.object(forKey: "blur") as? Double ?? 0 {
        didSet { UserDefaults.standard.set(blur, forKey: "blur") }
    }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    static let minOpacity = 0.0 // only backgrounds fade; text always stays readable

    func setOpacity(_ value: Double) {
        opacity = (min(1, max(Store.minOpacity, value)) * 20).rounded() / 20 // 5% steps
    }

    func setBlur(_ value: Double) {
        #if APPSTORE
        blur = value > blur ? 1 : 0 // on/off only: the public-API blur has a fixed strength
        return
        #endif
        blur = (min(1, max(0, value)) * 20).rounded() / 20
    }

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("QuickTimer: launch at login failed: \(error)")
        }
        objectWillChange.send()
    }

    var onSubmit: ((String?) -> Void)?
    var onSettings: (() -> Void)? // toggles the settings view
    var onEditSubmit: ((String?) -> Void)?

    // Editing a timer's time (⌃⌥E)
    @Published var editingID: UUID?
    private var editWasRunning = false
    var editing: TimerItem? { timers.first { $0.id == editingID } }
    /// The panel has a text field open (new timer or edit).
    var typing: Bool { inputActive || editingID != nil }

    @discardableResult
    func beginEdit() -> Bool {
        guard let t = current else { return false }
        if editingID == nil {
            editWasRunning = t.running
            if t.running { t.hold() }
        }
        editingID = t.id
        selectedID = t.id
        touch()
        return true
    }

    /// nil = cancel (resume if it was running). Returns false if the text isn't a valid time.
    func finishEdit(_ text: String?) -> Bool {
        guard let t = editing else { editingID = nil; return true }
        if let text {
            guard let time = parseInput(text).0 else { return false }
            t.restart(at: time)
        } else if editWasRunning {
            t.unhold()
        }
        editingID = nil
        touch()
        return true
    }
    private var ticker: Timer?

    init() {
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    var current: TimerItem? { active.first { $0.id == selectedID } ?? active.last }

    private var lastSignature = ""

    private func tick() {
        guard !timers.isEmpty else { return }
        // Only redraw when a displayed value changes, but check often so seconds flip without lag.
        let blink = timers.contains { $0.finished } ? Int(Date().timeIntervalSince1970 * 2) % 2 : 0
        let signature = timers.map { "\($0.display)|\(Int($0.pausedTotal))" }.joined(separator: ",") + "\(blink)"
        if signature != lastSignature {
            lastSignature = signature
            now = Date()
        }
        for t in active where t.finished && !t.alerted {
            t.alerted = true
            // Three alerts, 1.2s apart: a chime and/or a shake each time.
            for i in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.2) { [weak self, weak t] in
                    // Stop alerting once the timer has been stopped.
                    guard let self, let t, self.timers.contains(where: { $0 === t }) else { return }
                    if self.soundEnabled { NSSound(named: "Glass")?.play() }
                    if self.shakeEnabled {
                        withAnimation(.linear(duration: 0.5)) { self.shakes += 1 }
                    }
                }
            }
        }
    }

    func add(_ input: String) {
        let (duration, label) = parseInput(input.trimmingCharacters(in: .whitespaces))
        let t = TimerItem(label: label.isEmpty ? (duration == nil ? "Stopwatch" : "Timer") : label, duration: duration)
        timers.append(t)
        selectedID = t.id
    }

    /// TimerItem is a class, so in-place changes are invisible to SwiftUI's diffing.
    /// Bumping `now` (which every timer view takes) forces an immediate redraw.
    private func touch() { now = Date() }

    func togglePause() {
        guard let t = current else { return }
        t.running ? t.pause() : t.resume()
        touch()
    }

    /// Dismisses a finished (ringing) timer first, otherwise the selected one.
    func stop() {
        guard let t = active.first(where: { $0.finished }) ?? current else { return }
        let info = Closing(label: t.label, time: format(Int(t.elapsed)))
        if soundEnabled { Sounds.playTading() }
        if editingID == t.id { editingID = nil }

        // Other timers still running: check this one off in the list, then let it leave the list.
        // The rest of the card (hero, other rows) carries on as normal.
        if active.count > 1 {
            withAnimation(.easeOut(duration: 0.2)) {
                if t.running { t.hold() }
                t.stopped = true
                if selectedID == t.id { selectedID = active.last?.id }
                touch()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self, weak t] in
                guard let self, let t else { return }
                withAnimation(.easeInOut(duration: 0.3)) { self.timers.removeAll { $0 === t } }
                self.touch()
            }
            return
        }

        withAnimation(.easeOut(duration: 0.2)) {
            timers.removeAll { $0 === t }
            if selectedID == t.id { selectedID = active.last?.id }
            closing = info
            closingBorder = false
            fadingOut = false
        }
        touch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.closing?.id == info.id else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.closingBorder = true }
        }
        // Hold the checkmark, then fade the card away (last timer) or hand over to the next one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.closing?.id == info.id else { return }
            if self.active.isEmpty && !self.inputActive {
                withAnimation(.easeIn(duration: 0.35)) { self.fadingOut = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard self.closing?.id == info.id else { return }
                    self.closing = nil
                    self.closingBorder = false
                    self.fadingOut = false
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { self.closing = nil; self.closingBorder = false }
            }
        }
    }

    /// Cancels the stop animation (e.g. when starting a new timer mid-fade).
    func clearClosing() {
        closing = nil
        closingBorder = false
        fadingOut = false
    }

    func restart() {
        current?.reset()
        touch()
    }

    func cycle(_ delta: Int) {
        let list = active
        guard let c = current, let i = list.firstIndex(where: { $0 === c }) else { return }
        selectedID = list[(i + delta + list.count) % list.count].id
        touch()
    }
}

// MARK: - Theme

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum Theme {
    static let bg = Color(hex: 0x0E0E10)
    static let raised = Color(hex: 0x1E1E21)
    static let border = Color(hex: 0x26262A)
    static let text = Color(hex: 0xECECEC)
    /// Secondary text. Lightens as the background fades so it stays readable over light content.
    static func dim(_ surface: Double) -> Color {
        let t = 1 - max(0, min(1, surface)) // 0 = solid bg, 1 = fully see-through
        let from = (0x8C, 0x8C, 0x90), to = (0xF4, 0xF4, 0xF6)
        func mix(_ a: Int, _ b: Int) -> Double { (Double(a) + (Double(b) - Double(a)) * t) / 255 }
        return Color(red: mix(from.0, to.0), green: mix(from.1, to.1), blue: mix(from.2, to.2))
    }
    static let lime = Color(hex: 0xE6F0A3)
    static let blue = Color(hex: 0x9FC6CF)
    static let orange = Color(hex: 0xE07A5F)
    static let red = Color(hex: 0xE5484D)
    static let grey = Color(hex: 0x3A3A3E)
}

/// Background opacity from settings. Text and lime accents ignore it; grey surfaces fade with it.
struct SurfaceOpacityKey: EnvironmentKey { static let defaultValue: Double = 1 }
extension EnvironmentValues {
    var surfaceOpacity: Double {
        get { self[SurfaceOpacityKey.self] }
        set { self[SurfaceOpacityKey.self] = newValue }
    }
}

extension Color {
    /// Raised greys (inputs, buttons, tracks) fade less than the card so they stay discernible.
    func surface(_ o: Double) -> Color { opacity(0.3 + 0.7 * o) }
}

func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

struct Notched: Shape {
    var cut: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + cut, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - cut))
        p.closeSubpath()
        return p
    }
}

// MARK: - Views

let panelWidth: CGFloat = 320   // expanded (hovered)
let compactWidth: CGFloat = 210 // resting card
let shadowMargin: CGFloat = 20  // transparent room around the card for its shadow
let windowSize = CGSize(width: panelWidth + shadowMargin * 2, height: 720)

struct PanelView: View {
    @ObservedObject var store: Store
    var surface: Double { store.opacity }

    /// Extras (header, buttons, shortcut help) only appear while the mouse is over the panel.
    var expanded: Bool { (store.hovering || store.settingsOpen) && store.closing == nil }
    /// Extras are laid out as soon as the card expands but only fade in once it has (nearly) settled,
    /// so nothing visibly slides in from the side while the card is still growing.
    var reveal: Double { store.revealed || store.settingsOpen ? 1 : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded { header.opacity(reveal).transition(.identity) }
            if store.settingsOpen {
                SettingsView(store: store)
            } else if let closing = store.closing {
                ClosingView(info: closing).id(closing.id)
            } else {
                if let t = store.current {
                    HeroView(t: t, now: store.now, store: store, showControls: expanded, controlsOpacity: reveal,
                             width: expanded || store.typing ? panelWidth : compactWidth)
                }
                if store.timers.count > 1 {
                    VStack(spacing: 2) {
                        ForEach(store.timers) { t in
                            RowView(t: t, now: store.now, selected: t.id == store.current?.id)
                                .onTapGesture { if !t.stopped { store.selectedID = t.id } }
                                .transition(.asymmetric(insertion: .opacity,
                                                        removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .leading))))
                        }
                    }
                    .padding(.bottom, 14)
                }
                if store.editingID != nil { editRow }
                if store.inputActive { inputRow }
            }
            if expanded { footer.opacity(reveal).transition(.identity) }
        }
        .frame(width: expanded || store.typing ? panelWidth : compactWidth)
        .background(ZStack {
            // The blur itself is done by the window server behind this; it only shows where the card
            // has some alpha, so keep a hint of background when blur is on.
            #if APPSTORE
            if store.blur > 0 { NativeBlur() }
            #endif
            Theme.bg.opacity(store.blur > 0 ? max(store.opacity, 0.04) : store.opacity)
        })
        // Faint light hairline so the card's edge stays visible on dark backgrounds too.
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .overlay(alertBorder)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .fixedSize(horizontal: false, vertical: true)
        .opacity(store.fadingOut ? 0 : 1)
        .scaleEffect(store.fadingOut ? 0.96 : 1, anchor: .topTrailing)
        .modifier(Shake(progress: CGFloat(store.shakes)))
        .background(GeometryReader { g in
            Color.clear
                .onAppear { store.cardSize = g.size }
                .onChange(of: g.size) { store.cardSize = $0 }
        })
        .environment(\.surfaceOpacity, store.opacity)
        // Shadow fades with the background; a faint one remains so text stays legible on light content.
        // No shadow with blur: the window server would blur under the shadow too, making a halo.
        .shadow(color: .black.opacity(store.blur > 0 ? 0 : 0.15 + 0.3 * store.opacity), radius: 12, y: 4)
        .padding(shadowMargin)
        // The window never resizes: the card grows/shrinks inside it, anchored top-right,
        // so hover expansion is a single animated SwiftUI change.
        .frame(width: windowSize.width, height: windowSize.height, alignment: .topTrailing)
    }

    /// Pulsing red border while a finished timer is waiting to be stopped.
    @ViewBuilder var alertBorder: some View {
        if store.closing != nil {
            // Stopped: lime border to match the checkmark, drawn the same way as the red "time's up" one.
            if store.closingBorder {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.lime, lineWidth: 2.5)
                    .transition(.opacity)
            }
        } else if store.alerting {
            let bright = Int(store.now.timeIntervalSince1970 * 2) % 2 == 0
            // strokeBorder keeps the whole line inside the card; a centred stroke loses its outer half to the clip.
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.red.opacity(bright ? 1 : 0.7), lineWidth: 2.5)
                .animation(.easeInOut(duration: 0.4), value: bright)
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            Text(store.settingsOpen ? "SETTINGS" : store.timers.isEmpty ? appName.uppercased() : "\(store.active.count) ACTIVE")
                .font(mono(10)).tracking(1.5).foregroundColor(Theme.dim(surface)).legible()
            Spacer()
            if !store.settingsOpen {
                IconButton(icon: "gearshape.fill") { store.onSettings?() }
            }
            if store.inputActive || store.settingsOpen {
                IconButton(icon: "xmark") { store.settingsOpen ? store.onSettings?() : store.onSubmit?(nil) }
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 2)
    }

    var editRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EDIT TIME").font(mono(10)).tracking(1.5).foregroundColor(Theme.dim(surface)).legible()
            InputField(placeholder: "10m · 1h30 · 1:30",
                       onSubmit: { store.onEditSubmit?($0) }, onCancel: { store.onEditSubmit?(nil) })
                .frame(height: 22)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.raised.surface(store.opacity))
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
    }

    var inputRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEW TIMER").font(mono(10)).tracking(1.5).foregroundColor(Theme.dim(surface)).legible()
            InputField(onSubmit: { text in store.onSubmit?(text) }, onCancel: { store.onSubmit?(nil) })
                .frame(height: 22)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.raised.surface(store.opacity))

            if store.hovering {
                // One group so the help slides in as a unit (a lazy grid would pop items in one by one).
                VStack(alignment: .leading, spacing: 8) {
                    Text("25m focus · 1h30 · 90s · blank = stopwatch")
                        .font(mono(9)).foregroundColor(Theme.dim(surface).opacity(0.7)).legible()
                    Text("SHORTCUTS  ⌃⌥ +").font(mono(10)).tracking(1.5).foregroundColor(Theme.dim(surface)).legible()
                        .padding(.top, 14)
                    let keys = [("N", "NEW"), ("P", "PAUSE"), ("S", "STOP"), ("R", "RESTART"), ("J/K", "SWITCH"), ("E", "EDIT TIME"), ("H", "HIDE"), (",", "SETTINGS")]
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 8) {
                        ForEach(0..<4, id: \.self) { row in
                            GridRow {
                                ForEach(0..<2, id: \.self) { col in
                                    let (key, title) = keys[row * 2 + col]
                                    HStack(spacing: 8) {
                                        KeyCap(key)
                                        Text(title).font(mono(10)).tracking(1).foregroundColor(Theme.text).legible()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                .opacity(reveal)
                .transition(.identity)
            }
        }
        .padding(.horizontal, 20).padding(.top, store.timers.isEmpty ? 16 : 0).padding(.bottom, 16)
    }

    var footer: some View {
        HStack {
            Text(store.settingsOpen ? "←/→ OPACITY · ⇧ BLUR" : store.editingID != nil ? "↵ RESTART AT TIME" : store.inputActive ? "↵ START" : "⌃⌥N NEW · ⌃⌥E EDIT")
            Spacer()
            Text(store.editingID != nil ? "ESC CANCEL" : store.settingsOpen || store.inputActive ? "ESC CLOSE" : "⌘, SETTINGS")
        }
        .font(mono(9)).tracking(1).foregroundColor(Theme.dim(surface).opacity(0.8)).legible()
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(Rectangle().fill(Theme.border.surface(store.opacity)).frame(height: 1), alignment: .top)
    }
}

struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.18, y: r.minY + r.height * 0.52))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.76))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.84, y: r.minY + r.height * 0.26))
        return p
    }
}

struct ClosingView: View {
    @Environment(\.surfaceOpacity) var surface
    let info: Store.Closing
    @State private var popped = false
    @State private var drawn = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.lime.opacity(0.14))
                Circle().stroke(Theme.lime.opacity(0.5), lineWidth: 1.5)
                CheckShape()
                    .trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(Theme.lime, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .padding(10)
            }
            .frame(width: 40, height: 40)
            .scaleEffect(popped ? 1 : 0.5)
            .opacity(popped ? 1 : 0)

            VStack(alignment: .leading, spacing: 5) {
                Text(info.label.uppercased()).font(mono(10)).tracking(1.5).foregroundColor(Theme.dim(surface)).lineLimit(1).legible()
                Text("DONE · \(info.time)").font(mono(13, .medium)).tracking(1).foregroundColor(Theme.text).legible()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 18)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { popped = true }
            withAnimation(.easeOut(duration: 0.35).delay(0.1)) { drawn = true }
        }
    }
}

/// For text sitting directly on the (possibly see-through) card — not text on buttons.
/// Adds a soft dark halo that grows as the background fades, so it reads over light content.
struct Legible: ViewModifier {
    @Environment(\.surfaceOpacity) var surface
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(0.7 * (1 - surface)), radius: 2.5, y: 0.5)
    }
}

extension View {
    func legible() -> some View { modifier(Legible()) }
}

/// One spring for every hover/expand change, so everything moves together.
let panelSpring = Animation.spring(response: 0.3, dampingFraction: 0.9)

/// The big time, rendered once at 40pt and scaled as a whole. Animating the font size instead
/// re-lays-out the glyphs every frame, which makes the digits jitter while the card resizes.
struct ScaledTime: View {
    let text: String
    let scale: CGFloat

    var body: some View {
        let natural = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 40, weight: .medium),
        ]).size()
        Text(text)
            .font(mono(40, .medium))
            .fixedSize()
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: ceil(natural.width) * scale, height: ceil(natural.height) * scale, alignment: .topLeading)
    }
}

struct Shake: GeometryEffect {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let phase = progress - progress.rounded(.down) // 0→1 within the current shake
        guard phase > 0 else { return ProjectionTransform(.identity) }
        let x = 9 * (1 - phase) * sin(phase * .pi * 8)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key).font(mono(10, .medium)).foregroundColor(.black)
            .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 18)
            .background(Theme.lime.opacity(0.9))
    }
}

struct IconButton: View {
    @Environment(\.surfaceOpacity) var surface
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundColor(Theme.dim(surface)).legible()
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LimeSlider(title: "OPACITY", value: store.opacity, surface: store.opacity) { store.setOpacity($0) }
            #if APPSTORE
            ToggleRow(title: "BLUR BACKGROUND", on: store.blur > 0) { store.setBlur(store.blur > 0 ? 0 : 1) }
            #else
            LimeSlider(title: "BLUR", value: store.blur, surface: store.opacity) { store.setBlur($0) }
            #endif
            ToggleRow(title: "SOUNDS", on: store.soundEnabled) { store.soundEnabled.toggle() }
            ToggleRow(title: "SHAKE WHEN DONE", on: store.shakeEnabled) { store.shakeEnabled.toggle() }
            ToggleRow(title: "LAUNCH AT LOGIN", on: store.launchAtLogin) { store.toggleLaunchAtLogin() }
            Button { NSWorkspace.shared.open(privacyPolicyURL) } label: {
                Text("PRIVACY POLICY ↗").font(mono(9)).tracking(1.5).foregroundColor(Theme.dim(store.opacity)).legible()
            }
            .buttonStyle(.plain)
            QuitButton()
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 20)
    }
}

struct LimeSlider: View {
    let title: String
    let value: Double // 0...1
    let surface: Double
    let onChange: (Double) -> Void
    let width = panelWidth - 40

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))%").foregroundColor(Theme.text)
            }
            .font(mono(10)).tracking(1.5).foregroundColor(Theme.dim(surface)).legible()

            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.raised.surface(surface))
                Notched(cut: 6).fill(Theme.lime).frame(width: max(14, width * value))
            }
            .frame(width: width, height: 26)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { onChange(Double($0.location.x / width)) })
        }
    }
}

struct QuitButton: View {
    @Environment(\.surfaceOpacity) var surface
    @State private var hovering = false

    var body: some View {
        Button { NSApp.terminate(nil) } label: {
            HStack {
                Image(systemName: "power").font(.system(size: 10, weight: .bold))
                Text("QUIT \(appName.uppercased())").font(mono(10, .medium)).tracking(1.5)
                Spacer()
                Text("⌘Q").font(mono(10)).opacity(0.6)
            }
            .foregroundColor(hovering ? Theme.red : Theme.text)
            .padding(.horizontal, 12).frame(height: 30)
            .background(Theme.raised.surface(surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.top, 4)
    }
}

struct ToggleRow: View {
    @Environment(\.surfaceOpacity) var surface
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title).font(mono(10)).tracking(1.5).foregroundColor(Theme.dim(surface)).legible()
            Spacer()
            Button(action: action) {
                Text(on ? "ON" : "OFF").font(mono(10, .medium)).tracking(1)
                    .foregroundColor(on ? .black : Theme.dim(1))
                    .frame(width: 56, height: 26)
                    .background(Notched(cut: on ? 5 : 0).fill(on ? Theme.lime : Theme.raised.surface(surface)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct HeroView: View {
    @Environment(\.surfaceOpacity) var surface
    let t: TimerItem
    let now: Date
    let store: Store
    let showControls: Bool
    let controlsOpacity: Double
    let width: CGFloat

    var body: some View {
        let compact = width < panelWidth
        let blinkOff = t.finished && Int(now.timeIntervalSince1970 * 2) % 2 == 0
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            HStack {
                Text(t.label.uppercased()).lineLimit(1)
                Spacer()
                Text(store.editingID == t.id ? "EDITING" : t.finished ? "DONE" : !t.running ? "PAUSED" : t.duration.map { "OF " + format(Int($0)) } ?? "STOPWATCH")
            }
            .font(mono(10)).tracking(1.5).foregroundColor(Theme.dim(surface)).legible()

            HStack(alignment: .bottom) {
                ScaledTime(text: t.display, scale: compact ? 28.0 / 40 : 1)
                    .foregroundColor(t.finished ? Theme.orange : t.running ? Theme.text : Theme.dim(surface)).legible()
                    .opacity(blinkOff ? 0.35 : 1)
                Spacer(minLength: 8)
                // Total time paused — appears the moment the timer is first paused.
                // Laid out at one fixed size and scaled as a unit, so icon and digits never drift apart.
                if t.hasBeenPaused {
                    HStack(spacing: 4) {
                        Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold))
                        Text(format(Int(t.pausedTotal))).font(mono(13, .medium))
                    }
                    .fixedSize()
                    .scaleEffect(compact ? 11.0 / 13 : 1, anchor: .bottomTrailing)
                    .foregroundColor(t.running ? Theme.dim(surface) : Theme.lime).legible()
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: t.hasBeenPaused)

            if t.duration != nil {
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.raised.surface(store.opacity))
                    Rectangle().fill(t.finished ? Theme.orange : Theme.lime)
                        .frame(width: (width - (compact ? 32 : 40)) * t.progress)
                }
                .frame(height: 2)
            }

            if showControls {
                HStack(spacing: 6) {
                Chip(icon: t.running ? "pause.fill" : "play.fill", title: t.running ? "PAUSE" : "RESUME", primary: true) { store.togglePause() }
                Chip(icon: "xmark", title: "STOP") { store.stop() }
                Chip(icon: "arrow.counterclockwise", title: "RESET") { store.restart() }
                }
                .opacity(controlsOpacity)
                .transition(.identity)
            }
        }
        .padding(.horizontal, compact ? 16 : 20)
        .padding(.top, compact ? 14 : showControls ? 14 : 18).padding(.bottom, compact ? 14 : 20)
    }
}

struct Chip: View {
    @Environment(\.surfaceOpacity) var surface
    let icon: String, title: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(title).font(mono(10, .medium)).tracking(1).lineLimit(1).fixedSize()
            }
            .foregroundColor(primary ? .black : Theme.text)
            .frame(maxWidth: .infinity).frame(height: 32)
            .background(Notched(cut: primary ? 6 : 0).fill(primary ? Theme.lime : Theme.raised.surface(surface)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Lime square with a checkmark that draws itself in — the list-row version of ClosingView.
struct RowCheck: View {
    @State private var drawn = false
    var body: some View {
        ZStack {
            Rectangle().fill(Theme.lime)
            CheckShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(Color.black.opacity(0.8), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .padding(6)
        }
        .frame(width: 26, height: 26)
        .onAppear { withAnimation(.easeOut(duration: 0.3).delay(0.05)) { drawn = true } }
    }
}

struct RowView: View {
    @Environment(\.surfaceOpacity) var surface
    let t: TimerItem
    let now: Date // forces a redraw when time moves
    let selected: Bool

    var body: some View {
        let (color, icon): (Color, String) =
            t.finished ? (Theme.orange, "bell.fill")
            : !t.running ? (Theme.grey, "pause.fill")
            : t.duration == nil ? (Theme.lime, "stopwatch.fill") : (Theme.blue, "hourglass")
        HStack(spacing: 12) {
            if t.stopped {
                RowCheck() // same lime checkmark as the "done" card, drawn in
            } else {
                Rectangle().fill(color).frame(width: 26, height: 26)
                    .overlay(Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundColor(.black.opacity(0.8)))
            }
            Text(t.label.uppercased()).font(mono(11, .medium)).tracking(1.2).lineLimit(1)
                .foregroundColor(selected || t.stopped ? Theme.text : Theme.dim(surface)).legible()
            Spacer()
            if !t.stopped { // a stopped row is just the checkmark + green highlight
                Text(t.display).font(mono(11)).foregroundColor(t.finished ? Theme.orange : Theme.dim(surface)).legible()
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 6)
        .background(t.stopped ? Theme.lime.opacity(0.16) : selected ? Theme.raised.surface(surface).opacity(0.6) : Color.clear)
        .overlay(Rectangle().fill(selected || t.stopped ? Theme.lime : .clear).frame(width: 2), alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct InputField: NSViewRepresentable {
    var placeholder = "25m focus"
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        f.textColor = .white
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(white: 1, alpha: 0.25),
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
        ])
        f.delegate = context.coordinator
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.currentEditor() == nil {
            DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InputField
        init(_ parent: InputField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                let text = control.stringValue
                DispatchQueue.main.async { self.parent.onSubmit(text) }
                return true
            }
            if sel == #selector(NSResponder.cancelOperation(_:)) {
                DispatchQueue.main.async { self.parent.onCancel() }
                return true
            }
            return false
        }
    }
}

// MARK: - Panel & app

final class HostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store()
    var panel: Panel!
    var statusItem: NSStatusItem!
    /// Top-right corner of the panel window, remembered between launches.
    var anchor: NSPoint? = AppDelegate.savedAnchor()
    let isDemo = ProcessInfo.processInfo.environment["QT_DEMO"] != nil
    var userHidden = false
    var previousApp: NSRunningApplication?
    var hosting: HostingView<PanelView>!
    var cancellable: AnyCancellable?
    var hoverTimer: Timer?
    var hoverTarget = false               // where the hover state is heading (phases may still be running)
    var hoverPhase: DispatchWorkItem?     // the pending second phase of a hover change
    var appliedBlur: Int32 = -1
    var hiding = false
    var focusedAt = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = Panel(contentRect: NSRect(origin: .zero, size: windowSize),
                      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the card draws its own shadow
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        hosting = HostingView(rootView: PanelView(store: store))
        hosting.sizingOptions = []
        panel.contentView = hosting

        store.onSubmit = { [weak self] text in self?.endInput(text) }
        store.onSettings = { [weak self] in self?.toggleSettings() }
        store.onEditSubmit = { [weak self] text in self?.endEdit(text) }
        cancellable = store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }

        HotKeyCenter.handler = { [weak self] in self?.handle($0) }
        HotKeyCenter.register()
        setupStatusItem()

        // Hover detection that works even while another app is focused.
        let hover = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let pointerInside = self.panel.isVisible && self.cardRect.contains(NSEvent.mouseLocation)
            // While dragging the card (button held after hovering), stay expanded even if the pointer outruns the window.
            let dragging = self.hoverTarget && NSEvent.pressedMouseButtons & 1 != 0
            let inside = pointerInside || dragging
            // Only the card takes clicks; the transparent rest of the window passes them through.
            self.panel.ignoresMouseEvents = !inside
            if inside != self.hoverTarget { self.setHover(inside) }
        }
        RunLoop.main.add(hover, forMode: .common)
        hoverTimer = hover

        // In-app keys: ⌘, settings · Esc closes settings · ←/→ adjust opacity.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers == "," { self.toggleSettings(); return nil }
            // Menu-bar apps have no app menu, so ⌘Q needs handling by hand.
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "q" { NSApp.terminate(nil); return nil }
            guard self.store.settingsOpen else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape: self.toggleSettings(); return nil
            case kVK_LeftArrow, kVK_RightArrow:
                let step = event.keyCode == UInt16(kVK_LeftArrow) ? -0.05 : 0.05
                if event.modifierFlags.contains(.shift) { self.store.setBlur(self.store.blur + step) }
                else { self.store.setOpacity(self.store.opacity + step) }
                return nil
            default: return event
            }
        }

        // Opened directly (Finder, Spotlight, Raycast…) → show the panel. Launched at login → stay quiet.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        let demo = ProcessInfo.processInfo.environment["QT_DEMO"]
        if let demo {
            // Testing/screenshots: QT_DEMO="25m focus" starts that timer at a fixed spot, without stealing focus.
            anchor = NSPoint(x: 700, y: 700)
            store.add(demo)
        } else if !atLogin {
            beginInput()
        }
    }

    // Opening the app again while it's already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        beginInput()
        return false
    }

    /// Two-phase hover so nothing slides around while the card resizes:
    /// in  → the card grows (extras laid out but invisible), then the extras fade in where they belong;
    /// out → the extras fade out, then the card shrinks.
    func setHover(_ on: Bool) {
        hoverTarget = on
        hoverPhase?.cancel()
        let second: DispatchWorkItem
        if on {
            withAnimation(panelSpring) { store.hovering = true }
            second = DispatchWorkItem { [weak self] in
                withAnimation(.easeOut(duration: 0.18)) { self?.store.revealed = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: second)
        } else {
            withAnimation(.easeOut(duration: 0.1)) { store.revealed = false }
            second = DispatchWorkItem { [weak self] in
                withAnimation(panelSpring) { self?.store.hovering = false }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: second)
        }
        hoverPhase = second
    }

    func handle(_ action: Action) {
        switch action {
        case .new: beginInput()
        case .pause: store.togglePause()
        case .stop: store.stop()
        case .restart: store.restart()
        case .next: store.cycle(1)
        case .prev: store.cycle(-1)
        case .toggle: userHidden.toggle(); refresh()
        case .settings: toggleSettings()
        case .edit: beginEdit()
        }
    }

    func refresh() {
        let show = (!store.timers.isEmpty || store.inputActive || store.settingsOpen || store.closing != nil) && !userHidden
        // Dragging the background moves the panel — except in settings, where it would steal slider drags.
        panel.isMovableByWindowBackground = !store.settingsOpen
        if show {
            if hiding { // re-shown mid fade-out: cancel it
                hiding = false
                NSAnimationContext.runAnimationGroup { $0.duration = 0; panel.animator().alphaValue = 1 }
            }
            layout()
            if !panel.isVisible { panel.orderFrontRegardless() }
            #if !APPSTORE
            let radius = Int32((store.blur * maxBlurRadius).rounded())
            if radius != appliedBlur {
                _ = CGSSetWindowBackgroundBlurRadius(CGSMainConnectionID(), Int32(panel.windowNumber), radius)
                appliedBlur = radius
            }
            #endif
        } else if panel.isVisible && !hiding {
            // Fade out instead of snapping away.
            hiding = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.hiding else { return }
                self.hiding = false
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            })
        }
    }

    /// Positions the (fixed-size) window so the card's top-right corner sits at the anchor.
    func layout() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let tr = anchor ?? NSPoint(x: screen.maxX - 14 + shadowMargin, y: screen.maxY - 10 + shadowMargin)
        let frame = NSRect(x: tr.x - windowSize.width, y: tr.y - windowSize.height,
                           width: windowSize.width, height: windowSize.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    /// The visible card in screen coordinates.
    var cardRect: NSRect {
        let f = panel.frame, size = store.cardSize
        return NSRect(x: f.maxX - shadowMargin - size.width, y: f.maxY - shadowMargin - size.height,
                      width: size.width, height: size.height)
    }

    func windowDidMove(_ note: Notification) {
        let point = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        anchor = point
        guard !isDemo else { return } // test runs must not overwrite your saved position
        UserDefaults.standard.set([point.x, point.y], forKey: "anchor")
    }

    /// The saved position, if it's still on a connected screen (displays may have changed).
    static func savedAnchor() -> NSPoint? {
        let xy = (UserDefaults.standard.array(forKey: "anchor") ?? []).compactMap { v -> Double? in
            (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
        }
        guard xy.count == 2 else { return nil }
        // Check the card's actual top-right corner (the window extends past it by the shadow margin).
        let card = NSPoint(x: xy[0] - shadowMargin - 10, y: xy[1] - shadowMargin - 10)
        guard NSScreen.screens.contains(where: { $0.frame.contains(card) }) else { return nil }
        return NSPoint(x: xy[0], y: xy[1])
    }

    /// Brings the panel to the front with keyboard focus, remembering the app to return to.
    func focusPanel() {
        if let front = NSWorkspace.shared.frontmostApplication, front != .current { previousApp = front }
        userHidden = false
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        focusedAt = Date()
    }

    /// Clicking away closes the new-timer box, same as Esc. Running timer cards stay.
    func windowDidResignKey(_ note: Notification) {
        // Ignore focus hiccups during the activation handoff right after opening.
        guard Date().timeIntervalSince(focusedAt) > 0.3 else { return }
        if store.editingID != nil { _ = store.finishEdit(nil) } // cancel edit → resume
        if store.inputActive { store.inputActive = false }
        previousApp = nil // the user already moved focus where they want it
    }

    func returnFocus() {
        previousApp?.activate()
        previousApp = nil
    }

    func beginInput() {
        if store.editingID != nil { _ = store.finishEdit(nil) }
        store.clearClosing()
        store.settingsOpen = false
        store.inputActive = true
        focusPanel()
    }

    func beginEdit() {
        store.clearClosing()
        store.settingsOpen = false
        store.inputActive = false
        guard store.beginEdit() else { return }
        focusPanel()
    }

    func endEdit(_ text: String?) {
        guard store.finishEdit(text) else { NSSound.beep(); return } // invalid time: keep the field open
        returnFocus()
    }

    func endInput(_ text: String?) {
        if let text { store.add(text) }
        store.inputActive = false
        returnFocus()
    }

    func toggleSettings() {
        if store.settingsOpen {
            store.settingsOpen = false
            returnFocus()
        } else {
            store.inputActive = false
            store.settingsOpen = true
            focusPanel()
        }
    }

    // MARK: Menu bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "timer", accessibilityDescription: appName)
        let menu = NSMenu()
        menu.addItem(item("New Timer  ⌃⌥N", #selector(menuNew)))
        menu.addItem(item("Show / Hide  ⌃⌥H", #selector(menuToggle)))
        menu.addItem(item("Settings…  ⌘,", #selector(menuSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), target: NSApp))
        statusItem.menu = menu
    }

    func item(_ title: String, _ sel: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = target ?? self
        return i
    }

    @objc func menuNew() { beginInput() }
    @objc func menuToggle() { handle(.toggle) }
    @objc func menuSettings() { if !store.settingsOpen { toggleSettings() } }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
