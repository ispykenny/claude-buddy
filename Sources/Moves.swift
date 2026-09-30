import AppKit

/// One rendered frame of the menu bar scene.
struct Frame: Equatable {
    var cols: Int
    var critters: [Critter]
    var glyphs: [Glyph] = []
}

enum Art {
    static let heart = ["XX.XX", "XXXXX", ".XXX.", "..X.."]
    static let sparkle = [".X.", "XXX", ".X."]
    static let note = ["..X.", "..XX", "..X.", "XXX.", "XX.."]
    static let z = ["XXXX", "..X.", ".X..", "XXXX"]
    static let bang = ["X", "X", "X", ".", "X"]
}

/// Moves the critter does now and then while everyone is idle.
enum IdleMove: CaseIterable {
    case wave, hop, heart, dance, stretch, wink, sit, lookAround, shuffle

    var length: Int {  // in ticks (0.1s)
        switch self {
        case .wave: 24
        case .hop: 16
        case .heart: 30
        case .dance: 40
        case .stretch: 26
        case .wink: 12
        case .sit: 50
        case .lookAround: 30
        case .shuffle: 24
        }
    }
}

/// Little tricks a working critter throws in while it scuttles.
enum Trick: CaseIterable {
    case hop, pause, dash, lookBack

    var length: Int {
        switch self {
        case .hop: 6
        case .pause: 16
        case .dash: 20
        case .lookBack: 12
        }
    }
}

struct Walker {
    var x = 0
    var dir = 1
    var trick: Trick?
    var trickLeft = 0
    var nextTrickAt = Int.random(in: 30...90)
}

/// Decides what the critters are doing on each animation tick.
final class Choreographer {
    private var idleMove: IdleMove?
    private var idleStart = 0
    private var nextIdleAt = 40
    private var walkers: [Walker] = []

    /// Starts a specific idle move now (used by the preview sheet).
    func start(_ move: IdleMove, at tick: Int) {
        idleMove = move
        idleStart = tick
    }

    private func blinking(_ tick: Int, _ seed: Int = 0) -> Bool { (tick + seed * 17) % 47 < 2 }

    // MARK: Idle: blinks, plus a random move every few seconds

    func idle(_ tick: Int) -> Frame {
        var pose = Pose()
        var x = 0, y = 1
        var glyphs: [Glyph] = []
        pose.eyes = blinking(tick) ? .blink : .open

        if idleMove == nil, tick >= nextIdleAt {
            idleMove = IdleMove.allCases.randomElement()
            idleStart = tick
        }
        if let move = idleMove {
            let t = tick - idleStart
            if t >= move.length {
                idleMove = nil
                nextIdleAt = tick + Int.random(in: 40...90)
            } else {
                switch move {
                case .wave:
                    pose.rightArmUp = (t / 3) % 2 == 0
                    pose.eyes = .happy
                case .hop:  // crouch, spring, crouch, spring
                    if t % 8 < 2 { pose.tucked = true } else if t % 8 < 6 { y = 0; pose.legPhase = 3; pose.eyes = .happy }
                case .heart:
                    pose.eyes = .happy
                    if t < 26 { glyphs.append(Glyph(art: Art.heart, col: 15, row: max(0, 3 - t / 5), color: .systemPink)) }
                case .dance:
                    let beat = (t / 5) % 2
                    x = beat
                    pose.leftArmUp = beat == 0
                    pose.rightArmUp = beat == 1
                    pose.legPhase = beat + 1
                    pose.eyes = .happy
                    glyphs.append(Glyph(art: Art.note, col: 15, row: beat, color: claudeOrange))
                case .stretch:
                    if t < 16 { pose.armsUp = true; pose.eyes = .closed; y = 0 } else { pose.eyes = .happy }
                case .wink:
                    pose.eyes = .wink
                    if (3..<9).contains(t) { glyphs.append(Glyph(art: Art.sparkle, col: 16, row: 0, color: .systemYellow)) }
                case .sit:
                    pose.tucked = true
                    if t % 20 < 3 { pose.eyes = .blink }
                case .lookAround:
                    pose.eyeDX = t < 10 ? -1 : (14..<24).contains(t) ? 1 : 0
                    if (10..<14).contains(t) { pose.eyes = .lookUp }
                case .shuffle:  // side-step out and back
                    x = t < 12 ? t / 3 : (24 - t) / 3
                    pose.legPhase = (t / 2) % 2 + 1
                    pose.eyeDX = t < 12 ? 1 : -1
                }
            }
        }
        return Frame(cols: 20, critters: [Critter(x: x, y: y, pose: pose)], glyphs: glyphs)
    }

    // MARK: No sessions: napping with Zs

    func sleeping(_ tick: Int) -> Frame {
        var pose = Pose()
        pose.tucked = true
        pose.eyes = .closed
        let t = tick % 40
        let glyphs = t < 30 ? [Glyph(art: Art.z, col: 15, row: max(0, 6 - t / 5), color: .secondaryLabelColor)] : []
        return Frame(cols: 20, critters: [Critter(x: 0, y: 1, pose: pose)], glyphs: glyphs)
    }

    // MARK: Working: one scuttling critter per agent, each doing its own tricks

    func working(_ tick: Int, count n: Int, speaker: Int) -> Frame {
        let range = n == 1 ? 6 : 4
        let slot = 15 + range + (n == 1 ? 0 : 1)
        if walkers.count != n {
            walkers = (0..<n).map { i in
                var w = Walker()
                w.x = (i * 3) % (range + 1)
                w.dir = i % 2 == 0 ? 1 : -1
                return w
            }
        }

        var critters: [Critter] = []
        for i in 0..<n {
            var w = walkers[i]
            if w.trick == nil, tick >= w.nextTrickAt {
                w.trick = Trick.allCases.randomElement()
                w.trickLeft = w.trick!.length
            }

            let moving = w.trick != .pause
            let every = w.trick == .dash ? 1 : 2
            if moving, tick % every == 0 {
                w.x += w.dir
                if w.x >= range || w.x <= 0 { w.dir = -w.dir }
                w.x = min(max(w.x, 0), range)
            }

            var pose = Pose()
            pose.legPhase = moving ? (tick / every) % 2 + 1 : 0
            pose.eyeDX = w.dir
            pose.eyes = blinking(tick, i) ? .blink : .open
            var y = pose.legPhase == 1 || pose.legPhase == 0 ? 1 : 0

            switch w.trick {
            case .hop:
                y = 0
                pose.legPhase = 3
                pose.eyes = .happy
            case .pause:  // stop and look at you
                pose.eyeDX = 0
                if w.trickLeft == 8 || w.trickLeft == 7 { pose.eyes = .blink }
            case .dash:  // arms pumping, double speed
                pose.leftArmUp = pose.legPhase == 1
                pose.rightArmUp = pose.legPhase == 2
            case .lookBack:
                pose.eyeDX = -w.dir
            case nil:
                break
            }
            if n > 1, i == speaker, w.trick != .dash { pose.rightArmUp = (tick / 3) % 2 == 0 }  // the one talking waves

            if w.trick != nil {
                w.trickLeft -= 1
                if w.trickLeft <= 0 {
                    w.trick = nil
                    w.nextTrickAt = tick + Int.random(in: 40...120)
                }
            }
            walkers[i] = w
            critters.append(Critter(x: i * slot + w.x, y: y, pose: pose))
        }
        return Frame(cols: n * slot - (n == 1 ? 0 : 1), critters: critters)
    }

    // MARK: Needs permission: jittery waving with a blinking "!"

    func waiting(_ tick: Int) -> Frame {
        var pose = Pose()
        pose.leftArmUp = (tick / 3) % 2 == 0
        pose.rightArmUp = !pose.leftArmUp
        pose.eyes = .wide
        let x = 1 + (tick % 20 < 6 ? ((tick / 2) % 2 == 0 ? -1 : 1) : 0)
        let glyphs = (tick / 4) % 2 == 0 ? [Glyph(art: Art.bang, col: 17, row: 1, color: .systemRed)] : []
        return Frame(cols: 19, critters: [Critter(x: x, y: 1, pose: pose)], glyphs: glyphs)
    }

    // MARK: Just finished: jumping for joy between sparkles

    func celebrating(_ tick: Int) -> Frame {
        var pose = Pose()
        pose.armsUp = true
        pose.eyes = .happy
        var y = 1
        if tick % 6 < 2 { pose.tucked = true } else { y = 0; pose.legPhase = 3 }
        let flip = (tick / 3) % 2 == 0
        let glyphs = [
            Glyph(art: Art.sparkle, col: 0, row: flip ? 1 : 6, color: .systemYellow),
            Glyph(art: Art.sparkle, col: 18, row: flip ? 6 : 1, color: .systemYellow),
        ]
        return Frame(cols: 21, critters: [Critter(x: 3, y: y, pose: pose)], glyphs: glyphs)
    }
}

/// `ClaudeBuddy preview <out.png>` renders a contact sheet of every move, for eyeballing animations.
func renderPreview(to path: String) {
    var rows: [(String, [Frame])] = []
    for move in IdleMove.allCases {
        let c = Choreographer()
        c.start(move, at: 100)
        rows.append(("\(move)", stride(from: 100, to: 100 + move.length, by: max(1, move.length / 8)).map { c.idle($0) }))
    }
    let c = Choreographer()
    rows.append(("sleeping", stride(from: 0, to: 40, by: 5).map { c.sleeping($0) }))
    rows.append(("working×3", stride(from: 0, to: 400, by: 50).map { c.working($0, count: 3, speaker: 1) }))
    rows.append(("waiting", (0..<8).map { c.waiting($0 * 2) }))
    rows.append(("celebrating", (0..<8).map { c.celebrating($0) }))

    let p: CGFloat = 6, cellW = CGFloat(rows.flatMap { $0.1 }.map(\.cols).max()! + 3) * p, cellH: CGFloat = 13 * p, labelW: CGFloat = 110
    let size = NSSize(width: labelW + cellW * 8, height: cellH * CGFloat(rows.count))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(srgbRed: 0.35, green: 0.62, blue: 0.85, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    for (r, (label, frames)) in rows.enumerated() {
        let top = size.height - cellH * CGFloat(r + 1)
        (label as NSString).draw(at: NSPoint(x: 6, y: top + 12), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white])
        for (i, f) in frames.enumerated() {
            let img = sceneImage(cols: f.cols, critters: f.critters, glyphs: f.glyphs, pixel: p)
            img.draw(at: NSPoint(x: labelW + cellW * CGFloat(i), y: top + p), from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
