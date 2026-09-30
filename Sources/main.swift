import AppKit
import Darwin
import ServiceManagement
import Sparkle

// MARK: - Shared state

let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude-buddy/sessions", isDirectory: true)

struct Session: Codable {
    var id: String
    var state: String  // idle | working | waiting | done | error
    var updatedAt: Double
    var cwd: String?
    var activity: String?
    var prompt: String?
    var message: String?
    var startedAt: Double?
    var finishedAt: Double?
    var pid: Int32?
    var transcript: String?
    var hostApp: String?
    var iterm: String?

    var project: String { cwd.map { ($0 as NSString).lastPathComponent } ?? "claude" }
}

func now() -> Double { Date().timeIntervalSince1970 }

func sessionFile(_ id: String) -> URL {
    let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    return stateDir.appendingPathComponent("\(safe).json")
}

func loadSession(_ url: URL) -> Session? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Session.self, from: data)
}

func saveSession(_ s: Session) {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(s) {
        try? data.write(to: sessionFile(s.id), options: .atomic)
    }
}

func truncate(_ s: String?, _ n: Int) -> String? {
    guard var s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    s = s.replacingOccurrences(of: "\n", with: " ")
    return s.count > n ? String(s.prefix(n - 1)) + "…" : s
}

/// Reads the last `bytes` of a file as text.
func tail(_ path: String, bytes: Int) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    try? fh.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
    guard let data = try? fh.readToEnd() else { return nil }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Hook mode (`ClaudeBuddy hook`, fed JSON on stdin by Claude Code)

func parentInfo(_ pid: pid_t) -> (ppid: pid_t, name: String)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafePointer(to: info.kp_proc.p_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
    }
    return (info.kp_eproc.e_ppid, name)
}

/// The Claude Code process that spawned this hook (skipping any wrapper shell).
func claudePID() -> Int32 {
    var pid = getppid()
    for _ in 0..<3 {
        guard let info = parentInfo(pid), ["sh", "bash", "zsh", "dash"].contains(info.name) else { break }
        pid = info.ppid
    }
    return pid
}

func describeTool(_ name: String, _ input: [String: Any]) -> String {
    let file = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
    switch name {
    case "Read": return "Reading \(file)"
    case "Edit", "MultiEdit", "NotebookEdit": return "Editing \(file)"
    case "Write": return "Writing \(file)"
    case "Bash":
        if let d = input["description"] as? String { return d }
        return "Running \(truncate(input["command"] as? String, 30) ?? "a command")"
    case "Grep", "Glob": return "Searching \(truncate(input["pattern"] as? String, 24) ?? "")"
    case "WebFetch": return "Reading the web"
    case "WebSearch": return "Searching \(truncate(input["query"] as? String, 24) ?? "the web")"
    case "Agent", "Task": return "Delegating: \(truncate(input["description"] as? String, 30) ?? "subagent")"
    case "TodoWrite": return "Planning"
    default:
        let short = name.hasPrefix("mcp__") ? String(name.split(separator: "_").last ?? "") : name
        return "Using \(short)"
    }
}

func lastAssistantText(_ transcript: String?) -> String? {
    guard let path = transcript, let text = tail(path, bytes: 256 * 1024) else { return nil }
    for line in text.split(separator: "\n").reversed() {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]]
        else { continue }
        let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        if let t = texts.last { return t }
    }
    return nil
}

func runHook() {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sid = obj["session_id"] as? String,
          let event = obj["hook_event_name"] as? String
    else { return }

    if event == "SessionEnd" {
        try? FileManager.default.removeItem(at: sessionFile(sid))
        return
    }

    var s = loadSession(sessionFile(sid)) ?? Session(id: sid, state: "idle", updatedAt: now())
    let toolName = obj["tool_name"] as? String ?? ""
    let toolInput = obj["tool_input"] as? [String: Any] ?? [:]

    switch event {
    case "SessionStart":
        if s.state != "working" { s.state = "idle" }
    case "UserPromptSubmit":
        s.state = "working"
        s.startedAt = now()
        s.finishedAt = nil
        s.prompt = truncate(obj["prompt"] as? String, 80)
        s.activity = nil
        s.message = nil
    case "PreToolUse":
        s.state = "working"
        s.activity = describeTool(toolName, toolInput)
        if s.startedAt == nil { s.startedAt = now() }
    case "PostToolUse":
        s.state = "working"
    case "PermissionRequest":
        s.state = "waiting"
        s.message = "Wants to: \(describeTool(toolName, toolInput))"
    case "Notification":
        let type = obj["notification_type"] as? String
        let msg = obj["message"] as? String ?? ""
        let needsUser = type == "permission_prompt" || type == "elicitation_dialog"
            || (type == nil && msg.localizedCaseInsensitiveContains("permission"))
        guard needsUser else { return }
        s.state = "waiting"
        if s.message == nil || !(s.message!.hasPrefix("Wants to")) { s.message = msg }
    case "Stop":
        s.state = "done"
        s.finishedAt = now()
        s.message = truncate(
            (obj["last_assistant_message"] as? String)
                ?? lastAssistantText(obj["transcript_path"] as? String ?? s.transcript), 240)
    case "StopFailure":
        s.state = "error"
        s.finishedAt = now()
        s.message = truncate((obj["error"] as? String) ?? (obj["message"] as? String), 240)
            ?? "Something went wrong"
    default:
        return
    }

    s.updatedAt = now()
    s.cwd = obj["cwd"] as? String ?? s.cwd
    s.transcript = obj["transcript_path"] as? String ?? s.transcript
    s.pid = claudePID()
    let env = ProcessInfo.processInfo.environment
    s.hostApp = env["__CFBundleIdentifier"] ?? s.hostApp
    s.iterm = env["ITERM_SESSION_ID"].flatMap { $0.split(separator: ":").last.map(String.init) } ?? s.iterm
    saveSession(s)
}

// MARK: - The mascot

let claudeOrange = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)

enum Eyes { case open, blink, closed }

struct Pose: Equatable {
    var legPhase = 0  // 0 = standing, 1/2 = alternating steps
    var eyes = Eyes.open
    var eyeDX = 0
    var armsUp = false
    var leftArmUp = false
    var rightArmUp = false
}

/// Pixel size that keeps the sprite crisp (whole device pixels) and fits the menu bar.
let menuPixel: CGFloat = max(1, floor((NSStatusBar.system.thickness - 2) / 11 * 2) / 2)

struct Critter: Equatable {
    var x: Int
    var y: Int
    var pose: Pose
}

/// Draws a single 15x10 pixel critter onto a canvas `cols` wide and `rows` tall.
func spriteImage(cols: Int, rows: Int = 11, x: Int, y: Int, pose: Pose, pixel p: CGFloat = menuPixel) -> NSImage {
    sceneImage(cols: cols, rows: rows, critters: [Critter(x: x, y: y, pose: pose)], pixel: p)
}

/// Draws several critters onto one canvas.
func sceneImage(cols: Int, rows: Int = 11, critters: [Critter], pixel p: CGFloat = menuPixel) -> NSImage {
    let img = NSImage(size: NSSize(width: CGFloat(cols) * p, height: CGFloat(rows) * p), flipped: true) { _ in
        for critter in critters { drawCritter(critter, pixel: p) }
        return true
    }
    img.isTemplate = false
    return img
}

func drawCritter(_ critter: Critter, pixel p: CGFloat) {
    let (x, y, pose) = (critter.x, critter.y, critter.pose)
    func rect(_ c: Int, _ r: Int, _ w: Int, _ h: Int, _ color: NSColor = claudeOrange) {
        color.setFill()
        NSRect(x: CGFloat(x + c) * p, y: CGFloat(y + r) * p, width: CGFloat(w) * p, height: CGFloat(h) * p).fill()
    }
    rect(2, 0, 11, 8)  // body
    if pose.armsUp || pose.leftArmUp { rect(1, 4, 1, 1); rect(0, 2, 1, 2) } else { rect(0, 4, 2, 2) }
    if pose.armsUp || pose.rightArmUp { rect(13, 4, 1, 1); rect(14, 2, 1, 2) } else { rect(13, 4, 2, 2) }
    for (i, c) in [3, 5, 9, 11].enumerated() {
        let lifted = (pose.legPhase == 1 && i % 2 == 0) || (pose.legPhase == 2 && i % 2 == 1)
        rect(c, 8, 1, lifted ? 1 : 2)
    }
    let dx = pose.eyeDX
    switch pose.eyes {
    case .open: rect(4 + dx, 2, 1, 2, .black); rect(10 + dx, 2, 1, 2, .black)
    case .blink: rect(4 + dx, 3, 1, 1, .black); rect(10 + dx, 3, 1, 1, .black)
    case .closed: rect(3, 3, 2, 1, .black); rect(10, 3, 2, 1, .black)
    }
}

/// `ClaudeBuddy icon <dir.iconset>` renders the app icon.
func renderIconset(to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                         ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(size)
        let bg = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
        NSColor(srgbRed: 0xFA / 255, green: 0xF3 / 255, blue: 0xE6 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: bg, xRadius: s * 0.18, yRadius: s * 0.18).fill()
        let sprite = spriteImage(cols: 15, rows: 10, x: 0, y: 0, pose: Pose(), pixel: 2)
        let w = s * 0.62, h = w * 10 / 15
        sprite.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2 - s * 0.02, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
    }
}

// MARK: - The app

/// Claude Code's own spinner verbs (fallback when the terminal screen can't be read).
let verbs = [
    "Accomplishing", "Actioning", "Actualizing", "Architecting", "Baking", "Beaming", "Beboppin'", "Befuddling",
    "Billowing", "Blanching", "Bloviating", "Boogieing", "Boondoggling", "Booping", "Bootstrapping", "Brewing",
    "Bunning", "Burrowing", "Calculating", "Canoodling", "Caramelizing", "Cascading", "Catapulting", "Cerebrating",
    "Channeling", "Choreographing", "Churning", "Clauding", "Coalescing", "Cogitating", "Combobulating",
    "Composing", "Computing", "Concocting", "Considering", "Contemplating", "Cooking", "Crafting", "Creating",
    "Crunching", "Crystallizing", "Cultivating", "Deciphering", "Deliberating", "Determining", "Dilly-dallying",
    "Discombobulating", "Doing", "Doodling", "Drizzling", "Ebbing", "Effecting", "Elucidating", "Embellishing",
    "Enchanting", "Envisioning", "Fermenting", "Fiddle-faddling", "Finagling", "Flambéing", "Flibbertigibbeting",
    "Flowing", "Flummoxing", "Fluttering", "Forging", "Forming", "Frolicking", "Frosting", "Gallivanting",
    "Galloping", "Garnishing", "Generating", "Gesticulating", "Germinating", "Gitifying", "Grooving", "Gusting",
    "Harmonizing", "Hashing", "Hatching", "Herding", "Honking", "Hullaballooing", "Hyperspacing", "Ideating",
    "Imagining", "Improvising", "Incubating", "Inferring", "Infusing", "Ionizing", "Jitterbugging", "Julienning",
    "Kerfuffling", "Kneading", "Leavening", "Levitating", "Lollygagging", "Manifesting", "Marinating", "Meandering",
    "Metamorphosing", "Misting", "Moonwalking", "Moseying", "Mulling", "Mustering", "Musing", "Nebulizing",
    "Nesting", "Newspapering", "Noodling", "Nucleating", "Orbiting", "Orchestrating", "Osmosing", "Perambulating",
    "Percolating", "Perusing", "Philosophizing", "Photosynthesizing", "Pollinating", "Pondering", "Pontificating",
    "Pouncing", "Precipitating", "Prestidigitating", "Processing", "Proofing", "Propagating", "Puttering",
    "Puzzling", "Quantumizing", "Razzle-dazzling", "Razzmatazzing", "Recombobulating", "Reticulating", "Roosting",
    "Ruminating", "Sautéing", "Scampering", "Schlepping", "Scurrying", "Seasoning", "Shenaniganing", "Shimmying",
    "Simmering", "Skedaddling", "Sketching", "Slithering", "Smooshing", "Sock-hopping", "Spelunking", "Spinning",
    "Sprouting", "Stewing", "Sublimating", "Swirling", "Swooping", "Symbioting", "Synthesizing", "Tempering",
    "Thinking", "Thundering", "Tinkering", "Tomfoolering", "Topsy-turvying", "Transfiguring", "Transmogrifying",
    "Transmuting", "Twisting", "Undulating", "Unfurling", "Unraveling", "Vibing", "Waddling", "Wandering",
    "Warping", "Whatchamacalliting", "Whirlpooling", "Whirring", "Whisking", "Wibbling", "Working", "Wrangling",
    "Zesting", "Zigzagging",
]

enum Mode { case sleeping, idle, working, waiting, celebrating }

/// Reads the live spinner verb ("Smooshing…") off an iTerm2 session's screen.
enum ScreenReader {
    static let queue = DispatchQueue(label: "screen-reader")
    static let spinner = try! NSRegularExpression(pattern: #"(?m)^\s*[^\s>❯│]{1,2}\s+([A-Z][^\s…]{1,40})…(?:\s*\(|\s*$)"#)

    static func verb(itermSession id: String) -> String? {
        let src = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if unique ID of s is "\(id)" then return contents of s
              end repeat
            end repeat
          end repeat
        end tell
        """
        guard let text = NSAppleScript(source: src)?.executeAndReturnError(nil).stringValue else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = spinner.matches(in: text, range: range).last, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var sessions: [Session] = []
    var celebrated = Set<String>()
    var firstPoll = true
    var celebrateUntil = 0.0
    var tick = 0
    var lastRenderKey = ""
    var screenVerbs: [String: String] = [:]
    var readingScreen = false
    let defaults = UserDefaults.standard
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ note: Notification) {
        defaults.register(defaults: ["showActivity": false])
        item.button?.imagePosition = .imageLeft
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        poll()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in self.poll() }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in self.animate() }
    }

    // MARK: Polling session files

    func poll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Session] = []
        for url in files where url.pathExtension == "json" {
            guard var s = loadSession(url) else { continue }
            // Claude process gone without a SessionEnd (crash, closed terminal): forget it.
            if let pid = s.pid, kill(pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            // Esc-interrupts don't fire Stop, so peek at the transcript.
            if s.state == "working" || s.state == "waiting", let t = s.transcript,
               let last = tail(t, bytes: 4096)?.split(separator: "\n").last,
               last.contains("[Request interrupted by user") {
                s.state = "idle"
                s.updatedAt = now()
                saveSession(s)
            }
            loaded.append(s)
        }
        sessions = loaded.sorted { $0.updatedAt > $1.updatedAt }
        refreshScreenVerbs()

        // Celebrate each newly finished turn once (but not ones that finished before launch).
        for s in sessions where s.state == "done" {
            if let f = s.finishedAt, celebrated.insert("\(s.id)-\(f)").inserted, !firstPoll {
                celebrateUntil = now() + 4
            }
        }
        firstPoll = false
    }

    func refreshScreenVerbs() {
        let targets = sessions.filter { $0.state == "working" && $0.iterm != nil && $0.hostApp == "com.googlecode.iterm2" }
        screenVerbs = screenVerbs.filter { id, _ in targets.contains { $0.id == id } }
        guard !targets.isEmpty, !readingScreen else { return }
        readingScreen = true
        ScreenReader.queue.async {
            var found: [String: String] = [:]
            for t in targets { found[t.id] = ScreenReader.verb(itermSession: t.iterm!) }
            DispatchQueue.main.async {
                for (id, v) in found { self.screenVerbs[id] = v }
                self.readingScreen = false
            }
        }
    }

    // MARK: Animation

    var mode: Mode {
        if sessions.contains(where: { $0.state == "waiting" }) { return .waiting }
        if now() < celebrateUntil { return .celebrating }
        if sessions.contains(where: { $0.state == "working" }) { return .working }
        return sessions.isEmpty ? .sleeping : .idle
    }

    func animate() {
        tick += 1
        var pose = Pose()
        var cols = 15, x = 0, y = 1
        var title = NSAttributedString(string: "")
        var critters: [Critter]? = nil
        let blinking = tick % 47 < 2

        switch mode {
        case .sleeping:
            pose.eyes = .closed
        case .idle:
            pose.eyes = blinking ? .blink : .open
            let cycle = tick % 120
            pose.eyeDX = (80..<92).contains(cycle) ? -1 : (98..<110).contains(cycle) ? 1 : 0
        case .working:
            // One critter per working agent (up to 3), each scuttling in its own lane, out of step.
            let n = min(workingSessions.count, 3)
            let range = n == 1 ? 6 : 4
            let slot = 15 + range + (n == 1 ? 0 : 1)
            cols = n * slot - (n == 1 ? 0 : 1)
            critters = (0..<n).map { i in
                let step = (tick / 2 + i * 3) % (range * 2)
                var pose = Pose()
                pose.legPhase = (tick / 2 + i) % 2 + 1
                pose.eyes = (tick + i * 17) % 47 < 2 ? .blink : .open
                pose.eyeDX = step < range ? 1 : -1
                if n > 1, i == speaker { pose.rightArmUp = (tick / 3) % 2 == 0 }  // the one talking waves
                return Critter(x: i * slot + (step <= range ? step : range * 2 - step),
                               y: pose.legPhase == 1 ? 1 : 0, pose: pose)
            }
            title = workingTitle()
        case .waiting:
            cols = 17
            x = 1 + ((tick / 2) % 2 == 0 ? -1 : 1) * (tick % 20 < 6 ? 1 : 0)
            pose.leftArmUp = (tick / 3) % 2 == 0
            pose.rightArmUp = !pose.leftArmUp
            title = styled(" Needs you!", color: .systemRed, bold: true)
        case .celebrating:
            y = (tick / 3) % 2 == 0 ? 0 : 1
            pose.armsUp = true
            pose.eyes = .blink
            title = styled(" Done!", color: claudeOrange, bold: true)
        }

        let scene = critters ?? [Critter(x: x, y: y, pose: pose)]
        let key = "\(cols)|\(scene)|\(title.string)|\(mode)|\(mode == .working ? tick : 0)"
        guard key != lastRenderKey, let button = item.button else { return }
        lastRenderKey = key
        button.image = sceneImage(cols: cols, critters: scene)
        button.attributedTitle = title
    }

    /// Which working agent's word is showing; rotates every 3 seconds.
    var speaker: Int { (tick / 30) % max(1, workingSessions.count) }

    /// A random verb per agent that changes every 6 seconds (when the screen can't be read).
    func fallbackVerb(_ s: Session) -> String {
        var h = Hasher()
        h.combine(s.id)
        h.combine(tick / 60)
        return verbs[abs(h.finalize()) % verbs.count]
    }

    /// Working agents, oldest first, so the leader (and its word) stays put.
    var workingSessions: [Session] {
        sessions.filter { $0.state == "working" }.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
    }

    func workingTitle() -> NSAttributedString {
        let working = workingSessions
        guard !working.isEmpty else { return NSAttributedString(string: "") }
        let s = working[speaker % working.count]
        var text = "\(screenVerbs[s.id] ?? fallbackVerb(s))…"
        if defaults.bool(forKey: "showActivity"), let a = s.activity { text = truncate(a, 32)! }
        if working.count > 1 { text += " ×\(working.count)" }
        text = " " + text

        // Claude Code-style shimmer sweeping across the text.
        let dark = item.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = dark ? claudeOrange : NSColor(srgbRed: 0.72, green: 0.36, blue: 0.23, alpha: 1)
        let glow = dark ? NSColor(srgbRed: 1, green: 0.85, blue: 0.75, alpha: 1)
                        : NSColor(srgbRed: 0.95, green: 0.6, blue: 0.45, alpha: 1)
        let chars = Array(text)
        let span = chars.count + 8
        let head = Double(tick % span) - 4
        let out = NSMutableAttributedString()
        let font = NSFont.menuBarFont(ofSize: 0)
        for (i, ch) in chars.enumerated() {
            let t = max(0, 1 - abs(Double(i) - head) / 3)
            let color = base.blended(withFraction: t, of: glow) ?? base
            out.append(NSAttributedString(string: String(ch), attributes: [.foregroundColor: color, .font: font]))
        }
        return out
    }

    func styled(_ s: String, color: NSColor, bold: Bool = false) -> NSAttributedString {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        return NSAttributedString(string: s, attributes: [
            .foregroundColor: color,
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.menuBarFont(ofSize: 0),
        ])
    }

    func activate(_ bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let header = NSMenuItem(title: "Claude Buddy \(version)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if sessions.isEmpty {
            menu.addItem(disabled("No Claude sessions — napping 💤"))
        }
        for s in sessions {
            let (dot, label): (String, String)
            switch s.state {
            case "working": (dot, label) = ("🟠", "working" + (s.startedAt.map { " · \(duration(now() - $0))" } ?? ""))
            case "waiting": (dot, label) = ("🔴", "needs you")
            case "done": (dot, label) = ("🟢", "done" + (s.finishedAt.map { " · \(duration(now() - $0)) ago" } ?? ""))
            case "error": (dot, label) = ("⚠️", "error")
            default: (dot, label) = ("⚪️", "idle")
            }
            let detail = s.state == "working" ? s.activity ?? s.prompt : s.message ?? s.prompt
            let text = NSMutableAttributedString(string: "\(dot) \(s.project)  ", attributes: [.font: NSFont.menuFont(ofSize: 0)])
            text.append(NSAttributedString(string: label, attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            if let d = truncate(detail, 60) {
                text.append(NSAttributedString(string: "\n      \(d)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            let mi = NSMenuItem(title: s.project, action: #selector(openSession(_:)), keyEquivalent: "")
            mi.attributedTitle = text
            mi.representedObject = s.hostApp
            mi.target = self
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        menu.addItem(toggle("Show tool activity instead of verbs", key: "showActivity"))
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater
        menu.addItem(update)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Buddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    func toggle(_ title: String, key: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(flip(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = key
        mi.state = defaults.bool(forKey: key) ? .on : .off
        return mi
    }

    @objc func flip(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        lastRenderKey = ""
    }

    @objc func openSession(_ sender: NSMenuItem) { activate(sender.representedObject as? String) }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
    }
}

func duration(_ secs: Double) -> String {
    let s = Int(secs)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
}

// MARK: - Entry point

let args = CommandLine.arguments
if args.count > 1, args[1] == "hook" {
    runHook()
    exit(0)
}
if args.count > 2, args[1] == "icon" {
    renderIconset(to: args[2])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
