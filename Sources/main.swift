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
    var name: String?
    var entrypoint: String?

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

// MARK: - Claude Code's session registry (~/.claude/sessions/<pid>.json, one per running claude)

struct RegistryEntry: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String?
    let name: String?
    let nameSource: String?
    let entrypoint: String?
    let status: String?
    let statusUpdatedAt: Double?
    let updatedAt: Double?
}

func loadRegistry() -> [RegistryEntry] {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap {
        (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(RegistryEntry.self, from: $0) }
    }
}

func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno != ESRCH }

// MARK: - Hook mode (`ClaudeBuddy hook`, fed JSON on stdin by Claude Code)

func procInfo(_ pid: pid_t) -> (ppid: pid_t, name: String, tty: String?)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafePointer(to: info.kp_proc.p_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
    }
    var tty: String?
    let dev = info.kp_eproc.e_tdev
    if dev != -1, let n = devname(dev, mode_t(S_IFCHR)), String(cString: n) != "??" { tty = "/dev/" + String(cString: n) }
    return (info.kp_eproc.e_ppid, name, tty)
}

/// The Claude Code process that spawned this hook (skipping any wrapper shell).
func claudePID() -> Int32 {
    var pid = getppid()
    for _ in 0..<3 {
        guard let info = procInfo(pid), ["sh", "bash", "zsh", "dash"].contains(info.name) else { break }
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

enum Eyes { case open, blink, closed, happy, wide, wink, lookUp }

struct Pose: Equatable {
    var legPhase = 0  // 0 = standing, 1/2 = alternating steps, 3 = all feet tucked (mid-hop)
    var tucked = false  // sitting/crouching: body drops a row onto short legs
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

/// A little pixel-art effect (heart, sparkle, z, …) drawn next to the critters. `X` marks a lit pixel.
struct Glyph: Equatable {
    var art: [String]
    var col: Int
    var row: Int
    var color: NSColor
}

/// Draws several critters (plus any effects) onto one canvas.
func sceneImage(cols: Int, rows: Int = 11, critters: [Critter], glyphs: [Glyph] = [],
                pixel p: CGFloat = menuPixel) -> NSImage {
    let img = NSImage(size: NSSize(width: CGFloat(cols) * p, height: CGFloat(rows) * p), flipped: true) { _ in
        for critter in critters { drawCritter(critter, pixel: p) }
        for g in glyphs {
            g.color.setFill()
            for (r, line) in g.art.enumerated() {
                for (c, ch) in line.enumerated() where ch == "X" {
                    NSRect(x: CGFloat(g.col + c) * p, y: CGFloat(g.row + r) * p, width: p, height: p).fill()
                }
            }
        }
        return true
    }
    img.isTemplate = false
    return img
}

func drawCritter(_ critter: Critter, pixel p: CGFloat) {
    let pose = critter.pose
    let (x, y) = (critter.x, critter.y + (pose.tucked ? 1 : 0))
    func rect(_ c: Int, _ r: Int, _ w: Int, _ h: Int, _ color: NSColor = claudeOrange) {
        color.setFill()
        NSRect(x: CGFloat(x + c) * p, y: CGFloat(y + r) * p, width: CGFloat(w) * p, height: CGFloat(h) * p).fill()
    }
    rect(2, 0, 11, 8)  // body
    if pose.armsUp || pose.leftArmUp { rect(1, 4, 1, 1); rect(0, 2, 1, 2) } else { rect(0, 4, 2, 2) }
    if pose.armsUp || pose.rightArmUp { rect(13, 4, 1, 1); rect(14, 2, 1, 2) } else { rect(13, 4, 2, 2) }
    for (i, c) in [3, 5, 9, 11].enumerated() {
        let lifted = pose.tucked || pose.legPhase == 3
            || (pose.legPhase == 1 && i % 2 == 0) || (pose.legPhase == 2 && i % 2 == 1)
        rect(c, 8, 1, lifted ? 1 : 2)
    }
    let dx = pose.eyeDX
    switch pose.eyes {
    case .open: rect(4 + dx, 2, 1, 2, .black); rect(10 + dx, 2, 1, 2, .black)
    case .blink: rect(4 + dx, 3, 1, 1, .black); rect(10 + dx, 3, 1, 1, .black)
    case .closed: rect(3, 3, 2, 1, .black); rect(10, 3, 2, 1, .black)
    case .happy:  // ^ ^
        for c in [4, 10] { rect(c - 1 + dx, 3, 1, 1, .black); rect(c + dx, 2, 1, 1, .black); rect(c + 1 + dx, 3, 1, 1, .black) }
    case .wide: rect(4 + dx, 1, 1, 3, .black); rect(10 + dx, 1, 1, 3, .black)
    case .wink:
        rect(4 + dx, 2, 1, 2, .black)
        rect(9 + dx, 3, 1, 1, .black); rect(10 + dx, 2, 1, 1, .black); rect(11 + dx, 3, 1, 1, .black)
    case .lookUp: rect(4 + dx, 1, 1, 2, .black); rect(10 + dx, 1, 1, 2, .black)
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

/// Talks to terminal apps over AppleScript: reads the live spinner verb and brings a session's tab forward.
enum Terminals {
    static let queue = DispatchQueue(label: "terminals")
    static let iTerm = "com.googlecode.iterm2"
    static let terminal = "com.apple.Terminal"
    static let spinner = try! NSRegularExpression(pattern: #"(?m)^\s*[^\s>❯│]{1,2}\s+([A-Z][^\s…]{1,40})…(?:\s*\(|\s*$)"#)

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func run(_ source: String) -> String? {
        NSAppleScript(source: source)?.executeAndReturnError(nil).stringValue
    }

    /// The spinner word ("Smooshing") on the iTerm2 session attached to `tty`.
    static func verb(tty: String) -> String? {
        guard isRunning(iTerm), let text = run("""
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then return contents of s
                  end repeat
                end repeat
              end repeat
            end tell
            """) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = spinner.matches(in: text, range: range).last, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// Selects the iTerm2 or Terminal tab attached to `tty` and brings it to the front.
    static func focus(tty: String) -> Bool {
        if isRunning(iTerm), run("""
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      tell w to select
                      tell t to select
                      tell s to select
                      activate
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return "no"
            """) == "ok" { return true }
        if isRunning(terminal), run("""
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return "no"
            """) == "ok" { return true }
        return false
    }

    /// The GUI app a process lives under (VS Code, Ghostty, the Claude desktop app, …).
    static func hostApp(of pid: Int32) -> NSRunningApplication? {
        var p = pid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            guard let info = procInfo(p), info.ppid > 1 else { return nil }
            p = info.ppid
        }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var sessions: [Session] = []
    var celebrated = Set<String>()
    var firstPoll = true
    var celebrateUntil = 0.0
    var finished: (project: String, until: Double)?  // brief "✓ x done" while others keep working
    var tick = 0
    var lastRenderKey = ""
    let moves = Choreographer()
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
        DispatchQueue.main.async { self.setUpHooks() }
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

        // Hook data per claude process (after /clear a process gets a new session id; keep the latest).
        var hooked: [Int32: Session] = [:]
        var unkeyed: [Session] = []
        for s in loaded {
            guard let pid = s.pid else { unkeyed.append(s); continue }
            if hooked[pid].map({ $0.updatedAt < s.updatedAt }) ?? true { hooked[pid] = s }
        }

        // Every running claude registers itself, so sessions show up even without hooks.
        var merged: [Session] = []
        for entry in loadRegistry() where isAlive(entry.pid) {
            let regState = ["busy": "working", "idle": "idle"][entry.status ?? ""]
            let regTime = (entry.statusUpdatedAt ?? entry.updatedAt ?? 0) / 1000
            var s = hooked.removeValue(forKey: entry.pid)
                ?? Session(id: entry.sessionId, state: regState ?? "idle", updatedAt: regTime, cwd: entry.cwd,
                           startedAt: regState == "working" ? regTime : nil, pid: entry.pid)
            // If Claude Code's own status is newer than the last hook, trust it for busy/idle.
            if let regState, regTime > s.updatedAt + 1 {
                if regState == "working", s.state != "working", s.state != "waiting" {
                    s.state = "working"
                    s.startedAt = regTime
                    s.activity = nil
                } else if regState == "idle", s.state == "working" || s.state == "waiting" {
                    s.state = "idle"
                }
            }
            s.name = entry.nameSource == "derived" ? nil : entry.name
            s.entrypoint = entry.entrypoint
            merged.append(s)
        }
        merged += hooked.values
        merged += unkeyed
        sessions = merged.sorted { $0.updatedAt > $1.updatedAt }
        refreshScreenVerbs()

        // Celebrate each newly finished turn once (but not ones that finished before launch).
        for s in sessions where s.state == "done" {
            if let f = s.finishedAt, celebrated.insert("\(s.id)-\(f)").inserted, !firstPoll {
                celebrateUntil = now() + 4
                finished = (s.project, now() + 3)
            }
        }
        firstPoll = false
    }

    func refreshScreenVerbs() {
        let targets: [(id: String, tty: String)] = sessions.compactMap { s in
            guard s.state == "working", let pid = s.pid, let tty = procInfo(pid)?.tty else { return nil }
            return (s.id, tty)
        }
        screenVerbs = screenVerbs.filter { id, _ in targets.contains { $0.id == id } }
        guard !targets.isEmpty, !readingScreen, Terminals.isRunning(Terminals.iTerm) else { return }
        readingScreen = true
        Terminals.queue.async {
            var found: [String: String] = [:]
            for t in targets { found[t.id] = Terminals.verb(tty: t.tty) }
            DispatchQueue.main.async {
                for (id, v) in found { self.screenVerbs[id] = v }
                self.readingScreen = false
            }
        }
    }

    // MARK: Animation

    var mode: Mode {
        if sessions.contains(where: { $0.state == "waiting" }) { return .waiting }
        // Others still busy: keep them walking (the title calls out who finished) instead of a full celebration.
        if sessions.contains(where: { $0.state == "working" }) { return .working }
        if now() < celebrateUntil { return .celebrating }
        return sessions.isEmpty ? .sleeping : .idle
    }

    func animate() {
        tick += 1
        let frame: Frame
        var title = NSAttributedString(string: "")
        switch mode {
        case .sleeping:
            frame = moves.sleeping(tick)
        case .idle:
            frame = moves.idle(tick)
        case .working:
            frame = moves.working(tick, count: min(workingSessions.count, 3), speaker: speaker)
            if let f = finished, now() < f.until {
                title = styled(" ✓ \(f.project) done", color: .systemGreen, bold: true)
            } else {
                title = workingTitle()
            }
        case .waiting:
            frame = moves.waiting(tick)
            title = styled(" Needs you!", color: .systemRed, bold: true)
        case .celebrating:
            frame = moves.celebrating(tick)
            title = styled(" Done!", color: claudeOrange, bold: true)
        }

        let key = "\(frame)|\(title.string)|\(mode == .working ? tick : 0)"
        guard key != lastRenderKey, let button = item.button else { return }
        lastRenderKey = key
        button.image = sceneImage(cols: frame.cols, critters: frame.critters, glyphs: frame.glyphs)
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
            let detail = (s.state == "working" ? s.activity ?? s.prompt : s.message ?? s.prompt) ?? s.name
            let where_ = s.entrypoint == "claude-desktop" ? " · Claude app" : ""
            let text = NSMutableAttributedString(string: "\(dot) \(s.project)  ", attributes: [.font: NSFont.menuFont(ofSize: 0)])
            text.append(NSAttributedString(string: label + where_, attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            if let d = truncate(detail, 60) {
                text.append(NSAttributedString(string: "\n      \(d)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            let mi = NSMenuItem(title: s.project, action: #selector(openSession(_:)), keyEquivalent: "")
            mi.attributedTitle = text
            mi.representedObject = s.id
            mi.toolTip = "Open this session"
            mi.target = self
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        let hooks = NSMenuItem(title: "Connected to Claude Code", action: #selector(toggleHooks), keyEquivalent: "")
        hooks.target = self
        hooks.state = HookInstaller.status() == .missing ? .off : .on
        menu.addItem(hooks)
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

    @objc func openSession(_ sender: NSMenuItem) {
        guard let s = sessions.first(where: { $0.id == sender.representedObject as? String }) else { return }
        let tty = s.pid.flatMap { procInfo($0)?.tty }
        let app = s.pid.flatMap { Terminals.hostApp(of: $0) }
        Terminals.queue.async {
            // Exact tab in iTerm2/Terminal when we can find it; otherwise just bring the host app forward.
            if let tty, Terminals.focus(tty: tty) { return }
            DispatchQueue.main.async {
                if let app { app.activate() } else { self.activate(s.hostApp) }
            }
        }
    }

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
if args.count > 2, args[1] == "hooks" {  // ClaudeBuddy hooks install|uninstall|status
    switch args[2] {
    case "install": try? HookInstaller.install()
    case "uninstall": try? HookInstaller.uninstall()
    default: break
    }
    print(HookInstaller.status())
    exit(0)
}
if args.count > 2, args[1] == "preview" {
    renderPreview(to: args[2])
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
