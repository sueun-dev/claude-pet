import Foundation

// Everything lives in ~/.claude-pet so the hook process (short-lived CLI) and the
// menu bar app (long-lived GUI) talk through plain files — no sockets, no daemon.
// CLAUDE_PET_HOME overrides the location (used by the tests).
enum Paths {
    static let root = ProcessInfo.processInfo.environment["CLAUDE_PET_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-pet")
    static let sessions = root.appendingPathComponent("sessions")
    static let config = root.appendingPathComponent("config.json")
    static let prompts = root.appendingPathComponent("prompts")
    static let lock = root.appendingPathComponent("app.lock")

    static func session(_ id: String) -> URL {
        let safe = id.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return sessions.appendingPathComponent(safe + ".json")
    }

    /// Where the hook waiting on a permission prompt listens for the menu bar's answer.
    static func promptSocket(_ promptID: String) -> URL { prompts.appendingPathComponent(promptID + ".sock") }

    /// Owner-only: sessions hold commands and messages. (main.swift also sets umask 077.)
    static func ensure() {
        for d in [root, sessions, prompts] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

/// Session states shown in the menu bar; idle sessions are hidden.
enum SessionState: String, Codable {
    case idle, running, needsInput, ready, blocked

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .needsInput: return "Needs input"
        case .ready: return "Ready"
        case .blocked: return "Blocked"
        }
    }

    /// Lower sorts first: the thing that needs you most.
    var priority: Int {
        switch self {
        case .needsInput: return 0
        case .blocked: return 1
        case .ready: return 2
        case .running: return 3
        case .idle: return 4
        }
    }
}

/// A permission dialog Claude is showing right now.
struct PermissionPrompt: Codable, Equatable {
    var id: String
    var tool: String
    var detail: String        // the command, file or URL being asked about
    var inputKey: String      // fingerprint of the tool input, to spot this call's PostToolUse
    var canAlwaysAllow: Bool  // Claude offered "don't ask again" rules
    var answerable: Bool      // a hook is listening for the menu bar's answer
    var created: Double

    var question: String { "Allow \(tool)?" }

    /// The panel only offers to answer when it can show the whole request plainly: short,
    /// a few lines, and free of control or invisible formatting characters and of long
    /// whitespace runs that could push part of a command out of view.
    static func isReviewable(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 400,
              text.split(separator: "\n", omittingEmptySubsequences: false).count <= 6,
              text.range(of: "[ \t]{4,}", options: .regularExpression) == nil else { return false }
        return !text.unicodeScalars.contains {
            ($0.properties.generalCategory == .control && $0 != "\n") || $0.properties.generalCategory == .format
        }
    }
}

enum PermissionAnswer: String, Codable { case allowOnce, allowAlways, deny }

/// What the menu bar app sends to the waiting hook over the prompt's socket.
struct PermissionReply: Codable { var answer: PermissionAnswer }

struct SessionRecord: Codable, Equatable {
    var id: String
    var state: SessionState = .idle
    var message: String? = nil
    var title: String? = nil
    var cwd: String? = nil
    var bundle: String? = nil        // app that launched Claude Code (__CFBundleIdentifier)
    var hostSession: String? = nil   // Claude desktop session id (local_…), for deep links
    var pid: Int32? = nil            // Claude Code process, to drop sessions that died
    var updated: Double = 0
    var runStart: Double? = nil
    var prompt: PermissionPrompt? = nil

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let c = cwd { return (c as NSString).lastPathComponent }
        return "Claude"
    }
}

struct Config: Codable, Equatable {
    var awake: Bool = true
}

// MARK: - JSON file helpers

func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}

/// Atomic write (temp file + rename) so readers never see half a file.
func writeJSON<T: Encodable>(_ value: T, _ url: URL) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(value) else { return }
    try? data.write(to: url, options: .atomic)
}

func loadConfig() -> Config { readJSON(Config.self, Paths.config) ?? Config() }
func saveConfig(_ c: Config) { Paths.ensure(); writeJSON(c, Paths.config) }

func loadSessions() -> [SessionRecord] {
    let files = (try? FileManager.default.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { readJSON(SessionRecord.self, $0) }
}

// MARK: - App process lifecycle

/// The menu bar app holds an exclusive flock on app.lock for its whole life.
/// Returns the fd (keep it open) if we got the lock, nil if another instance has it.
func acquireAppLock() -> Int32? {
    Paths.ensure()
    let fd = open(Paths.lock.path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return nil }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return nil }
    return fd
}

func appIsRunning() -> Bool {
    guard let fd = acquireAppLock() else { return true }
    flock(fd, LOCK_UN); close(fd)
    return false
}

/// Start the menu bar app without stealing focus. (Test builds never launch it.)
func launchApp() {
    #if !TESTING
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let task = Process()
    if bundle.pathExtension == "app" {
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-g", bundle.path]
    } else {
        task.executableURL = exe
        task.arguments = ["app"]
    }
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
    #endif
}

func processAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
