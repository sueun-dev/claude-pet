import AppKit
import SwiftUI

private let staleRunning: Double = 45 * 60   // a "running" session silent this long probably crashed
private let forgetAfter: Double = 12 * 3600
private let alertSeconds: Double = 4          // how long a new alert drops the panel down
private let promptLifetime: Double = 600      // the hook gives up waiting before this
private let panelGap: CGFloat = 6             // space between the menu bar and the panel

/// Borderless, never-focused panel that hangs under the menu bar item.
private final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts the SwiftUI label inside the status item button without stealing its clicks.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The panel never becomes key, so its buttons must react to the very first click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Calls `onChange` when files are added, replaced or removed in a directory.
private final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(_ url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

/// A menu bar item showing Claude Code session status, with a Liquid Glass panel that
/// drops down on click — or on its own when a session starts needing you. Permission
/// prompts can be answered right in the panel. Reacts to file changes in ~/.claude-pet
/// (written by the hook and the CLI) instead of polling.
final class MenuBarController: NSObject {
    private let status = StatusModel()
    private let model = SessionsModel()
    private var latest: [SessionRecord] = []    // shown in the panel once it opens
    private var statusItem: NSStatusItem!
    private var label: NSHostingView<StatusLabel>!
    private var panel: DropdownPanel!
    private var content: NSHostingView<SessionsPanel>!
    private var watchers: [DirectoryWatcher] = []
    private var clickMonitor: Any?
    private var pinnedOpen = false               // opened by a click: stays until clicked away
    private var openForPrompt = false            // dropped down for a permission prompt
    private var alertGeneration = 0
    private var hasLoaded = false

    func start() {
        // The lock stays held (its descriptor open) until this process exits.
        guard acquireAppLock() != nil else { NSApp.terminate(nil); return }
        var config = loadConfig()
        if !config.awake { config.awake = true; saveConfig(config) }

        model.onOpen = { [weak self] in self?.open($0) }
        model.onClearFinished = { [weak self] in self?.clearFinished() }
        model.onAnswer = { prompt, answer in
            DispatchQueue.global(qos: .userInitiated).async { sendAnswer(answer, to: prompt.id) }   // waits for the hook's ack
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        label = PassthroughHostingView(rootView: StatusLabel(model: status))
        if let button = statusItem.button {
            button.addSubview(label)
            button.target = self
            button.action = #selector(togglePanel)
            // The system positions the item only after launch, so a panel shown right away
            // (an alert that launched us) has to follow the item to its real place.
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: button.window,
                                                   queue: .main) { [weak self] _ in self?.followItem() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.followItem() }

        content = FirstClickHostingView(rootView: SessionsPanel(model: model))
        panel = DropdownPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = content

        Paths.ensure()
        watchers = [
            DirectoryWatcher(Paths.sessions) { [weak self] in self?.refresh() },
            DirectoryWatcher(Paths.root) { if !loadConfig().awake { NSApp.terminate(nil) } },
        ].compactMap { $0 }
        // Housekeeping for things that age rather than change: stale sessions, orphaned sockets.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.removeOrphanedSockets()
        }

        refresh()
        hasLoaded = true
        sizeLabel()
    }

    // MARK: - Sessions

    private func refresh() {
        let now = Date().timeIntervalSince1970
        var active: [SessionRecord] = []
        for var r in loadSessions() {
            let dead = r.pid.map { !processAlive($0) } ?? false
            if dead || now - r.updated > forgetAfter {
                try? FileManager.default.removeItem(at: Paths.session(r.id))
                continue
            }
            if r.state == .running && now - r.updated > staleRunning { r.state = .idle }
            if let p = r.prompt, now - p.created > promptLifetime { r.prompt = nil }   // its hook is gone
            if r.state != .idle { active.append(r) }
        }
        active.sort { ($0.state.priority, -$0.updated) < ($1.state.priority, -$1.updated) }
        guard active != latest else { return }

        let before = Dictionary(latest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // At launch, sessions that finished earlier only update the icon; anything waiting
        // on you (including the permission prompt that may have launched us) still alerts.
        let alerting: Set<SessionState> = hasLoaded ? [.needsInput, .ready, .blocked] : [.needsInput]
        let newAlert = active.contains { alerting.contains($0.state) && before[$0.id]?.state != $0.state }
        let newPrompt = active.contains { $0.prompt != nil && before[$0.id]?.prompt?.id != $0.prompt?.id }
        latest = active

        let labelBefore = (status.headline, status.count)
        status.update(headline: active.first?.state ?? .idle, count: active.count)
        if labelBefore != (status.headline, status.count) { DispatchQueue.main.async { self.sizeLabel() } }
        if panel.isVisible { showLatestInPanel() }
        if openForPrompt && !active.contains(where: { $0.prompt != nil }) && !pinnedOpen { hidePanel() }
        if newAlert || newPrompt {
            status.attention += 1
            model.attention += 1
            showAlert(staysOpen: newPrompt)
        }
    }

    private func showLatestInPanel() {
        guard model.sessions != latest else { return }
        model.sessions = latest
        DispatchQueue.main.async { self.placePanel() }   // after SwiftUI has measured the change
    }

    /// Sockets left behind by hooks that were killed before they could clean up (Claude
    /// kills its hooks when it quits): no session still shows their prompt.
    private func removeOrphanedSockets() {
        let fm = FileManager.default, now = Date().timeIntervalSince1970
        let open = Set(loadSessions().compactMap { $0.prompt?.id })
        for url in (try? fm.contentsOfDirectory(at: Paths.prompts, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let age = modified.map { now - $0.timeIntervalSince1970 } ?? 0
            // A hook creates its socket a moment before it publishes the prompt.
            if age > 5 && !open.contains(url.deletingPathExtension().lastPathComponent) { try? fm.removeItem(at: url) }
        }
    }

    // MARK: - Layout

    private func sizeLabel() {
        let size = label.fittingSize
        statusItem.length = size.width
        guard let button = statusItem.button else { return }
        label.frame = NSRect(x: 0, y: (button.bounds.height - size.height) / 2, width: size.width, height: size.height)
        let summary = status.count == 0 ? "no active sessions"
            : "\(status.count) active \(status.count == 1 ? "session" : "sessions"), \(status.headline.label.lowercased())"
        button.setAccessibilityLabel("Claude Pet, \(summary)")
        button.toolTip = "Claude Pet — \(summary)"
    }

    private func followItem() {
        if panel.isVisible { placePanel() }
    }

    /// Under the menu bar item, kept on screen; grows downward from a fixed top edge.
    private func placePanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        let item = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = content.fittingSize
        let screen = window.screen?.visibleFrame ?? item
        let x = min(max(item.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: item.minY - panelGap - size.height, width: size.width, height: size.height), display: true)
    }

    // MARK: - Panel

    /// Like a menu: a click opens the panel (and keeps it open), the next click closes it.
    @objc private func togglePanel() {
        if panel.isVisible { hidePanel() } else { pinnedOpen = true; showPanel() }
    }

    /// A new alert drops the panel down for a few seconds — or, for a permission prompt,
    /// until it is answered or clicked away — unless the user already opened it.
    private func showAlert(staysOpen: Bool) {
        guard !pinnedOpen else { return }
        alertGeneration += 1
        let generation = alertGeneration
        showPanel()
        openForPrompt = openForPrompt || staysOpen
        if !staysOpen { hideAfterAlert(generation, delay: alertSeconds) }
    }

    /// Closes an alert once its time is up and the pointer isn't resting on the panel.
    private func hideAfterAlert(_ generation: Int, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.alertGeneration, !self.pinnedOpen, !self.openForPrompt else { return }
            if self.panel.frame.contains(NSEvent.mouseLocation) { self.hideAfterAlert(generation, delay: 1) }
            else { self.hidePanel() }
        }
    }

    private func showPanel() {
        model.sessions = latest
        placePanel()
        DispatchQueue.main.async { self.placePanel() }   // again, once SwiftUI has laid out new rows
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        statusItem.button?.highlight(pinnedOpen)
        if clickMonitor == nil {
            // A click anywhere else (other apps) closes the panel, like a menu.
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hidePanel()
            }
        }
    }

    private func hidePanel() {
        pinnedOpen = false
        openForPrompt = false
        alertGeneration += 1
        statusItem.button?.highlight(false)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            guard let self, !self.pinnedOpen, self.clickMonitor == nil else { return }
            self.panel.orderOut(nil)
        })
    }

    // MARK: - Actions

    /// Jump back to the session: the exact desktop session via deep link, otherwise the
    /// app (terminal, IDE) that launched it. Opening a finished session clears it.
    private func open(_ rec: SessionRecord) {
        hidePanel()
        if let host = rec.hostSession, host.hasPrefix("local_"),
           let url = URL(string: "claude://code/continue?session=\(host)") {
            NSWorkspace.shared.open(url)
        } else if let bundle = rec.bundle {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate()
        }
        if rec.state == .ready || rec.state == .blocked { markSeen([rec.id]) }
    }

    private func clearFinished() {
        markSeen(latest.filter { $0.state == .ready || $0.state == .blocked }.map(\.id))
    }

    private func markSeen(_ ids: [String]) {
        for id in ids {
            let url = Paths.session(id)
            guard var r = readJSON(SessionRecord.self, url) else { continue }
            r.state = .idle
            writeJSON(r, url)
        }
    }
}

func runApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = MenuBarController()
    controller.start()
    withExtendedLifetime(controller) { app.run() }
}
