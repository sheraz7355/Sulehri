// Sulehri — a friendly AI tutor that lives next to your cursor.
// Hold Control + Option, ask out loud, let go.
// Sulehri looks at your screen, explains slowly in simple English,
// draws on your screen live, and builds a diagram on the board.
// Runs on your Claude plan through the `claude` command (Claude Code).
// Voice: Kokoro, an open-source voice model running on your Mac.

import Cocoa
import AVFoundation
import Speech
import WebKit

// MARK: - Settings

let defaults = UserDefaults.standard
func setting<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }
var modelChoice: String { get { setting("model", "sonnet") } set { defaults.set(newValue, forKey: "model") } }
var voiceChoice: String { get { setting("voice", "af_heart") } set { defaults.set(newValue, forKey: "voice") } }
var speedChoice: Double { get { setting("speed", 0.85) } set { defaults.set(newValue, forKey: "speed") } }
var autoBoard: Bool { get { setting("autoBoard", true) } set { defaults.set(newValue, forKey: "autoBoard") } }
/// "wallpaper" = colors come from the desktop wallpaper. "topic" = a color theme per subject.
var colorMode: String { get { setting("colorMode", "wallpaper") } set { defaults.set(newValue, forKey: "colorMode") } }
var deepThink: Bool { get { setting("deepThink", false) } set { defaults.set(newValue, forKey: "deepThink") } }

let home = FileManager.default.homeDirectoryForCurrentUser.path
let supportDir = URL(fileURLWithPath: "\(home)/Library/Application Support/Sulehri", isDirectory: true)
let shotsDir: URL = {
    let u = supportDir.appendingPathComponent("shots", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()

func findClaude() -> String? {
    for c in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        where FileManager.default.isExecutableFile(atPath: c) { return c }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "command -v claude"]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return s.isEmpty ? nil : s
}

// MARK: - Palette

extension NSColor {
    convenience init(hex: UInt32, a: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
}
enum Palette {
    // Defaults from the user's palettes (Riviera Blue, Soft Ivory, Morning Sky, Olive Grove, Buttercream, Canyon).
    // In "match my wallpaper" mode these are replaced by colors read from the wallpaper.
    static var bg = NSColor(hex: 0x183451, a: 0.97)
    static var line = NSColor(hex: 0x2C4C70)
    static var text = NSColor(hex: 0xF3ECDE)
    static var muted = NSColor(hex: 0xB8C2CF)
    static var blue = NSColor(hex: 0x8DA6CC)       // idle
    static var green = NSColor(hex: 0xAAA648)      // listening
    static var yellow = NSColor(hex: 0xF7D89A)     // thinking
    static var purple = NSColor(hex: 0xDF6D41)     // speaking
    static var ink = NSColor(hex: 0xDF6D41)        // drawings on the screen
    static var note = NSColor(hex: 0xF7D89A)       // label pills and marker highlight
    static var noteText = NSColor(hex: 0x183451)
    static let laser = NSColor(hex: 0xFF4B3A)

    static func reset() {
        bg = NSColor(hex: 0x183451, a: 0.97); line = NSColor(hex: 0x2C4C70); text = NSColor(hex: 0xF3ECDE)
        muted = NSColor(hex: 0xB8C2CF); blue = NSColor(hex: 0x8DA6CC); green = NSColor(hex: 0xAAA648)
        yellow = NSColor(hex: 0xF7D89A); purple = NSColor(hex: 0xDF6D41); ink = NSColor(hex: 0xDF6D41)
        note = NSColor(hex: 0xF7D89A); noteText = NSColor(hex: 0x183451)
    }
    static func apply(_ t: WallTheme) {
        bg = t.bg.color.withAlphaComponent(0.97); line = t.line.color; text = t.text.color; muted = t.muted.color
        blue = t.idle.color; green = t.listening.color; yellow = t.thinking.color; purple = t.speaking.color
        ink = t.ink.color; note = t.note.color; noteText = t.noteText.color
    }
}

// MARK: - Timeline log (to find pauses): ~/Library/Application Support/Sulehri/timeline.log

var tlogStart = Date()
func tlog(_ msg: String, reset: Bool = false) {
    let url = supportDir.appendingPathComponent("timeline.log")
    if reset { tlogStart = Date(); try? "".write(to: url, atomically: true, encoding: .utf8) }
    let line = String(format: "%6.2f  %@\n", Date().timeIntervalSince(tlogStart), msg)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

// MARK: - History (saved lessons, all local)

let historyDir: URL = {
    let u = supportDir.appendingPathComponent("history", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()

enum History {
    static func file(_ id: String) -> URL { historyDir.appendingPathComponent("\(id).json") }
    static func load(_ id: String) -> [String: Any]? {
        guard let d = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    static func append(lesson id: String, session: String?, answer: [String: Any]) {
        var l = load(id) ?? ["id": id, "started": Date().timeIntervalSince1970, "answers": []]
        var answers = l["answers"] as? [[String: Any]] ?? []
        answers.append(answer)
        l["answers"] = answers
        l["updated"] = Date().timeIntervalSince1970
        if let s = session { l["session"] = s }
        if (l["title"] as? String ?? "").isEmpty { l["title"] = (answer["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? answer["question"] }
        if let d = try? JSONSerialization.data(withJSONObject: l) { try? d.write(to: file(id)) }
    }
    static func list() -> [[String: Any]] {
        let files = (try? FileManager.default.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { u -> [String: Any]? in
            guard let l = load(u.deletingPathExtension().lastPathComponent) else { return nil }
            let answers = l["answers"] as? [[String: Any]] ?? []
            return ["id": l["id"] ?? "", "title": l["title"] ?? "Lesson", "updated": l["updated"] ?? l["started"] ?? 0,
                    "count": answers.count, "theme": answers.last?["theme"] ?? "spring",
                    "questions": answers.compactMap { $0["question"] as? String }.joined(separator: " · ")]
        }.sorted { ($0["updated"] as? Double ?? 0) > ($1["updated"] as? Double ?? 0) }
    }
    static func delete(_ id: String) { try? FileManager.default.removeItem(at: file(id)) }
}

// MARK: - Rules (SULEHRI.md)

/// Sulehri's rules live in SULEHRI.md. Edit /Users/apple/sulehri/SULEHRI.md (or the copy inside the app) any time.
let rulesSourcePath = "\(home)/sulehri/SULEHRI.md"
func rulesPath() -> String {
    if FileManager.default.fileExists(atPath: rulesSourcePath) { return rulesSourcePath }
    return Bundle.main.path(forResource: "SULEHRI", ofType: "md") ?? rulesSourcePath
}
func loadRules() -> String { (try? String(contentsOfFile: rulesPath(), encoding: .utf8)) ?? "" }

// MARK: - Speech to text

final class Listener {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private(set) var transcript = ""
    var onPartial: ((String) -> Void)?
    private(set) var isRunning = false

    func start() throws {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw NSError(domain: "Sulehri", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn't available."])
        }
        transcript = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        request = req
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
        engine.prepare()
        try engine.start()
        isRunning = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let r = result else { return }
            let text = r.bestTranscription.formattedString
            DispatchQueue.main.async { self?.transcript = text; self?.onPartial?(text) }
        }
    }

    func stop(_ done: @escaping (String) -> Void) {
        guard isRunning else { done(transcript); return }
        isRunning = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.task?.cancel(); self.task = nil
            done(self.transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func cancel() { if isRunning { stop { _ in } } }
}

// MARK: - Voice (Kokoro, with Apple voice as backup)

final class Voice: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    let port = 51723
    private var server: Process?
    private(set) var ready = false
    private var player: AVAudioPlayer?
    private let backup = AVSpeechSynthesizer()
    private var onDone: (() -> Void)?
    var onReady: (() -> Void)?
    private var ackCache: [String: Data] = [:]
    // Said right after you stop talking. "Good question" only when you really asked a question.
    static let questionAcks = ["Good question. One second.", "Hmm, let me look.", "Ooh, okay. Let me see."]
    static let neutralAcks = ["Okay, let me see.", "Mm, okay.", "Alright, one moment.", "Hmm, okay."]
    static var ackPhrases: [String] { questionAcks + neutralAcks }

    override init() { super.init(); backup.delegate = self }

    private func markReady() { if !ready { ready = true; onReady?() } }

    /// Make the short "thinking" phrases ahead of time so they play instantly.
    func warmAcks() {
        let dir = supportDir.appendingPathComponent("phrases", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for p in Voice.ackPhrases {
            let key = "\(voiceChoice)|\(speedChoice)|\(p)"
            if ackCache[key] != nil { continue }
            let file = dir.appendingPathComponent("\(voiceChoice)-\(Int(speedChoice * 100))-\(p.filter { $0.isLetter }).wav")
            if let d = try? Data(contentsOf: file) { ackCache[key] = d; continue }   // made on an earlier launch
            synth(p, urgent: false) { d in
                if let d = d { self.ackCache[key] = d; try? d.write(to: file) }
            }
        }
    }

    func playAck(isQuestion: Bool, _ done: @escaping () -> Void) {
        let pool = isQuestion ? Voice.questionAcks : Voice.neutralAcks
        let ready = pool.compactMap { ackCache["\(voiceChoice)|\(speedChoice)|\($0)"] }
        guard let d = ready.randomElement() else { done(); warmAcks(); return }
        play(d, text: "", done: done)
    }

    func start() {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        req.timeoutInterval = 1
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            DispatchQueue.main.async {
                if (resp as? HTTPURLResponse)?.statusCode == 200 { self.markReady() } else { self.launch() }
            }
        }.resume()
    }

    private func launch() {
        let py = supportDir.appendingPathComponent("tts-env/bin/python").path
        let models = supportDir.appendingPathComponent("models").path
        guard let script = Bundle.main.path(forResource: "tts_server", ofType: "py"),
              FileManager.default.isExecutableFile(atPath: py) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [script, models, "\(port)"]
        p.qualityOfService = .userInteractive   // the voice must never be slowed down
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { h in
            if let s = String(data: h.availableData, encoding: .utf8), s.contains("READY") {
                DispatchQueue.main.async { self.markReady() }
                h.readabilityHandler = nil
            }
        }
        try? p.run()
        server = p
    }

    func shutdown() { server?.terminate() }

    /// Turn text into audio. Gives nil when the voice model isn't ready (then the backup voice is used).
    func synth(_ text: String, urgent: Bool = true, _ cb: @escaping (Data?) -> Void) {
        guard ready else { cb(nil); return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "voice": voiceChoice, "speed": speedChoice, "urgent": urgent])
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { cb(ok ? data : nil) }
        }.resume()
    }

    func play(_ audio: Data?, text: String, done: @escaping () -> Void) {
        stop()
        onDone = done
        if let a = audio, let p = try? AVAudioPlayer(data: a) {
            player = p; p.delegate = self; p.play()
        } else {
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice.speechVoices().first { $0.language == "en-US" && $0.quality == .premium }
                ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language == "en-US" && $0.quality == .enhanced }
                ?? AVSpeechSynthesisVoice(language: "en-US")
            u.rate = 0.42
            backup.speak(u)
        }
    }

    func stop() {
        onDone = nil
        player?.stop(); player = nil
        if backup.isSpeaking { backup.stopSpeaking(at: .immediate) }
    }

    private func finished() { let d = onDone; onDone = nil; d?() }
    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) { finished() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { finished() }
}

// MARK: - Screenshot

struct Shot {
    let path: String
    let width: Int, height: Int     // pixels
    let screenFrame: NSRect         // global points
    let cursorPx: (Int, Int)

    var scale: CGFloat { screenFrame.width / CGFloat(width) }   // points per pixel
    func toScreen(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: screenFrame.minX + x * scale, y: screenFrame.maxY - y * (screenFrame.height / CGFloat(height)))
    }
}

func runTool(_ exe: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
}

func takeScreenshot() -> Shot? {
    let mouse = NSEvent.mouseLocation
    var screen = NSScreen.main ?? NSScreen.screens[0]
    var index = 1
    for (i, s) in NSScreen.screens.enumerated() where NSMouseInRect(mouse, s.frame, false) { screen = s; index = i + 1 }
    if let files = try? FileManager.default.contentsOfDirectory(atPath: shotsDir.path) {
        for f in files { try? FileManager.default.removeItem(at: shotsDir.appendingPathComponent(f)) }
    }
    let path = shotsDir.appendingPathComponent("screen-\(Int(Date().timeIntervalSince1970)).jpg").path
    runTool("/usr/sbin/screencapture", ["-x", "-t", "jpg", "-D", "\(index)", path])
    runTool("/usr/bin/sips", ["-Z", "1568", path])
    guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data) else { return nil }
    let w = rep.pixelsWide, h = rep.pixelsHigh, f = screen.frame
    // Tell the `mac` helper how screenshot pixels map to screen points (top-left origin).
    let primaryH = NSScreen.screens[0].frame.height
    let state: [String: Any] = ["display": index, "x": f.minX, "y": primaryH - f.maxY, "w": f.width, "h": f.height, "iw": w, "ih": h]
    if let d = try? JSONSerialization.data(withJSONObject: state) {
        try? d.write(to: supportDir.appendingPathComponent("screen.json"))
    }
    return Shot(path: path, width: w, height: h, screenFrame: f,
                cursorPx: (Int((mouse.x - f.minX) / f.width * CGFloat(w)), Int((f.maxY - mouse.y) / f.height * CGFloat(h))))
}

/// Draws the user's laser trail onto a copy of the screenshot so Claude can see where they pointed.
func laserImage(_ shot: Shot, trail: [NSPoint]) -> (String, String)? {
    guard trail.count > 3, let img = NSImage(contentsOfFile: shot.path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = shot.width, h = shot.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let sx = CGFloat(w) / shot.screenFrame.width, sy = CGFloat(h) / shot.screenFrame.height
    let px = trail.map { CGPoint(x: ($0.x - shot.screenFrame.minX) * sx, y: ($0.y - shot.screenFrame.minY) * sy) }
    ctx.setStrokeColor(Palette.laser.withAlphaComponent(0.85).cgColor)
    ctx.setLineWidth(4); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.addLines(between: px); ctx.strokePath()
    guard let out = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: out)
    guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
    let path = shotsDir.appendingPathComponent("laser-\(Int(Date().timeIntervalSince1970)).jpg").path
    try? data.write(to: URL(fileURLWithPath: path))
    // A few points along the trail, in image pixels (top-left origin), for the text prompt.
    let n = min(10, px.count)
    let picks = (0..<n).map { px[$0 * (px.count - 1) / max(n - 1, 1)] }
    let desc = picks.map { "(\(Int($0.x)), \(h - Int($0.y)))" }.joined(separator: " → ")
    return (path, desc)
}

// MARK: - Reading Claude's answer as it streams in

struct Mark { var shape: String; var x, y, w, h: CGFloat; var label: String; var text: String = ""; var keep = false; var at = 1 }
/// sync: "after" = speak, then act (default). "with" = act while speaking.
/// (To act first and speak after, Claude simply acts before writing the step.)
struct Step { var say: String; var marks: [Mark]; var sync: String = "after"; var draw: String = "" }

enum ReplyEvent { case title(String), theme(String), step(Step), visual(String), useBoard, canvas(CGFloat, CGFloat, CGFloat) }

final class ReplyParser {
    private var sentSteps = 0, sentTitle = false, sentVisual = false, sentTheme = false
    private var sentBoard = false, sentCanvas = false
    private static let canvasRe = re(#"<canvas\b([^>]*?)/?>"#)
    private(set) var totalSteps = 0
    /// Claude can write text, use a tool, then write more. Each message is parsed on its own.
    func newMessage() { sentSteps = 0 }
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let titleRe = re(#"<title>([\s\S]*?)</title>"#)
    private static let stepRe = re(#"<step\b([^>]*)>([\s\S]*?)</step>"#)
    private static let sayRe = re(#"<say>([\s\S]*?)</say>"#)
    private static let markRe = re(#"<mark\b([^>]*?)/?>"#)
    private static let attrRe = re(#"(\w+)\s*=\s*"([^"]*)""#)
    private static let visualRe = re(#"<visual>([\s\S]*?)</visual>"#)
    private static let themeRe = re(#"<theme>\s*(\w+)\s*</theme>"#)
    private static let drawRe = re(#"<draw>([\s\S]*?)</draw>"#)

    private func groups(_ r: NSRegularExpression, _ s: String) -> [String] {
        let ns = s as NSString
        return r.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    func feed(_ text: String) -> [ReplyEvent] {
        var out: [ReplyEvent] = []
        if !sentTitle, let t = groups(Self.titleRe, text).first {
            sentTitle = true; out.append(.title(t.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if !sentTheme, let t = groups(Self.themeRe, text).first { sentTheme = true; out.append(.theme(t.lowercased())) }
        // <board/> = this lesson is too complex for the screen, use the board window.
        if !sentBoard, text.range(of: #"<board\s*/?>"#, options: .regularExpression) != nil { sentBoard = true; out.append(.useBoard) }
        // <canvas x= y= w=/> = where on the screen the sketch should go (screenshot pixels).
        if !sentCanvas, let attrs = groups(Self.canvasRe, text).first {
            sentCanvas = true
            var a: [String: CGFloat] = [:]
            let ns = attrs as NSString
            for m in Self.attrRe.matches(in: attrs, range: NSRange(location: 0, length: ns.length)) {
                a[ns.substring(with: m.range(at: 1)).lowercased()] = CGFloat(Double(ns.substring(with: m.range(at: 2))) ?? 0)
            }
            if let x = a["x"], let y = a["y"] { out.append(.canvas(x, y, a["w"] ?? 0)) }
        }
        let nsText = text as NSString
        let steps: [(attrs: String, body: String)] = Self.stepRe.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { (nsText.substring(with: $0.range(at: 1)), nsText.substring(with: $0.range(at: 2))) }
        while sentSteps < steps.count {
            let body = steps[sentSteps].body
            let sync = steps[sentSteps].attrs.lowercased().contains("with") ? "with" : "after"
            sentSteps += 1
            let say = clean(groups(Self.sayRe, body).joined(separator: " "))
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            var marks: [Mark] = []
            let bodyNoDraw = body.replacingOccurrences(of: #"<draw>[\s\S]*?</draw>"#, with: "", options: .regularExpression)
            for attrs in groups(Self.markRe, bodyNoDraw) {
                var a: [String: String] = [:]
                let ns = attrs as NSString
                for m in Self.attrRe.matches(in: attrs, range: NSRange(location: 0, length: ns.length)) {
                    a[ns.substring(with: m.range(at: 1)).lowercased()] = ns.substring(with: m.range(at: 2))
                }
                func n(_ k: String, _ d: CGFloat) -> CGFloat { CGFloat(Double(a[k] ?? "") ?? Double(d)) }
                if a["x"] != nil, a["y"] != nil {
                    marks.append(Mark(shape: a["shape"] ?? "circle", x: n("x", 0), y: n("y", 0),
                                      w: n("w", 80), h: n("h", 40), label: a["label"] ?? "", text: a["text"] ?? "",
                                      keep: (a["keep"] ?? "").lowercased() == "true", at: Int(a["at"] ?? "") ?? 1))
                }
            }
            if !say.isEmpty || !marks.isEmpty { totalSteps += 1; out.append(.step(Step(say: say, marks: marks, sync: sync,
                                                                                         draw: groups(Self.drawRe, body).joined(separator: "\n")))) }
        }
        if !sentVisual, var v = groups(Self.visualRe, text).first {
            sentVisual = true
            v = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.hasPrefix("```") { v = v.components(separatedBy: "\n").dropFirst().joined(separator: "\n") }
            if v.hasSuffix("```") { v = String(v.dropLast(3)) }
            out.append(.visual(v))
        }
        return out
    }

    /// When Claude didn't use the format at all, speak the plain text in small pieces.
    func fallback(_ text: String) -> [ReplyEvent] {
        guard totalSteps == 0 else { return [] }
        let plain = clean(text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
        guard !plain.isEmpty else { return [] }
        var sentences: [String] = []
        plain.enumerateSubstrings(in: plain.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty { sentences.append(s) }
        }
        var events: [ReplyEvent] = []
        stride(from: 0, to: sentences.count, by: 2).forEach { i in
            events.append(.step(Step(say: sentences[i..<min(i + 2, sentences.count)].joined(separator: " "), marks: [])))
        }
        sentSteps = events.count; totalSteps = events.count
        return events
    }

    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Keeps one Claude Code session warm, so each question starts answering right away.
/// The screenshot and quick web results are sent together with the question (no extra tool steps).
final class ClaudeBridge {
    let exe = findClaude()
    var sessionId: String?
    private var proc: Process?
    private var input: FileHandle?
    private var config = ""
    private var pending = Data()
    private var errText = Data()

    // The question being answered right now
    private var active = false
    private var parser = ReplyParser()
    private var text = ""
    private var onEvent: ((ReplyEvent) -> Void)?
    private var onStatus: ((String) -> Void)?
    private var onDone: ((String?) -> Void)?

    private func wantedConfig() -> String { "\(modelChoice)|\(deepThink)|\(loadRules().hashValue)" }

    /// Start (or restart) Claude in the background if it isn't ready.
    func warm() {
        guard !active else { return }
        if proc == nil || config != wantedConfig() { spawn() }
    }

    private func spawn() {
        stopProcess()
        guard let exe = exe else { return }
        config = wantedConfig()
        // Tools: read `mac see` screenshots, search the web, and run ONLY the `mac` helper.
        // No general shell access, so text on screen can't make Sulehri run other commands.
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--model", modelChoice, "--append-system-prompt", loadRules(),
                    "--effort", deepThink ? "high" : "low",   // low = starts talking in ~3 s; "Think deeper" for hard problems
                    "--allowedTools", "Read", "WebSearch", "WebFetch", "Bash(mac:*)",
                    "--add-dir", shotsDir.path, "--strict-mcp-config"]
        if let sid = sessionId { args += ["--resume", sid] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = shotsDir
        p.qualityOfService = .userInitiated
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if !deepThink { env["MAX_THINKING_TOKENS"] = "0" }   // answer right away; "Think deeper" turns this off
        env["ENABLE_TOOL_SEARCH"] = "false"                  // keep WebSearch ready without an extra lookup step
        p.environment = env
        let inPipe = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = inPipe; p.standardOutput = out; p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            DispatchQueue.main.async {
                guard let self = self, self.proc === p else { return }
                self.pending.append(chunk)
                while let nl = self.pending.firstIndex(of: 0x0A) {
                    let line = Data(self.pending[self.pending.startIndex..<nl])
                    self.pending.removeSubrange(self.pending.startIndex...nl)
                    self.handle(line)
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            DispatchQueue.main.async { if let self = self, self.errText.count < 4000 { self.errText.append(chunk) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.proc === p else { return }
                self.proc = nil; self.input = nil
                if self.active {
                    let msg = String(data: self.errText, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.finish(msg.isEmpty ? "Claude stopped unexpectedly. Please try again." : String(msg.prefix(300)))
                }
            }
        }
        pending = Data(); errText = Data()
        do { try p.run() } catch { return }
        proc = p
        input = inPipe.fileHandleForWriting
    }

    private func stopProcess() {
        if let p = proc {
            proc = nil; input = nil
            let pid = p.processIdentifier
            p.terminate()
            // Also stop any clicking/typing it started (child processes of this Claude session).
            let k = Process()
            k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            k.arguments = ["-TERM", "-P", "\(pid)"]
            try? k.run()
            let m = Process()
            m.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            m.arguments = ["-f", "cliclick|\\.local/bin/mac "]
            try? m.run()
        }
    }

    func shutdown() { active = false; stopProcess() }

    /// Stop the current answer. The session is restarted in the background for the next question.
    func cancel() {
        guard active else { return }
        active = false; onEvent = nil; onStatus = nil; onDone = nil
        stopProcess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.warm() }
    }

    /// Start a new conversation (nil) or continue a saved one.
    func switchSession(_ sid: String?) {
        cancel(); stopProcess()
        sessionId = sid
        warm()
    }

    func ask(_ question: String, shot: Shot?, laser: (String, String)?, web: String?,
             onEvent: @escaping (ReplyEvent) -> Void, onStatus: @escaping (String) -> Void,
             onDone: @escaping (String?) -> Void) {
        guard exe != nil else { onDone("I can't find Claude Code. Install it and run `claude` once to log in."); return }
        if proc == nil || config != wantedConfig() { spawn() }
        guard let input = input else { onDone("Couldn't start Claude. Please try again."); return }

        var content: [[String: Any]] = []
        var prompt = ""
        if let s = shot {
            let imagePath = laser?.0 ?? s.path
            if let data = FileManager.default.contents(atPath: imagePath) {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                            "data": data.base64EncodedString()]])
            }
            prompt += "Above is a screenshot of my screen right now (\(s.width)x\(s.height) pixels). It is already attached, no need to Read it. "
            prompt += "My mouse is at about (\(s.cursorPx.0), \(s.cursorPx.1)).\n"
            if let l = laser {
                prompt += "The red line on it is my laser pointer trail while I was talking. It went through: \(l.1). That is what I was pointing at.\n"
            }
        }
        if let w = web, !w.isEmpty {
            prompt += "\nFresh web results for my question (already searched for you; use them, and only search again if they are not enough):\n\(w)\n"
        }
        prompt += "\nI said: \"\(question)\""
        content.append(["type": "text", "text": prompt])

        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard var line = try? JSONSerialization.data(withJSONObject: msg) else { onDone("Couldn't send the question."); return }
        line.append(0x0A)

        active = true
        parser = ReplyParser(); text = ""; errText = Data()
        self.onEvent = onEvent; self.onStatus = onStatus; self.onDone = onDone
        do { try input.write(contentsOf: line) } catch { finish("Couldn't reach Claude. Please try again."); stopProcess() }
    }

    private func finish(_ err: String?) {
        guard active else { return }
        active = false
        let d = onDone
        onEvent = nil; onStatus = nil; onDone = nil
        d?(err)
    }

    private func handle(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let sid = obj["session_id"] as? String { sessionId = sid }
        guard active else { return }
        switch obj["type"] as? String {
        case "stream_event":
            guard let ev = obj["event"] as? [String: Any] else { return }
            let type = ev["type"] as? String
            if type == "message_start" { text = ""; parser.newMessage() }
            if type == "content_block_start", let b = ev["content_block"] as? [String: Any],
               let kind = b["type"] as? String, kind.hasSuffix("tool_use") {
                switch b["name"] as? String ?? "" {
                case "Read": onStatus?("Looking closer…")
                case "WebSearch", "web_search": onStatus?("Searching the internet…")
                case "WebFetch", "web_fetch": onStatus?("Reading a web page…")
                case "Bash": onStatus?("Working on your Mac…")
                default: onStatus?("Working…")
                }
            }
            if type == "content_block_delta", let d = ev["delta"] as? [String: Any],
               d["type"] as? String == "text_delta", let t = d["text"] as? String {
                text += t
                parser.feed(text).forEach { onEvent?($0) }
            }
        case "result":
            let final = obj["result"] as? String ?? ""
            if (obj["is_error"] as? Bool) == true { finish(final.isEmpty ? "Claude returned an error." : final); return }
            parser.feed(final).forEach { onEvent?($0) }
            parser.fallback(final).forEach { onEvent?($0) }
            finish(nil)
        default: break
        }
    }
}

/// Quick web results from the local server (Google + Wikipedia, about 1-2 seconds).
func quickSearch(_ q: String, _ cb: @escaping (String?) -> Void) {
    var c = URLComponents(string: "http://127.0.0.1:51723/search")!
    c.queryItems = [URLQueryItem(name: "q", value: q)]
    var req = URLRequest(url: c.url!)
    req.timeoutInterval = 3.5
    URLSession.shared.dataTask(with: req) { data, _, _ in
        var out: String?
        if let d = data, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let rs = obj["results"] as? [[String: Any]], !rs.isEmpty {
            out = rs.map { "- \($0["title"] as? String ?? "") (\($0["url"] as? String ?? "")): \($0["text"] as? String ?? "")" }
                .joined(separator: "\n")
        }
        DispatchQueue.main.async { cb(out) }
    }.resume()
}

/// Is this a real question (not an answer like "yes" or "q one", and not a command)?
func isQuestion(_ q: String) -> Bool {
    let s = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasSuffix("?") { return true }
    let starters = ["what", "why", "how", "when", "where", "which", "who", "can ", "could ", "is ", "are ", "does ",
                    "do ", "should ", "will ", "would ", "explain", "tell me", "teach me", "what's", "whats"]
    let words = s.split(separator: " ")
    return words.count >= 3 && starters.contains { s.hasPrefix($0) }
}

/// Mac actions and small talk don't need a web search.
func needsSearch(_ q: String) -> Bool {
    let s = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if s.split(separator: " ").count < 3 || !isQuestion(q) && s.split(separator: " ").count < 8 { return false }
    let actions = ["open ", "close ", "click ", "type ", "send ", "play ", "pause ", "go to ", "scroll ", "message ",
                   "call ", "launch ", "quit ", "message ", "reply ", "turn ", "set ", "find my ", "show me my "]
    if actions.contains(where: { s.hasPrefix($0) || s.hasPrefix("please " + $0) || s.hasPrefix("can you " + $0) }) { return false }
    let onScreen = ["this ", "this?", "that ", "here", "on my screen", "on the screen", "this line", "this code"]
    // Questions only about what's on screen ("what does this line do") still benefit from search less; keep it light.
    if onScreen.contains(where: { s.contains($0) }) && s.split(separator: " ").count < 6 { return false }
    return true
}

// MARK: - The little cursor buddy

enum Mode { case idle, listening, thinking, speaking }

func modeColor(_ m: Mode) -> NSColor {
    switch m {
    case .idle: return Palette.blue
    case .listening: return Palette.green
    case .thinking: return Palette.yellow
    case .speaking: return Palette.purple
    }
}

final class CursorView: NSView {
    var mode: Mode = .idle { didSet { needsDisplay = true } }
    var phase: CGFloat = 0
    override var isFlipped: Bool { true }
    static let tip = NSPoint(x: 14, y: 14)

    override func draw(_ dirty: NSRect) {
        let c = modeColor(mode)
        let t = CursorView.tip
        if mode == .listening {
            let r = 15 + 4 * sin(phase * 2.2)
            let ring = NSBezierPath(ovalIn: NSRect(x: t.x + 9 - r, y: t.y + 9 - r, width: r * 2, height: r * 2))
            c.withAlphaComponent(0.45).setStroke(); ring.lineWidth = 2; ring.stroke()
        }
        if mode == .thinking {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: t.x + 9, y: t.y + 9), radius: 16,
                          startAngle: phase * 120, endAngle: phase * 120 + 100)
            c.setStroke(); arc.lineWidth = 2.2; arc.lineCapStyle = .round; arc.stroke()
        }
        let tri = NSBezierPath()
        tri.move(to: t)
        tri.line(to: NSPoint(x: t.x + 19, y: t.y + 7))
        tri.line(to: NSPoint(x: t.x + 10, y: t.y + 10))
        tri.line(to: NSPoint(x: t.x + 7, y: t.y + 19))
        tri.close()
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = c; sh.shadowBlurRadius = 9; sh.set()
        c.setFill(); tri.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.95).setStroke(); tri.lineWidth = 1.2; tri.stroke()
    }
}

final class CursorWindow: NSPanel {
    let view = CursorView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
    init() {
        super.init(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        contentView = view
    }
    func place(tip p: NSPoint) {
        setFrameOrigin(NSPoint(x: round(p.x - CursorView.tip.x), y: round(p.y + CursorView.tip.y - frame.height)))
    }
}

// MARK: - Eraser (hold Control)

final class EraserView: NSView {
    static let radius: CGFloat = 17
    override func draw(_ dirty: NSRect) {
        let r = EraserView.radius
        let ring = NSBezierPath(ovalIn: NSRect(x: bounds.midX - r, y: bounds.midY - r, width: r * 2, height: r * 2))
        NSColor(white: 1, alpha: 0.22).setFill(); ring.fill()
        NSColor(white: 0, alpha: 0.55).setStroke(); ring.lineWidth = 3.5; ring.stroke()
        NSColor(white: 1, alpha: 0.95).setStroke(); ring.lineWidth = 1.6; ring.stroke()
    }
}

final class EraserWindow: NSPanel {
    init() {
        let size: CGFloat = 44
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        contentView = EraserView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    }
    func follow(_ p: NSPoint) {
        setFrameOrigin(NSPoint(x: round(p.x - frame.width / 2), y: round(p.y - frame.height / 2)))
        if !isVisible { orderFrontRegardless() }
    }
}

// MARK: - Top caption bar

final class TopBarView: NSView {
    var mode: Mode = .idle
    var text = ""
    var counter = ""
    var onClick: (() -> Void)?
    var phase: CGFloat = 0
    override var isFlipped: Bool { true }
    static let maxTextW: CGFloat = 640

    var attributed: NSAttributedString {
        let p = NSMutableParagraphStyle(); p.lineSpacing = 2
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: Palette.text, .paragraphStyle: p])
    }
    static let maxTextH: CGFloat = 210     // about 10 lines; after that the oldest words scroll away
    private func height(_ str: String) -> NSRect {
        let p = NSMutableParagraphStyle(); p.lineSpacing = 2
        return NSAttributedString(string: str, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .paragraphStyle: p])
            .boundingRect(with: NSSize(width: TopBarView.maxTextW, height: 5000), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
    /// Sizes the bar to fit the whole text. If it is very long, keeps the newest words visible.
    func fit() -> NSSize {
        var r = height(text)
        if r.height > TopBarView.maxTextH {
            let words = text.split(separator: " ")
            var lo = 1, hi = words.count - 1          // how many of the oldest words to drop
            while lo < hi {
                let mid = (lo + hi) / 2
                if height("… " + words[mid...].joined(separator: " ")).height <= TopBarView.maxTextH { hi = mid } else { lo = mid + 1 }
            }
            text = "… " + words[lo...].joined(separator: " ")
            r = height(text)
        }
        return NSSize(width: min(TopBarView.maxTextW, ceil(r.width)) + 150, height: max(40, ceil(r.height) + 20))
    }

    override func draw(_ dirty: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: min(20, box.height / 2), yRadius: min(20, box.height / 2))
        Palette.bg.setFill(); path.fill()
        Palette.line.setStroke(); path.lineWidth = 1; path.stroke()
        let c = modeColor(mode)
        let pulse = mode == .speaking || mode == .listening ? 0.6 + 0.4 * sin(phase * 3) : 1
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = c; sh.shadowBlurRadius = 6; sh.set()
        c.withAlphaComponent(pulse).setFill()
        NSBezierPath(ovalIn: NSRect(x: 18, y: bounds.midY - 5, width: 10, height: 10)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let textH = bounds.height - 20
        attributed.draw(with: NSRect(x: 40, y: 10, width: bounds.width - 150, height: textH),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        let hint = (mode == .thinking || mode == .speaking) ? (counter.isEmpty ? "■ stop" : counter + "  ■ stop") : counter
        if !hint.isEmpty {
            let a = NSAttributedString(string: hint, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: Palette.muted])
            a.draw(at: NSPoint(x: bounds.width - 18 - a.size().width, y: bounds.midY - a.size().height / 2))
        }
    }
    override func mouseDown(with e: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

final class TopBar: NSPanel {
    let view = TopBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
    private var hideToken = 0
    init() {
        super.init(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        contentView = view
        alphaValue = 0
    }
    func show(_ mode: Mode, _ text: String, counter: String = "") {
        hideToken += 1
        view.mode = mode; view.text = text; view.counter = counter
        let size = view.fit()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let wasVisible = alphaValue > 0.01
        let newFrame = NSRect(x: round(vf.midX - size.width / 2), y: vf.maxY - size.height - 8, width: size.width, height: size.height)
        setFrame(newFrame, display: true)   // no blocking animation: the text updates many times a second while you talk
        view.needsDisplay = true
        orderFrontRegardless()
        if !wasVisible { NSAnimationContext.runAnimationGroup { $0.duration = 0.25; animator().alphaValue = 1 } }
    }
    func hide(after secs: Double = 0) {
        hideToken += 1
        let t = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
            guard t == self.hideToken else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self.animator().alphaValue = 0 }
        }
    }
}

// MARK: - Live drawing on the real screen

final class InkWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        contentView = v
        setFrame(screen.frame, display: false)
    }
    var root: CALayer { contentView!.layer! }
}

/// One stroke being drawn: the buddy flies to its start, then traces it.
final class Stroke {
    let layer = CAShapeLayer()
    let points: [NSPoint]          // global coordinates
    let labelLayer: CALayer?
    var start: Date
    let duration: Double
    var apply: ((CGFloat) -> Void)?   // custom drawing (handwritten notes)
    var step = 0
    init(points: [NSPoint], label: CALayer?, start: Date, duration: Double) {
        self.points = points; labelLayer = label; self.start = start; self.duration = duration
    }
}

final class Ink {
    private var windows: [NSRect: InkWindow] = [:]
    private struct Tagged { let layer: CALayer; let step: Int; let keep: Bool }
    private var layers: [Tagged] = []
    // The step and keep flag for the mark being made right now.
    private var tagStep = 0, tagKeep = false
    private func add(_ l: CALayer) { layers.append(Tagged(layer: l, step: tagStep, keep: tagKeep)) }

    private func window(for p: NSPoint) -> InkWindow? {
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? NSScreen.main else { return nil }
        if let w = windows[s.frame] { return w }
        let w = InkWindow(screen: s); windows[s.frame] = w
        return w
    }

    /// Builds the path for a mark and adds its (still invisible) layer. Returns the stroke to animate.
    func make(_ m: Mark, shot: Shot, start: Date, step: Int) -> Stroke? {
        tagStep = step; tagKeep = m.keep
        let c = shot.toScreen(m.x, m.y)
        guard let win = window(for: c) else { return nil }
        win.orderFrontRegardless()
        let w = max(m.w * shot.scale, 16), h = max(m.h * shot.scale, 12)
        let kind = m.shape.lowercased()
        if kind == "note" || kind == "write" { return makeNote(m.text.isEmpty ? m.label : m.text, at: c, in: win, start: start) }
        var pts: [NSPoint] = []
        var labelAt = NSPoint(x: c.x, y: c.y + h / 2 + 22)
        switch m.shape.lowercased() {
        case "box", "rect", "rectangle":
            let r = NSRect(x: c.x - w / 2 - 8, y: c.y - h / 2 - 7, width: w + 16, height: h + 14)
            let corners = [NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.maxX, y: r.minY),
                           NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.minX, y: r.maxY + 4)]
            for i in 0..<(corners.count - 1) {
                for k in 0..<16 { let t = CGFloat(k) / 16
                    pts.append(NSPoint(x: corners[i].x + (corners[i + 1].x - corners[i].x) * t,
                                       y: corners[i].y + (corners[i + 1].y - corners[i].y) * t)) }
            }
            labelAt = NSPoint(x: c.x, y: r.maxY + 18)
        case "highlight", "marker":
            for k in 0...30 { let t = CGFloat(k) / 30
                pts.append(NSPoint(x: c.x - w / 2 - 4 + (w + 8) * t, y: c.y + 1.2 * sin(t * .pi * 2))) }
            labelAt = NSPoint(x: c.x, y: c.y + h / 2 + 18)
        case "underline", "line":
            let y = c.y - h / 2 - 5
            for k in 0...40 { let t = CGFloat(k) / 40
                pts.append(NSPoint(x: c.x - w / 2 - 4 + (w + 8) * t, y: y - 3 * sin(t * .pi))) }
            labelAt = NSPoint(x: c.x, y: y - 22)
        case "arrow":
            let screen = win.frame
            let dx: CGFloat = c.x - 150 < screen.minX ? 1 : -1
            let dy: CGFloat = c.y + 110 > screen.maxY ? -1 : 1
            let from = NSPoint(x: c.x + dx * 130, y: c.y + dy * 95)
            let gap = min(w, h) / 2 + 8
            let len = hypot(from.x - c.x, from.y - c.y)
            let to = NSPoint(x: c.x + (from.x - c.x) / len * gap, y: c.y + (from.y - c.y) / len * gap)
            let ctrl = NSPoint(x: (from.x + to.x) / 2 + dy * 25, y: (from.y + to.y) / 2 - dx * 25)
            for k in 0...40 { let t = CGFloat(k) / 40, u = 1 - t
                pts.append(NSPoint(x: u * u * from.x + 2 * u * t * ctrl.x + t * t * to.x,
                                   y: u * u * from.y + 2 * u * t * ctrl.y + t * t * to.y)) }
            let ang = atan2(to.y - ctrl.y, to.x - ctrl.x)
            for side in [CGFloat(0.5), -0.5] {
                let wing = NSPoint(x: to.x - 16 * cos(ang + side), y: to.y - 16 * sin(ang + side))
                for k in 1...6 { let t = CGFloat(k) / 6; pts.append(NSPoint(x: to.x + (wing.x - to.x) * t, y: to.y + (wing.y - to.y) * t)) }
                for k in 1...6 { let t = CGFloat(k) / 6; pts.append(NSPoint(x: wing.x + (to.x - wing.x) * t, y: wing.y + (to.y - wing.y) * t)) }
            }
            labelAt = NSPoint(x: from.x, y: from.y + dy * 20)
        default: // circle
            let rx = max(w / 2 + 14, 30), ry = max(h / 2 + 12, 22)
            for k in 0...90 {
                let t = CGFloat(k) / 90
                let a = .pi * 0.75 + t * .pi * 2.15
                let wob = 1 + 0.035 * sin(t * 9)
                pts.append(NSPoint(x: c.x + rx * wob * cos(a), y: c.y + ry * wob * sin(a)))
            }
            labelAt = NSPoint(x: c.x, y: c.y + ry + 18)
        }

        let origin = win.frame.origin
        let path = CGMutablePath()
        path.addLines(between: pts.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) })
        var label: CALayer?
        if !m.label.isEmpty { label = makeLabel(m.label, at: NSPoint(x: labelAt.x - origin.x, y: labelAt.y - origin.y), in: win) }
        let s = Stroke(points: pts, label: label, start: start, duration: min(1.4, max(0.6, Double(pts.count) / 70)))
        let L = s.layer
        L.path = path
        L.fillColor = nil
        L.strokeColor = Palette.ink.cgColor
        L.lineWidth = 4.5
        L.lineCap = .round; L.lineJoin = .round
        L.shadowColor = Palette.ink.cgColor; L.shadowRadius = 6; L.shadowOpacity = 0.7; L.shadowOffset = .zero
        L.strokeEnd = 0
        if kind == "highlight" || kind == "marker" {   // see-through marker pen over text
            L.strokeColor = Palette.note.withAlphaComponent(0.42).cgColor
            L.lineWidth = h + 6; L.lineCap = .butt; L.shadowOpacity = 0
        }
        win.root.addSublayer(L)
        add(L)
        return s
    }

    /// Handwritten note on the screen (like a tutor writing "i = 2" next to your code). Written left to right.
    private func makeNote(_ text: String, at c: NSPoint, in win: InkWindow, start: Date) -> Stroke? {
        guard !text.isEmpty else { return nil }
        let font = NSFont(name: "Noteworthy-Bold", size: 21) ?? NSFont.systemFont(ofSize: 19, weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let o = win.frame.origin
        var x = c.x - o.x
        x = min(x, win.frame.width - size.width - 30)
        let box = CGRect(x: x - 10, y: c.y - o.y - size.height / 2 - 4, width: size.width + 20, height: size.height + 8)
        let bg = CALayer()
        bg.frame = box
        bg.backgroundColor = NSColor(hex: 0xF3ECDE, a: 0.94).cgColor   // Soft Ivory
        bg.cornerRadius = 9
        bg.borderColor = Palette.ink.withAlphaComponent(0.6).cgColor; bg.borderWidth = 1
        bg.shadowColor = NSColor.black.cgColor; bg.shadowOpacity = 0.3; bg.shadowRadius = 6; bg.shadowOffset = .zero
        bg.opacity = 0
        let t = CATextLayer()
        t.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(hex: 0xA9501C)])  // Terracotta ink
        t.contentsScale = win.backingScaleFactor
        t.frame = CGRect(x: 10, y: 2, width: size.width + 2, height: size.height + 2)
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.frame = CGRect(x: 0, y: 0, width: 0, height: t.frame.height)
        t.mask = mask
        bg.addSublayer(t)
        win.root.addSublayer(bg)
        add(bg)
        let y = c.y - 2
        let pts = (0...30).map { NSPoint(x: o.x + x + size.width * CGFloat($0) / 30, y: y + 4 * sin(CGFloat($0) * 1.7)) }
        let s = Stroke(points: pts, label: nil, start: start, duration: min(2.0, max(0.6, Double(text.count) * 0.07)))
        s.apply = { e in
            bg.opacity = 1
            mask.frame = CGRect(x: 0, y: 0, width: (size.width + 2) * e, height: t.frame.height)
        }
        return s
    }

    private func makeLabel(_ text: String, at p: NSPoint, in win: InkWindow) -> CALayer {
        let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let bg = CALayer()
        let scale = win.backingScaleFactor
        bg.frame = CGRect(x: p.x - size.width / 2 - 11, y: p.y - size.height / 2 - 5, width: size.width + 22, height: size.height + 10)
        bg.backgroundColor = Palette.note.cgColor
        bg.borderColor = Palette.ink.cgColor; bg.borderWidth = 1.5
        bg.cornerRadius = bg.frame.height / 2
        bg.shadowColor = NSColor.black.cgColor; bg.shadowOpacity = 0.35; bg.shadowRadius = 6; bg.shadowOffset = .zero
        let t = CATextLayer()
        t.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: Palette.noteText])
        t.contentsScale = scale
        t.alignmentMode = .center
        t.frame = CGRect(x: 0, y: 4, width: bg.frame.width, height: size.height + 2)
        bg.addSublayer(t)
        bg.opacity = 0
        win.root.addSublayer(bg)
        add(bg)
        return bg
    }

    private var laserGlow: CAShapeLayer?
    private var laserCore: CAShapeLayer?
    private weak var laserWin: InkWindow?

    /// The laser pointer trail (like Excalidraw's laser): a glowing red line that fades behind the mouse.
    func laser(_ pts: [NSPoint], around mouse: NSPoint) {
        guard let win = window(for: mouse) else { return }
        if laserWin !== win {
            laserGlow?.removeFromSuperlayer(); laserCore?.removeFromSuperlayer()
            let g = CAShapeLayer(), c = CAShapeLayer()
            for l in [g, c] { l.fillColor = nil; l.lineCap = .round; l.lineJoin = .round; win.root.addSublayer(l) }
            g.strokeColor = Palette.laser.withAlphaComponent(0.55).cgColor; g.lineWidth = 9
            g.shadowColor = Palette.laser.cgColor; g.shadowRadius = 10; g.shadowOpacity = 1; g.shadowOffset = .zero
            c.strokeColor = NSColor(hex: 0xFFE4DC).cgColor; c.lineWidth = 2.6
            laserGlow = g; laserCore = c; laserWin = win
            win.orderFrontRegardless()
        }
        let o = win.frame.origin
        let path = CGMutablePath()
        if pts.count > 1 { path.addLines(between: pts.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) }) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        laserGlow?.path = path; laserCore?.path = path
        CATransaction.commit()
    }

    /// Fade out marks that are no longer needed, while new ones are drawn (keep="true" marks stay).
    var hasMarks: Bool { !layers.isEmpty }

    /// Eraser: remove every mark the point touches (within `radius`). Returns how many were erased.
    @discardableResult
    func erase(at p: NSPoint, radius: CGFloat) -> Int {
        var gone: [CALayer] = []
        for t in layers {
            guard let win = windows.values.first(where: { $0.root === t.layer.superlayer }) else { continue }
            let local = CGPoint(x: p.x - win.frame.minX, y: p.y - win.frame.minY)
            if let shape = t.layer as? CAShapeLayer, let path = shape.path {
                guard shape.strokeEnd > 0.02 else { continue }       // not drawn yet
                let fat = path.copy(strokingWithWidth: max(shape.lineWidth, radius * 2), lineCap: .round, lineJoin: .round, miterLimit: 1)
                if fat.contains(local) { gone.append(shape) }
            } else if t.layer.opacity > 0.05, t.layer.frame.insetBy(dx: -radius * 0.6, dy: -radius * 0.6).contains(local) {
                gone.append(t.layer)
            }
        }
        guard !gone.isEmpty else { return 0 }
        layers.removeAll { t in gone.contains { $0 === t.layer } }
        CATransaction.begin(); CATransaction.setAnimationDuration(0.18)
        gone.forEach { $0.opacity = 0 }
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { gone.forEach { $0.removeFromSuperlayer() } }
        return gone.count
    }

    func fadeOld(before step: Int, delay: Double = 0) {
        let old = layers.filter { !$0.keep && $0.step < step }
        guard !old.isEmpty else { return }
        layers.removeAll { t in old.contains { $0.layer === t.layer } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            CATransaction.begin(); CATransaction.setAnimationDuration(0.5)
            old.forEach { $0.layer.opacity = 0 }
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { old.forEach { $0.layer.removeFromSuperlayer() } }
        }
    }

    func clear(fade: Bool = true) {
        let old = layers.map { $0.layer }; layers = []
        if fade {
            CATransaction.begin(); CATransaction.setAnimationDuration(0.6)
            old.forEach { $0.opacity = 0 }
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { old.forEach { $0.removeFromSuperlayer() } }
        } else { old.forEach { $0.removeFromSuperlayer() } }
    }
}

// MARK: - The board (chat + live diagram)

final class Board: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let panel: NSPanel
    let web: WKWebView
    let overlay: Bool
    private var loaded = false
    private var queue: [String] = []
    private var hideToken = 0
    var onMessage: (([String: Any]) -> Void)?

    /// overlay = true makes a see-through, click-through layer that shows only the drawing, right on the screen.
    init(overlay: Bool = false) {
        self.overlay = overlay
        let rect = NSRect(x: 0, y: 0, width: 900, height: 580)
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: rect, configuration: cfg)
        panel = NSPanel(contentRect: rect,
                        styleMask: overlay ? [.borderless, .nonactivatingPanel]
                                           : [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        super.init()
        cfg.userContentController.add(self, name: "sulehri")
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        if overlay {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.contentView = web
        } else {
            panel.title = "Sulehri"
            panel.titlebarAppearsTransparent = true
            panel.appearance = NSAppearance(named: .aqua)
            panel.backgroundColor = NSColor(hex: 0xFBF6EC)
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.minSize = NSSize(width: 640, height: 420)
            let container = NSView(frame: rect)
            web.frame = NSRect(x: 0, y: 0, width: rect.width, height: rect.height - 28)
            container.addSubview(web)
            panel.contentView = container
        }
        if let url = Bundle.main.url(forResource: "board", withExtension: "html") {
            let page = overlay ? (URL(string: url.absoluteString + "#overlay") ?? url) : url
            web.loadFileURL(page, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    /// Show the sketch layer at a place on the screen (fades in).
    func showOverlay(in rect: NSRect) {
        hideToken += 1
        if panel.isVisible, panel.alphaValue > 0.05 {
            if panel.frame != rect { panel.setFrame(rect, display: true) }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
            return
        }
        panel.setFrame(rect, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; panel.animator().alphaValue = 1 }
    }
    func hideOverlay(after secs: Double = 0) {
        hideToken += 1
        let t = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
            guard t == self.hideToken, self.panel.isVisible else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.5; self.panel.animator().alphaValue = 0 }) {
                if t == self.hideToken { self.panel.orderOut(nil) }
            }
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any] else { return }
        if body["type"] as? String == "ready" {
            loaded = true
            queue.forEach { web.evaluateJavaScript($0) }
            queue = []
            return
        }
        onMessage?(body)
    }

    func call(_ fn: String, _ args: Any...) { callArgs(fn, args) }
    func callArgs(_ fn: String, _ args: [Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let js = "\(fn).apply(null, \(json))"
        if loaded { web.evaluateJavaScript(js) } else { queue.append(js) }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        guard !panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let w = min(900, vf.width * 0.62), h = min(580, vf.height * 0.72)
        // Open on the side away from the mouse so it doesn't cover what you're looking at.
        let x = mouse.x > vf.midX ? vf.minX + 20 : vf.maxX - w - 20
        panel.setFrame(NSRect(x: x, y: vf.minY + (vf.height - h) / 2, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }
    func toggle() { panel.isVisible ? panel.orderOut(nil) : show() }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var napBlocker: NSObjectProtocol?
    let cursor = CursorWindow()
    let eraser = EraserWindow()
    var eraseStart: Date?
    var eraseBlocked = false
    var erasing = false
    let topBar = TopBar()
    let ink = Ink()
    let board = Board()
    let canvas = Board(overlay: true)     // drawings right on the screen, no window
    var useBoard = false                  // true when the lesson is too complex for the screen
    var canvasHint: (CGFloat, CGFloat, CGFloat)?
    /// Send a drawing command to both the board (keeps the full lesson) and the on-screen sketch layer.
    func draw(_ fn: String, _ args: Any...) { board.callArgs(fn, args); canvas.callArgs(fn, args) }

    /// Where the on-screen sketch goes: where Claude asked, or the side away from the mouse.
    func canvasRect() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { s in shot.map { $0.screenFrame == s.frame } ?? false }
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        var vf = screen.visibleFrame
        vf.size.height -= 70                       // stay clear of the caption bar at the top
        var w = min(max(vf.width * 0.5, 480), 860)
        var center: NSPoint?
        if let h = canvasHint, let s = shot {
            center = s.toScreen(h.0, h.1)
            if h.2 > 0 { w = min(max(h.2 * s.scale, 400), vf.width * 0.7) }
        }
        let h = min(w * 560 / 960 + 44, vf.height - 16)
        var x = center.map { $0.x - w / 2 } ?? (mouse.x > vf.midX ? vf.minX + 24 : vf.maxX - w - 24)
        var y = center.map { $0.y - h / 2 } ?? (vf.midY - h / 2)
        x = max(vf.minX + 8, min(x, vf.maxX - w - 8))
        y = max(vf.minY + 8, min(y, vf.maxY - h - 8))
        return NSRect(x: round(x), y: round(y), width: round(w), height: round(h))
    }
    let listener = Listener()
    let voice = Voice()
    let claude = ClaudeBridge()

    // Cursor motion
    var pos = NSEvent.mouseLocation
    var pointTarget: NSPoint?
    var strokes: [Stroke] = []

    // Hotkey (hold Control + Option)
    var holdStart: Date?
    var holdBlocked = false

    // Laser pointer while you hold the keys
    var laserLive: [(NSPoint, Date)] = []
    var laserAll: [NSPoint] = []
    var listenShot: Shot?
    var listenGen = 0

    // History
    var lessonId = UUID().uuidString
    var record: [String: Any]?

    // A short "hmm, let me look" while thinking
    var ackPlaying = false
    var pendingPlay = false

    // Current answer
    var gen = 0
    var steps: [Step] = []
    var playIdx = 0
    var playing = false
    var streamDone = true
    var shot: Shot?
    /// A sentence inside a chunk of speech: its number in the step (1-based), and where it starts / how long it is (0...1).
    struct Cue { let k: Int; let start: Double; let part: Double }
    struct Utter { let step: Int; let text: String; let first: Bool; let cues: [Cue] }
    var utters: [Utter] = []
    var audio: [Int: Data?] = [:]
    var audioWaiters: [Int: (Data?) -> Void] = [:]
    var audioAsked: Set<Int> = []
    var busy = false

    func applicationDidFinishLaunching(_ n: Notification) {
        setupMenu()
        requestPermissions()
        signal(SIGPIPE, SIG_IGN)
        // Without this, macOS "App Nap" slows Sulehri and its voice down because it has no Dock icon.
        napBlocker = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                                                           reason: "Sulehri speaks and draws in real time")
        // Testing hook (off unless `defaults write com.umer.sulehri testHook -bool true`):
        // post "com.umer.sulehri.ask" with {"text": ...} to ask a question without speaking.
        if setting("testHook", false) { DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.umer.sulehri.ask"), object: nil, queue: .main) { [weak self] n in
            if let t = n.userInfo?["text"] as? String { self?.ask(t) }
        } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.claude.warm() }   // ready before the first question
        voice.onReady = { [weak self] in self?.voice.warmAcks() }
        voice.start()
        listener.onPartial = { [weak self] t in
            self?.topBar.show(.listening, t.isEmpty ? "Listening…" : t)
            self?.earlySearch(t)
        }
        topBar.view.onClick = { [weak self] in
            guard let self = self else { return }
            if self.busy || self.playing { self.interrupt() } else { self.board.toggle() }
        }
        board.onMessage = { [weak self] m in self?.boardMessage(m) }
        board.call("setChat", setting("chatOpen", false))
        refreshColors(force: true)
        cursor.orderFrontRegardless()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)

        if claude.exe == nil {
            topBar.show(.idle, "I can't find Claude Code. Install it and run claude once to log in.")
        } else if !CGPreflightScreenCaptureAccess() {
            // macOS only applies Screen Recording after the app restarts.
            topBar.show(.idle, "Please allow Screen Recording for Sulehri in System Settings, then choose ✨ → Restart Sulehri.")
            topBar.hide(after: 15)
        } else {
            topBar.show(.idle, "Hi, I'm Sulehri. Hold Control + Option and ask me anything.")
            topBar.hide(after: 6)
        }
    }

    func applicationWillTerminate(_ n: Notification) { saveRecord(); voice.shutdown(); claude.shutdown() }

    // MARK: Every frame

    /// While Sulehri still has words to say, the `mac` helper waits before clicking or typing,
    /// so you hear "I'll click Add" and then see it happen.
    let voiceState = supportDir.appendingPathComponent("voice.json")
    let actedFile = supportDir.appendingPathComponent("acted")
    var stepStarted = 0, stepFinished = 0     // 1-based step numbers
    var lastState = ""
    var frame = 0
    var lastActed: Date?
    var actedCheck = 0
    func updateSpeakingFlag() {
        // Tell the `mac` helper where the voice is, so it acts at the right moment:
        // "after" steps → act once the sentence is finished; "with" steps → act as soon as it starts.
        let mode = steps.last?.sync ?? "after"
        let st = "{\"busy\":\(busy),\"parsed\":\(steps.count),\"started\":\(stepStarted),\"finished\":\(stepFinished),\"mode\":\"\(mode)\"}"
        if st != lastState {
            lastState = st
            try? st.write(to: voiceState, atomically: true, encoding: .utf8)
        }
        // When Sulehri clicks or types, the screen changes: fade the old marks.
        actedCheck += 1
        if actedCheck % 6 == 0, let d = (try? FileManager.default.attributesOfItem(atPath: actedFile.path))?[.modificationDate] as? Date,
           d != lastActed {
            if lastActed != nil {
                strokes.removeAll { $0.step < stepStarted - 1 }
                ink.fadeOld(before: Int.max, delay: 0.7)
            }
            lastActed = d
        }
    }

    func tick() {
        let now = Date()
        checkHotkey(now)
        updateSpeakingFlag()

        // Live screen drawing: buddy flies to the stroke, then traces it.
        if let s = strokes.first {
            let fly = 0.45
            let t = now.timeIntervalSince(s.start)
            if t < fly {
                pointTarget = s.points.first
            } else {
                let k = min(1, (t - fly) / s.duration)
                let e = 1 - pow(1 - k, 2)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                if let a = s.apply { a(CGFloat(e)) } else { s.layer.strokeEnd = CGFloat(e) }
                CATransaction.commit()
                let p = s.points[min(s.points.count - 1, Int(Double(s.points.count - 1) * e))]
                pointTarget = p
                pos = p
                if k >= 1 {
                    if let l = s.labelLayer { CATransaction.begin(); CATransaction.setAnimationDuration(0.3); l.opacity = 1; CATransaction.commit() }
                    strokes.removeFirst()
                    if let next = strokes.first { next.start = now.addingTimeInterval(0.15) }
                }
            }
        }

        let mouse = NSEvent.mouseLocation
        if listener.isRunning {
            if laserLive.last.map({ hypot($0.0.x - mouse.x, $0.0.y - mouse.y) > 1 }) ?? true {
                laserLive.append((mouse, now)); laserAll.append(mouse)
            }
        }
        if !laserLive.isEmpty {
            laserLive.removeAll { now.timeIntervalSince($0.1) > 0.9 }
            ink.laser(laserLive.map { $0.0 }, around: mouse)
        }
        let goal = pointTarget ?? NSPoint(x: mouse.x + 12, y: mouse.y - 14)
        let k: CGFloat = pointTarget == nil ? 0.45 : 0.16
        pos.x += (goal.x - pos.x) * k
        pos.y += (goal.y - pos.y) * k
        cursor.place(tip: pos)
        cursor.view.phase += 0.05
        topBar.view.phase += 0.05
        frame += 1
        if cursor.view.mode != .idle, frame % 2 == 0 { cursor.view.needsDisplay = true }
        if topBar.alphaValue > 0, frame % 4 == 0, topBar.view.mode == .speaking || topBar.view.mode == .listening { topBar.view.needsDisplay = true }
    }

    // Hold Control + Option (and nothing else) to talk. No extra permissions needed.
    func checkHotkey(_ now: Date) {
        let f = CGEventSource.flagsState(.combinedSessionState)
        let held = f.contains(.maskControl) && f.contains(.maskAlternate) && !f.contains(.maskCommand) && !f.contains(.maskShift)
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        if held {
            if holdStart == nil {
                holdStart = now; holdBlocked = false
                if busy || playing || ackPlaying { interrupt() }
            }
            let heldFor = now.timeIntervalSince(holdStart!)
            // A key was pressed during the hold: it's some other shortcut, not for us.
            if sinceKey < heldFor - 0.05 {
                if listener.isRunning { listener.cancel(); topBar.hide(); cursor.view.mode = busy ? .speaking : .idle }
                holdBlocked = true
                return
            }
            if !holdBlocked && !listener.isRunning && heldFor > 0.2 { startListening() }
        } else if holdStart != nil {
            holdStart = nil
            if listener.isRunning { stopListening() }
        }

        // Hold Control alone = eraser. Move it over any drawing on the screen to rub it out.
        let ctrlOnly = f.contains(.maskControl) && !f.contains(.maskAlternate) && !f.contains(.maskCommand) && !f.contains(.maskShift)
        if ctrlOnly {
            if eraseStart == nil { eraseStart = now; eraseBlocked = false }
            let heldFor = now.timeIntervalSince(eraseStart!)
            if sinceKey < heldFor - 0.05 { eraseBlocked = true }          // Control+C and friends: not for us
            let somethingDrawn = ink.hasMarks || (canvas.panel.isVisible && canvas.panel.alphaValue > 0.3)
            erasing = !eraseBlocked && heldFor > 0.3 && somethingDrawn
        } else {
            eraseStart = nil; erasing = false
        }
        if erasing {
            let m = NSEvent.mouseLocation
            eraser.follow(m)
            ink.erase(at: m, radius: EraserView.radius)
            let cf = canvas.panel.frame
            if canvas.panel.isVisible, frame % 2 == 0, cf.insetBy(dx: -EraserView.radius, dy: -EraserView.radius).contains(m) {
                canvas.call("eraseAt", m.x - cf.minX, cf.maxY - m.y, EraserView.radius)
            }
        } else if eraser.isVisible {
            eraser.orderOut(nil)
        }
    }

    /// Stop everything right away: talking, thinking, and any clicking/typing on the Mac.
    func interrupt() {
        stopAnswer()
        strokes = []
        topBar.show(.idle, "Stopped. Keep holding to tell me what to do instead.")
        topBar.hide(after: 3)
        NSSound(named: "Pop")?.play()
    }

    // MARK: Listening

    func startListening() {
        stopAnswer()
        // Take the screenshot now, while you're looking at the thing you're asking about.
        listenGen += 1
        let lg = listenGen
        listenShot = nil
        laserAll = []; laserLive = []
        DispatchQueue.global().async {
            let shot = takeScreenshot()
            DispatchQueue.main.async { if lg == self.listenGen { self.listenShot = shot } }
        }
        do {
            try listener.start()
            cursor.view.mode = .listening
            topBar.show(.listening, "Listening…")
            NSSound(named: "Tink")?.play()
        } catch {
            holdBlocked = true
            topBar.show(.idle, "I can't hear you. Allow Microphone and Speech Recognition in System Settings → Privacy & Security.")
            topBar.hide(after: 8)
        }
    }

    func stopListening() {
        topBar.show(.listening, listener.transcript.isEmpty ? "…" : listener.transcript)
        listener.stop { [weak self] text in
            guard let self = self else { return }
            if text.isEmpty {
                self.cursor.view.mode = .idle
                self.topBar.show(.idle, "I didn't hear anything. Hold Control + Option while you talk.")
                self.topBar.hide(after: 3)
            } else { self.ask(text, shot: self.listenShot, trail: self.laserAll) }
        }
    }

    // MARK: Colors from the wallpaper

    var wallTheme: WallTheme?
    var wallStamp = ""
    /// Reads the wallpaper's colors (again, if the wallpaper changed) and applies them everywhere.
    func refreshColors(force: Bool = false) {
        draw("setThemeMode", colorMode)
        guard colorMode == "wallpaper" else {
            if wallTheme != nil || force { wallTheme = nil; wallStamp = ""; Palette.reset(); repaint() }
            return
        }
        guard let url = currentWallpaperURL() else { return }
        let mod = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let stamp = "\(url.path)|\(mod?.timeIntervalSince1970 ?? 0)"
        guard force || stamp != wallStamp else { return }
        wallStamp = stamp
        DispatchQueue.global(qos: .utility).async {
            guard let t = makeWallTheme(from: url) else { return }
            DispatchQueue.main.async {
                guard colorMode == "wallpaper", self.wallStamp == stamp else { return }
                self.wallTheme = t
                Palette.apply(t)
                tlog("colors from wallpaper \(url.lastPathComponent): accent \(t.vars["--acc"] ?? "?"), background \(t.vars["--bg"] ?? "?")")
                self.draw("applyWallTheme", ["vars": t.vars, "backdrop": t.backdrop, "dark": t.dark, "swatches": t.swatches])
                self.repaint()
            }
        }
    }
    func repaint() { cursor.view.needsDisplay = true; topBar.view.needsDisplay = true }

    // MARK: Early web search (starts while you are still talking)

    var early: (text: String, result: String?, done: Bool)?
    var earlyWaiter: ((String?) -> Void)?
    func earlySearch(_ partial: String) {
        guard partial.split(separator: " ").count >= 4, needsSearch(partial) else { return }
        if let e = early, !e.done { return }                     // one at a time
        if let e = early, partial.hasPrefix(e.text), e.result != nil { return }   // still the same question
        early = (partial, nil, false)
        tlog("early search: \(partial)")
        quickSearch(partial) { [weak self] r in
            guard let self = self, var e = self.early, e.text == partial else { return }
            e.result = r; e.done = true; self.early = e
            tlog("early search done (\(r == nil ? "no" : "has") results)")
            if let w = self.earlyWaiter { self.earlyWaiter = nil; w(r) }
        }
    }
    /// Use the early search if it was about the same question; otherwise search now.
    func searchFor(_ question: String, _ cb: @escaping (String?) -> Void) {
        if let e = early, question.lowercased().hasPrefix(e.text.lowercased().prefix(max(12, e.text.count * 2 / 3))) {
            early = nil
            if e.done, e.result != nil { cb(e.result); return }
            if !e.done {
                earlyWaiter = cb
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in   // don't wait forever
                    if let w = self?.earlyWaiter { self?.earlyWaiter = nil; w(nil) }
                }
                return
            }
        }
        early = nil
        quickSearch(question, cb)
    }

    // MARK: Asking

    func ask(_ question: String, shot given: Shot? = nil, trail: [NSPoint] = []) {
        refreshColors()   // follow the wallpaper if it changed
        stopAnswer()
        gen += 1
        let g = gen
        busy = true
        steps = []; utters = []; playIdx = 0; playing = false; streamDone = false
        synthCursor = 0; synthBusy = false
        stepStarted = 0; stepFinished = 0
        audio = [:]; audioWaiters = [:]; audioAsked = []
        cursor.view.mode = .thinking
        topBar.show(.thinking, "Looking at your screen…")
        board.call("addUser", question)
        draw("newAnswer")
        useBoard = false; canvasHint = nil
        tlog("ask: \(question)", reset: true)
        record = ["question": question, "title": "", "theme": "", "steps": [String](), "visual": "",
                  "time": Date().timeIntervalSince1970]
        // Say a short "hmm, let me look" right away, like a person would.
        ackPlaying = true; pendingPlay = false
        voice.playAck(isQuestion: isQuestion(question)) { [weak self] in
            guard let self = self, g == self.gen else { return }
            self.ackPlaying = false
            if self.pendingPlay { self.pendingPlay = false; self.playNext() }
        }

        // The screenshot and a quick web search run at the same time.
        var web: String?
        var searching = needsSearch(question)
        var shotReady = false
        var shot: Shot?
        var laser: (String, String)?
        if searching { topBar.show(.thinking, "Checking the internet…") }
        func go() {
            guard g == self.gen, shotReady, !searching else { return }
            self.shot = shot
            self.topBar.show(.thinking, "Thinking about how to explain this…")
            self.send(question, shot: shot, laser: laser, web: web, g: g)
        }
        if searching { searchFor(question) { r in tlog("search done (\(r == nil ? "no" : "has") results)"); web = r; searching = false; go() } }
        DispatchQueue.global().async {
            let s = given ?? takeScreenshot()
            let l = s.flatMap { laserImage($0, trail: trail) }
            DispatchQueue.main.async { tlog("screenshot ready"); shot = s; laser = l; shotReady = true; go() }
        }
    }

    func send(_ question: String, shot: Shot?, laser: (String, String)?, web: String?, g: Int) {
        tlog("sent to Claude")
        claude.ask(question, shot: shot, laser: laser, web: web, onEvent: { ev in
            guard g == self.gen else { return }
            self.handle(ev)
        }, onStatus: { st in
            guard g == self.gen else { return }
            tlog("tool: \(st)")
            if !self.playing { self.topBar.show(.thinking, st) }
            self.board.call("status", st)
        }, onDone: { err in
            guard g == self.gen else { return }
            tlog("Claude finished\(err.map { ": " + $0 } ?? "")")
            self.streamDone = true
            if let err = err {
                self.board.call("sysMsg", err)
                if self.steps.isEmpty { self.fail(err); return }
            }
            if !self.playing { self.playNext() }
        })
    }

    func handle(_ ev: ReplyEvent) {
        switch ev {
        case .title(let t): board.call("setTitle", t); record?["title"] = t
        case .theme(let t): draw("setTheme", t); record?["theme"] = t
        case .useBoard:
            useBoard = true
            canvas.hideOverlay()
        case .canvas(let x, let y, let w):
            canvasHint = (x, y, w)
            if canvas.panel.isVisible { canvas.showOverlay(in: canvasRect()) }
        case .visual(let html):
            tlog("visual arrived (\(html.count) chars)")
            useBoard = true
            canvas.hideOverlay()
            board.call("setVisual", html); record?["visual"] = html
            if autoBoard { board.show() }
        case .step(let s):
            tlog("step \(steps.count + 1) arrived (\(s.say.split(separator: " ").count) words, \(s.marks.count) marks)")
            steps.append(s)
            record?["steps"] = steps.map { $0.say }
            if !s.draw.isEmpty { record?["visual"] = boardSVG() }
            board.call("addStep", steps.count, s.say)
            utters += makeUtters(step: steps.count - 1, say: s.say)
            if !s.draw.isEmpty {
                draw("addDraw", steps.count, s.draw)
            }
            pumpSynth()   // keep making audio ahead, in order, so there are no gaps
            if !playing { playNext() }
        }
    }

    /// Splits a step into sentences (for timing the drawing) and groups them into chunks of speech.
    /// A whole step is spoken as one piece of audio, so there are no pauses between its sentences.
    /// Only the very first sentence of the lesson is on its own, so Sulehri starts talking quickly.
    func makeUtters(step: Int, say: String) -> [Utter] {
        var sentences: [String] = []
        say.enumerateSubstrings(in: say.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let t = sub?.trimmingCharacters(in: .whitespaces), !t.isEmpty { sentences.append(t) }
        }
        guard !sentences.isEmpty else { return [Utter(step: step, text: "", first: true, cues: [Cue(k: 1, start: 0, part: 1)])] }
        func words(_ t: String) -> Int { t.split(separator: " ").count }
        var groups: [[Int]] = [[]]
        var count = 0
        for (i, t) in sentences.enumerated() {
            let n = words(t)
            let quickStart = step == 0 && groups.count == 1 && count >= 4      // first words of the lesson: speak them right away
            if !groups[groups.count - 1].isEmpty, quickStart || count + n > 34 { groups.append([]); count = 0 }
            groups[groups.count - 1].append(i); count += n
        }
        return groups.enumerated().map { gi, idx in
            let texts = idx.map { sentences[$0] }
            let total = Double(max(1, texts.reduce(0) { $0 + $1.count }))
            var before = 0.0
            var cues: [Cue] = []
            for (j, t) in texts.enumerated() {
                cues.append(Cue(k: idx[j] + 1, start: before / total, part: Double(t.count) / total))
                before += Double(t.count)
            }
            return Utter(step: step, text: texts.joined(separator: " "), first: gi == 0, cues: cues)
        }
    }

    var synthCursor = 0
    var synthBusy = false
    /// Make audio for every sentence in order, one after another, as far ahead as possible.
    func pumpSynth() {
        guard !synthBusy, synthCursor < utters.count else { return }
        let i = synthCursor
        synthCursor += 1
        let g = gen
        let text = utters[i].text
        if text.isEmpty { deliver(i, nil); pumpSynth(); return }
        synthBusy = true
        tlog("  synth \(i) start")
        voice.synth(text) { data in
            guard g == self.gen else { return }
            tlog("  synth \(i) done")
            self.synthBusy = false
            self.deliver(i, data)
            self.pumpSynth()
        }
    }
    func deliver(_ i: Int, _ data: Data?) {
        audio[i] = .some(data)
        if let w = audioWaiters.removeValue(forKey: i) { w(data) }
    }
    func fetchAudio(_ i: Int) { pumpSynth() }

    func withAudio(_ i: Int, _ cb: @escaping (Data?) -> Void) {
        if let d = audio[i] { cb(d); return }
        audioWaiters[i] = cb
        fetchAudio(i)
    }

    func playNext() {
        if ackPlaying { pendingPlay = true; return }
        if playIdx < utters.count { playUtter(playIdx) }
        else if streamDone { finishAnswer() }
        else {
            tlog("WAITING for next step from Claude")
            playing = false
            cursor.view.mode = .thinking
            if steps.isEmpty { topBar.show(.thinking, "Thinking about how to explain this…") }
        }
    }

    func playUtter(_ i: Int) {
        playing = true
        let g = gen
        let u = utters[i]
        let s = steps[u.step]
        cursor.view.mode = .speaking
        if u.first {
            stepStarted = u.step + 1
            draw("speakStep", u.step + 1)
            topBar.show(.speaking, s.say, counter: "\(u.step + 1)/\(max(steps.count, u.step + 1))\(streamDone ? "" : "+")")
            if s.marks.isEmpty, strokes.isEmpty { pointTarget = nil }
        }
        withAudio(i) { data in
            guard g == self.gen else { return }
            // Drawings go right on the screen. The board window opens only for very complex lessons.
            if u.first, !s.draw.isEmpty {
                if self.useBoard { if autoBoard { self.board.show() } } else { self.canvas.showOverlay(in: self.canvasRect()) }
            }
            let secs = data.map { Double(max(0, $0.count - 44)) / 48000.0 } ?? Double(u.text.split(separator: " ").count) * 0.45
            // While each sentence is being said, draw what it talks about (on the screen or the board) and make its marks.
            for c in u.cues {
                let fire = {
                    self.draw("cue", u.step + 1, c.k, Int(secs * c.part * 1000))
                    let marks = s.marks.filter { $0.at == c.k || (c.k == 1 && $0.at < 1) }
                    guard !marks.isEmpty else { return }
                    self.strokes.removeAll { $0.step < u.step }
                    self.ink.fadeOld(before: u.step)
                    guard let shot = self.shot else { return }
                    var start = Date().addingTimeInterval(0.05)
                    for m in marks {
                        if let st = self.ink.make(m, shot: shot, start: start, step: u.step) {
                            st.step = u.step
                            self.strokes.append(st); start = start.addingTimeInterval(0.4 + st.duration + 0.1)
                        }
                    }
                }
                if c.start < 0.01 { fire() } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + secs * c.start) {
                        guard g == self.gen, self.playIdx == i else { return }
                        fire()
                    }
                }
            }
            let endOfStep = i + 1 >= self.utters.count || self.utters[i + 1].first
            let finish = {
                if endOfStep { self.stepFinished = u.step + 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + (endOfStep ? 0.3 : 0.08)) {
                    guard g == self.gen else { return }
                    self.playIdx += 1
                    self.playNext()
                }
            }
            tlog("play \(i) (step \(u.step + 1), \(u.cues.count) sentence(s), \(String(format: "%.1f", secs))s): \(u.text.prefix(40))")
            if u.text.isEmpty { finish() } else { self.voice.play(data, text: u.text, done: { tlog("play \(i) end"); finish() }) }
        }
    }

    /// The whole drawing so far, as one SVG (for history).
    func boardSVG() -> String {
        var out = "<svg viewBox=\"0 0 960 560\">"
        for (n, st) in steps.enumerated() where !st.draw.isEmpty { out += "<g data-step=\"\(n + 1)\">\(st.draw)</g>" }
        return out + "</svg>"
    }

    /// Save the answer to this lesson's history file.
    func saveRecord() {
        guard let r = record else { return }
        record = nil
        guard !((r["steps"] as? [String]) ?? []).isEmpty else { return }
        let id = lessonId, sid = claude.sessionId
        DispatchQueue.global().async { History.append(lesson: id, session: sid, answer: r) }
    }

    func finishAnswer() {
        saveRecord()
        let g = gen
        playing = false; busy = false
        cursor.view.mode = .idle
        board.call("finish")
        canvas.hideOverlay(after: 25)     // leave the sketch up for a while, then fade it away
        topBar.show(.idle, "Done. Hold Control + Option to ask me more.")
        topBar.hide(after: 4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard g == self.gen else { return }
            self.pointTarget = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard g == self.gen else { return }
            self.ink.clear()
        }
    }

    func fail(_ msg: String) {
        saveRecord()
        busy = false; playing = false
        cursor.view.mode = .idle
        topBar.show(.idle, "Sorry: \(msg)")
        topBar.hide(after: 8)
        board.call("finish")
    }

    /// Stop whatever Sulehri is doing right now.
    func stopAnswer() {
        saveRecord()
        gen += 1
        claude.cancel()
        voice.stop()
        strokes = []
        ink.clear(fade: true)
        pointTarget = nil
        if busy { board.call("finish") }
        canvas.hideOverlay()
        busy = false; playing = false
        ackPlaying = false; pendingPlay = false
        cursor.view.mode = .idle
    }

    func boardMessage(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "ask": if let q = m["text"] as? String { ask(q) }
        case "new": newLesson()
        case "history": board.call("showHistory", History.list())
        case "openLesson":
            guard let id = m["id"] as? String, let l = History.load(id) else { return }
            stopAnswer()
            lessonId = id
            claude.switchSession(l["session"] as? String)   // keep talking where you left off
            board.call("loadLesson", l)
        case "deleteLesson":
            if let id = m["id"] as? String {
                History.delete(id)
                if id == lessonId { lessonId = UUID().uuidString; claude.switchSession(nil) }
                board.call("showHistory", History.list())
            }
        case "chat": defaults.set(m["open"] as? Bool ?? false, forKey: "chatOpen")
        case "theme":
            let bg: [String: (UInt32, Bool)] = ["spring": (0xFBF6EC, false), "ivory": (0xF3ECDE, false),
                                                "riviera": (0x122A43, true), "night": (0x1C1E22, true)]
            if m["theme"] as? String == "wallpaper", let w = wallTheme {
                board.panel.backgroundColor = w.bg.color
                board.panel.appearance = NSAppearance(named: w.dark ? .darkAqua : .aqua)
            } else if let t = m["theme"] as? String, let v = bg[t] {
                board.panel.backgroundColor = NSColor(hex: v.0)
                board.panel.appearance = NSAppearance(named: v.1 ? .darkAqua : .aqua)
            }
        case "replay":
            guard !busy, let t = m["text"] as? String else { return }
            gen += 1
            let g = gen
            cursor.view.mode = .speaking
            topBar.show(.speaking, t)
            voice.synth(t) { data in
                guard g == self.gen else { return }
                self.voice.play(data, text: t) {
                    guard g == self.gen else { return }
                    self.cursor.view.mode = .idle; self.topBar.hide(after: 1)
                }
            }
        default: break
        }
    }

    // MARK: Menu

    func setupMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Sulehri")
        rebuildMenu()
    }

    func item(_ title: String, _ action: Selector?, key: String = "", on: Bool = false, value: Any? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self; it.state = on ? .on : .off; it.representedObject = value
        return it
    }

    func rebuildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "Hold ⌃ Control + ⌥ Option to talk", action: nil, keyEquivalent: "")
        m.addItem(withTitle: "Hold ⌃ Control to erase drawings", action: nil, keyEquivalent: "")
        m.addItem(item("Show board", #selector(showBoard), key: "b"))
        m.addItem(.separator())

        let voices = NSMenu()
        voices.addItem(withTitle: "Female", action: nil, keyEquivalent: "")
        for (name, id) in [("Heart — warm, natural (US)", "af_heart"), ("Bella — bright (US)", "af_bella"),
                           ("Nicole — soft, calm (US)", "af_nicole"), ("Emma — British", "bf_emma")] {
            voices.addItem(item("   " + name, #selector(pickVoice(_:)), on: voiceChoice == id, value: id))
        }
        voices.addItem(.separator())
        voices.addItem(withTitle: "Male", action: nil, keyEquivalent: "")
        for (name, id) in [("Michael — friendly (US)", "am_michael"), ("Fenrir — deep (US)", "am_fenrir"),
                           ("Puck — lively (US)", "am_puck"), ("George — British", "bm_george")] {
            voices.addItem(item("   " + name, #selector(pickVoice(_:)), on: voiceChoice == id, value: id))
        }
        let vi = NSMenuItem(title: "Voice", action: nil, keyEquivalent: ""); vi.submenu = voices; m.addItem(vi)

        let speeds = NSMenu()
        for (name, v) in [("Very slow", 0.75), ("Slow", 0.85), ("Relaxed", 0.95), ("Normal", 1.05), ("Fast", 1.2), ("Very fast", 1.4)] {
            speeds.addItem(item(name, #selector(pickSpeed(_:)), on: abs(speedChoice - v) < 0.01, value: v))
        }
        let si = NSMenuItem(title: "Speaking speed", action: nil, keyEquivalent: ""); si.submenu = speeds; m.addItem(si)

        let models = NSMenu()
        for (name, id) in [("Haiku — fastest", "haiku"), ("Sonnet — balanced", "sonnet"), ("Opus — best explanations", "opus")] {
            models.addItem(item(name, #selector(pickModel(_:)), on: modelChoice == id, value: id))
        }
        let mi = NSMenuItem(title: "Brain (Claude model)", action: nil, keyEquivalent: ""); mi.submenu = models; m.addItem(mi)

        m.addItem(item("Think deeper (slower, for hard problems)", #selector(toggleDeepThink), on: deepThink))
        let colors = NSMenu()
        colors.addItem(item("Match my wallpaper", #selector(pickColors(_:)), on: colorMode == "wallpaper", value: "wallpaper"))
        colors.addItem(item("Change with the topic", #selector(pickColors(_:)), on: colorMode == "topic", value: "topic"))
        let ci = NSMenuItem(title: "Colors", action: nil, keyEquivalent: ""); ci.submenu = colors; m.addItem(ci)
        m.addItem(item("Open board automatically", #selector(toggleAutoBoard), on: autoBoard))
        m.addItem(item("Edit Sulehri's rules (SULEHRI.md)…", #selector(editRules)))
        m.addItem(.separator())
        m.addItem(item("New lesson", #selector(newLesson), key: "n"))
        m.addItem(item("Stop talking", #selector(stopTapped), key: "."))
        m.addItem(.separator())
        m.addItem(item("Restart Sulehri", #selector(restart)))
        m.addItem(withTitle: "Quit Sulehri", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = m
    }

    @objc func showBoard() { board.show(); board.panel.makeKeyAndOrderFront(nil) }
    @objc func pickVoice(_ s: NSMenuItem) { voiceChoice = s.representedObject as! String; rebuildMenu(); preview(); voice.warmAcks() }
    @objc func pickSpeed(_ s: NSMenuItem) { speedChoice = s.representedObject as! Double; rebuildMenu(); preview(); voice.warmAcks() }
    @objc func pickModel(_ s: NSMenuItem) { modelChoice = s.representedObject as! String; rebuildMenu(); claude.warm() }
    @objc func toggleDeepThink() { deepThink.toggle(); rebuildMenu(); claude.warm() }
    @objc func toggleAutoBoard() { autoBoard.toggle(); rebuildMenu() }
    @objc func pickColors(_ s: NSMenuItem) { colorMode = s.representedObject as! String; rebuildMenu(); refreshColors(force: true) }
    @objc func restart() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundlePath)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
    @objc func editRules() { NSWorkspace.shared.open(URL(fileURLWithPath: rulesPath())) }
    @objc func stopTapped() { stopAnswer(); topBar.hide() }
    @objc func newLesson() {
        stopAnswer()
        claude.switchSession(nil)
        lessonId = UUID().uuidString
        board.call("newLesson")
        board.show()
        topBar.show(.idle, "New lesson. What do you want to learn?")
        topBar.hide(after: 3)
    }

    func preview() {
        guard !busy else { return }
        let t = "Hi, I am Sulehri. Let's learn this together, step by step."
        voice.synth(t) { data in self.voice.play(data, text: t) {} }
    }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        // Needed so Sulehri can click and type for you.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
