import CryptoKit
import Foundation

// `claude-pet hook` — registered for every Claude Code hook event. Reads the event JSON
// on stdin and folds it into ~/.claude-pet/sessions/<session>.json.
//
// For PermissionRequest it can also wait for an answer from the menu bar, delivered over a
// socket (see AnswerChannel.swift). Claude shows its own dialog at the same time and takes
// whichever answer comes first, so if the user answers in Claude instead, the hook notices
// and exits without printing anything. Apart from that one decision, the hook must stay
// silent: stdout is read as hook output.

private let answerTimeout: Double = 570   // just under the 600 s hook timeout install.sh sets
private let answerPoll: Double = 0.15

/// A question or plan review: answering it blindly would skip what Claude is asking,
/// so it is shown as "needs input" but never turned into a prompt.
private let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

/// Tools whose whole request fits in `permissionDetail` — a command, a file to read, a URL —
/// so the panel shows everything being approved. Edits (whose diff the panel can't show),
/// MCP tools and the rest must be answered in Claude.
private let reviewableTools: Set<String> = ["Bash", "Read", "WebFetch"]

func runHook() {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let ev = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
          let sid = ev["session_id"] as? String,
          let name = ev["hook_event_name"] as? String else { return }

    Paths.ensure()
    let url = Paths.session(sid)

    if name == "SessionEnd" {
        try? FileManager.default.removeItem(at: url)
        return
    }

    var rec = readJSON(SessionRecord.self, url) ?? SessionRecord(id: sid)
    let env = ProcessInfo.processInfo.environment
    let now = Date().timeIntervalSince1970
    rec.cwd = ev["cwd"] as? String ?? rec.cwd
    func envValue(_ k: String) -> String? { env[k].flatMap { $0.isEmpty ? nil : $0 } }
    rec.bundle = envValue("__CFBundleIdentifier") ?? rec.bundle
    rec.hostSession = envValue("CLAUDE_CODE_HOST_SESSION_ID") ?? rec.hostSession
    rec.pid = rec.pid ?? claudePid(env)
    if let t = ev["session_title"] as? String, !t.isEmpty { rec.title = clip(t, 60) }

    apply(name, ev, to: &rec, now: now)
    rec.updated = now
    if rec.state == .running && rec.runStart == nil { rec.runStart = now }   // hooks installed mid-turn

    // Listen before publishing the prompt, so the app can never answer into the void.
    var listener: AnswerListener?
    if name == "PermissionRequest", let prompt = rec.prompt, prompt.answerable {
        listener = AnswerListener(promptID: prompt.id)
        if listener == nil { rec.prompt?.answerable = false }
    }
    writeJSON(rec, url)

    if loadConfig().awake && !appIsRunning() { launchApp() }

    if let listener, let prompt = rec.prompt {
        waitForAnswer(to: prompt, on: listener, session: url, suggestions: ev["permission_suggestions"])
    }
}

private func apply(_ name: String, _ ev: [String: Any], to rec: inout SessionRecord, now: Double) {
    let tool = ev["tool_name"] as? String ?? ""
    let input = ev["tool_input"] as? [String: Any] ?? [:]

    switch name {
    case "SessionStart":
        if rec.state != .running { rec.state = .idle; rec.message = nil }

    case "UserPromptSubmit":
        if rec.title == nil, let p = ev["prompt"] as? String {
            let title = firstLine(withoutTaggedBlocks(p))
            if !title.isEmpty { rec.title = clip(title, 48) }
        }
        rec.prompt = nil
        rec.state = .running
        rec.message = "Thinking…"
        rec.runStart = now

    case "PreToolUse":
        switch tool {
        case "AskUserQuestion":
            rec.state = .needsInput
            rec.message = (input["questions"] as? [[String: Any]])?.first?["question"] as? String ?? "Claude has a question for you"
        case "ExitPlanMode":
            rec.state = .needsInput
            rec.message = "Plan is ready for your review"
        default:
            rec.state = .running
            rec.message = describe(tool, input)
        }

    case "PostToolUse", "PostToolUseFailure":
        if rec.prompt?.inputKey == fingerprint(tool, input) { rec.prompt = nil }
        // Answering a permission prompt or question lands here: back to work.
        if rec.state == .needsInput || rec.state == .idle { rec.state = .running; rec.message = "Working…" }

    case "PermissionRequest" where questionTools.contains(tool):
        rec.state = .needsInput   // keep the question or plan text PreToolUse already showed

    case "PermissionRequest":
        let detail = permissionDetail(tool, input)
        rec.prompt = PermissionPrompt(id: String(format: "%016llx", UInt64.random(in: .min ... .max)), tool: tool,
                                      detail: clip(detail, 2000), inputKey: fingerprint(tool, input),
                                      canAlwaysAllow: !((ev["permission_suggestions"] as? [Any]) ?? []).isEmpty,
                                      answerable: reviewableTools.contains(tool) && PermissionPrompt.isReviewable(detail)
                                                  && loadConfig().awake,
                                      created: now)

    case "PermissionDenied":
        rec.prompt = nil
        rec.state = .running
        rec.message = "Permission denied"

    case "Notification":
        let type = ev["notification_type"] as? String ?? ""
        if type == "permission_prompt" || type == "elicitation_dialog" {
            rec.state = .needsInput
            rec.message = ev["message"] as? String ?? "Waiting for your input"
        }

    case "Stop":
        rec.prompt = nil
        rec.state = .ready
        let last = (ev["last_assistant_message"] as? String).map(summary) ?? ""
        rec.message = last.isEmpty ? "Finished" : last

    case "StopFailure":
        rec.prompt = nil
        rec.state = .blocked
        let err = ev["error"] as? String ?? "unknown"
        rec.message = "Stopped: \(err.replacingOccurrences(of: "_", with: " "))"

    default:
        break
    }

    // An open permission prompt outranks whatever else the session is doing.
    if let p = rec.prompt {
        rec.state = .needsInput
        rec.message = p.question
    }
}

// MARK: - Permission answers

/// Blocks until the menu bar answers, the prompt goes away (answered in Claude, or
/// replaced by a newer one), or the timeout passes. Prints a decision only for a menu bar answer.
private func waitForAnswer(to prompt: PermissionPrompt, on listener: AnswerListener, session url: URL, suggestions: Any?) {
    let deadline = Date().addingTimeInterval(answerTimeout)
    while Date() < deadline {
        if let answer = listener.nextAnswer(to: prompt, waitingAtMost: answerPoll) {
            closePrompt(prompt.id, in: url, message: answer == .deny ? "Denied from the menu bar" : "Working…")
            printDecision(answer, suggestions: suggestions)
            return
        }
        guard readJSON(SessionRecord.self, url)?.prompt?.id == prompt.id else { return }
    }
    closePrompt(prompt.id, in: url, message: nil)
}

private func closePrompt(_ id: String, in url: URL, message: String?) {
    guard var rec = readJSON(SessionRecord.self, url), rec.prompt?.id == id else { return }
    rec.prompt = nil
    rec.state = .running
    rec.message = message ?? rec.message
    rec.updated = Date().timeIntervalSince1970
    writeJSON(rec, url)
}

private func printDecision(_ answer: PermissionAnswer, suggestions: Any?) {
    let decision: [String: Any]
    switch answer {
    case .allowOnce: decision = ["behavior": "allow"]
    case .allowAlways: decision = ["behavior": "allow", "updatedPermissions": suggestions ?? []]
    case .deny: decision = ["behavior": "deny", "message": "Denied from the Claude Pet menu bar"]
    }
    let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    if let data = try? JSONSerialization.data(withJSONObject: output) {
        FileHandle.standardOutput.write(data)
    }
}

/// Stable id for one tool call's input, so its PostToolUse can close the matching prompt.
private func fingerprint(_ tool: String, _ input: [String: Any]) -> String {
    let json = (try? JSONSerialization.data(withJSONObject: input, options: .sortedKeys)) ?? Data()
    return SHA256.hash(data: Data(tool.utf8) + json).prefix(8).map { String(format: "%02x", $0) }.joined()
}

/// What the permission is about, in full enough detail to decide.
private func permissionDetail(_ tool: String, _ input: [String: Any]) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    switch tool {
    case "Bash": return input["command"] as? String ?? ""
    case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
        let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? ""
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    case "WebFetch": return input["url"] as? String ?? ""
    default: return describe(tool, input)
    }
}

// MARK: - Text

/// Short present-tense progress line for the menu bar panel.
func describe(_ tool: String, _ input: [String: Any]) -> String {
    func file() -> String {
        ((input["file_path"] as? String) ?? (input["notebook_path"] as? String)).map { ($0 as NSString).lastPathComponent } ?? "file"
    }
    switch tool {
    case "Bash": return "Running " + clip(firstLine(input["command"] as? String ?? "command"), 50)
    case "Edit", "MultiEdit", "NotebookEdit": return "Editing \(file())"
    case "Write": return "Writing \(file())"
    case "Read": return "Reading \(file())"
    case "Grep", "Glob": return "Searching " + clip(input["pattern"] as? String ?? "files", 40)
    case "WebSearch": return "Searching the web for " + clip(input["query"] as? String ?? "…", 40)
    case "WebFetch": return "Reading " + (URL(string: input["url"] as? String ?? "")?.host ?? "a web page")
    case "Agent", "Task": return "Delegating: " + clip(input["description"] as? String ?? "subtask", 40)
    case "Skill": return "Using skill " + (input["skill"] as? String ?? "")
    case "TodoWrite", "TaskCreate", "TaskUpdate": return "Updating the plan"
    default:
        if tool.hasPrefix("mcp__") {
            let parts = tool.components(separatedBy: "__")
            let server = parts.count > 1 ? parts[1].replacingOccurrences(of: "_", with: " ") : "tool"
            return "Using \(server)" + (parts.count > 2 ? ": \(parts[2].replacingOccurrences(of: "_", with: " "))" : "")
        }
        return "Using \(tool)"
    }
}

/// Prompts can carry injected context such as `<system-reminder>…</system-reminder>`;
/// drop those blocks so the title comes from what the user typed.
private func withoutTaggedBlocks(_ s: String) -> String {
    s.replacingOccurrences(of: "<([a-zA-Z][\\w-]*)[^>]*>[\\s\\S]*?</\\1>", with: "", options: .regularExpression)
}

private func firstLine(_ s: String) -> String {
    s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
}

/// First meaningful line of Claude's final message, with markdown stripped.
private func summary(_ s: String) -> String {
    let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("★") && !$0.hasPrefix("```") && !$0.allSatisfy { "─=_-`".contains($0) } }
    // Prefer prose over a markdown heading like "## Summary".
    let pick = lines.first { !$0.hasPrefix("#") } ?? lines.first ?? ""
    let line = pick.trimmingCharacters(in: CharacterSet(charactersIn: " #>*-`|"))
    return clip(line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: ""), 140)
}

func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

// MARK: - Process lookup

/// The Claude Code process this hook belongs to: $CLAUDE_PID when set, otherwise the
/// nearest ancestor that is not a shell.
private func claudePid(_ env: [String: String]) -> Int32? {
    if let s = env["CLAUDE_PID"], let p = Int32(s), p > 1 { return p }
    var pid = getppid()
    for _ in 0..<3 {
        guard pid > 1, let (name, parent) = procInfo(pid) else { return nil }
        if !["sh", "bash", "zsh", "dash", "fish"].contains(name) { return pid }
        pid = parent
    }
    return nil
}

private func procInfo(_ pid: Int32) -> (String, Int32)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    return (name, info.kp_eproc.e_ppid)
}
