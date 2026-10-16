import AppKit
// App-level checks: runs the real MenuBarController against a throwaway CLAUDE_PET_HOME,
// drives it with session-file changes and synthetic clicks, and asserts what it does.
// Built and run by tests/run_app_checks.sh; needs a logged-in GUI session.
//   app_checks            full scenario
//   app_checks launch     the app launched by a pending permission prompt

var failures = 0
func expect(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  FAIL \(what)"); if !ok { failures += 1 } }

let me = getpid()
func write(_ id: String, _ state: SessionState, title: String, prompt: PermissionPrompt? = nil, age: Double = 0) {
    var r = SessionRecord(id: id)
    r.state = state; r.title = title; r.message = "msg \(id)"; r.pid = me
    r.updated = Date().timeIntervalSince1970 - age; r.runStart = r.updated; r.prompt = prompt
    writeJSON(r, Paths.session(id))
}
func read(_ id: String) -> SessionRecord? { readJSON(SessionRecord.self, Paths.session(id)) }

func find<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
    guard let view else { return [] }
    return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) }
}
var panel: NSPanel? { NSApp.windows.compactMap { $0 as? NSPanel }.first }
var statusButton: NSStatusBarButton? { NSApp.windows.flatMap { find(NSStatusBarButton.self, in: $0.contentView) }.first }
var itemFrame: NSRect { statusButton.flatMap { b in b.window?.convertToScreen(b.convert(b.bounds, to: nil)) } ?? .zero }

func panelIsUnderItem() -> Bool {
    guard let p = panel, p.isVisible else { return false }
    let onScreen = NSScreen.screens.contains { $0.frame.contains(p.frame) }
    let below = abs(itemFrame.minY - p.frame.maxY - 6) < 1        // 6 pt: the panel's gap under the menu bar
    let near = p.frame.minX <= itemFrame.maxX && p.frame.maxX >= itemFrame.minX
    return onScreen && below && near
}

/// SwiftUI only builds its accessibility tree for a client, but it keeps a focus-ring (and
/// sometimes a KeyViewProxy) view over every button; the prompt row's three are those, left to right.
func promptButtons() -> [NSView] {
    let marker = find(NSView.self, in: panel?.contentView).contains { String(describing: type(of: $0)) == "KeyViewProxy" }
        ? "KeyViewProxy" : "_FocusRingView"
    let proxies = find(NSView.self, in: panel?.contentView).filter { String(describing: type(of: $0)) == marker }
    let rows = Dictionary(grouping: proxies) { $0.frame.minY }          // the header's Clear sits on its own line
    return (rows.values.first { $0.count == 3 } ?? []).sorted { $0.frame.minX < $1.frame.minX }
}
func click(_ view: NSView, at point: NSPoint? = nil) {
    guard let w = view.window else { return }
    let p = view.convert(point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        w.sendEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }
}

let prompt = PermissionPrompt(id: "PROMPT-1", tool: "Bash", detail: "rm -rf dist", inputKey: "k", canAlwaysAllow: true,
                              answerable: true, created: Date().timeIntervalSince1970)
var listener: AnswerListener?   // stands in for the hook waiting on PROMPT-1
var steps: [(Double, String, () -> Void)] = []
func step(_ after: Double, _ name: String, _ body: @escaping () -> Void) { steps.append((after, name, body)) }

Paths.ensure()
if CommandLine.arguments.dropFirst().first == "launch" {
    write("b", .needsInput, title: "Deploy", prompt: prompt)      // the prompt whose hook launched us
    step(1.5, "launched by a permission prompt") {
        expect(panelIsUnderItem(), "the panel drops down on screen, right under the menu bar item (panel \(panel?.frame ?? .zero), item \(itemFrame))")
        expect(promptButtons().count == 3, "the prompt shows Deny, Always Allow and Allow Once")
    }
} else {
    write("a", .ready, title: "Old finished task", age: 60)       // finished before launch
    step(1.0, "launch with only a finished session") {
        expect(panel?.isVisible != true, "a session that finished before launch does not drop the panel")
        expect(statusButton?.accessibilityLabel() == "Claude Pet, 1 active session, ready", "menu bar item is labelled (\(statusButton?.accessibilityLabel() ?? "nil"))")
        expect((statusButton?.frame.width ?? 0) > 20, "menu bar item has a width (\(statusButton?.frame.width ?? 0))")
    }
    step(0.2, "permission prompt arrives") { write("b", .needsInput, title: "Deploy", prompt: prompt) }
    step(0.8, "") {
        expect(panelIsUnderItem(), "a permission prompt drops the panel down under the item")
        expect(promptButtons().count == 3, "the prompt shows Deny, Always Allow and Allow Once")
    }
    step(4.5, "") { expect(panel?.isVisible == true, "the prompt panel stays open past the 4 s alert time") }
    step(0.1, "click Allow Once") {
        listener = AnswerListener(promptID: prompt.id)
        if let b = promptButtons().last { click(b) }
    }
    step(0.1, "") {
        expect(listener?.nextAnswer(waitingAtMost: 2) == .allowOnce, "Allow Once reaches the waiting hook")
        expect(panel?.isVisible == true, "the button did not also trigger its row (panel still open)")
        listener = nil
    }
    step(0.1, "hook closes the prompt") { write("b", .running, title: "Deploy") }
    step(0.8, "") { expect(panel?.isVisible != true, "the panel closes once the prompt is answered") }
    step(0.1, "a prompt the panel can't show in full") {
        var p = prompt; p.id = "PROMPT-2"; p.answerable = false
        write("d", .needsInput, title: "Long command", prompt: p)
    }
    step(0.8, "") {
        expect(panelIsUnderItem(), "it still drops the panel down")
        expect(promptButtons().isEmpty, "but offers no buttons: it must be answered in Claude")
    }
    step(0.1, "") { write("d", .running, title: "Long command") }
    step(0.8, "") { expect(panel?.isVisible != true, "the panel closes once that prompt is gone") }
    step(0.2, "a running session finishes") { write("c", .running, title: "Tests") }
    step(0.5, "") { write("c", .ready, title: "Tests") }
    step(0.8, "") { expect(panelIsUnderItem(), "a session finishing after launch drops the panel under the item") }
    step(4.6, "") { expect(panel?.isVisible != true, "the finish alert closes by itself after 4 s") }
    step(0.2, "click the menu bar item") { statusButton?.performClick(nil) }
    step(0.6, "") { expect(panelIsUnderItem(), "clicking the item opens the panel under it") }
    step(5.0, "") { expect(panel?.isVisible == true, "a clicked-open panel stays open") }
    step(0.1, "click the first row (Tests, the newest finished)") {
        if let host = panel?.contentView { click(host, at: NSPoint(x: 150, y: host.isFlipped ? 52 : host.bounds.height - 52)) }
    }
    step(0.8, "") {
        expect(read("c")?.state == .idle, "opening a finished row clears it")
        expect(read("a")?.state == .ready, "other rows are untouched")
        expect(panel?.isVisible != true, "opening a row closes the panel")
    }
    step(0.2, "toggle") { statusButton?.performClick(nil) }
    step(0.6, "") { expect(panel?.isVisible == true, "first click opens"); statusButton?.performClick(nil) }
    step(0.6, "") { expect(panel?.isVisible != true, "second click on the item closes the panel") }
}

func run(_ i: Int) {
    guard i < steps.count else { print(failures == 0 ? "ALL APP CHECKS PASSED" : "\(failures) APP CHECK(S) FAILED"); exit(failures == 0 ? 0 : 1) }
    let (after, name, body) = steps[i]
    DispatchQueue.main.asyncAfter(deadline: .now() + after) {
        if !name.isEmpty { print("• \(name)") }
        body(); run(i + 1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MenuBarController()
controller.start()
run(0)
withExtendedLifetime(controller) { app.run() }
