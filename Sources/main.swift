import Foundation

// One binary, two roles: run with no arguments it is the menu bar app; with a command
// it is the CLI used by the hooks, the /pet slash command, and you.

let usage = """
claude-pet — Claude Code sessions in the menu bar

  claude-pet                 run the menu bar app (normally started for you)
  claude-pet wake | sleep    show / hide the menu bar item
  claude-pet status          show the tracked sessions
  claude-pet cmd [on|off|status]   entry point for the /pet slash command
  claude-pet hook            Claude Code hook entry point (event JSON on stdin)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func setAwake(_ awake: Bool) {
    var c = loadConfig()
    c.awake = awake
    saveConfig(c)
    if awake && !appIsRunning() { launchApp() }
    print(awake ? "Claude Pet is on." : "Claude Pet is hidden. Run /pet to bring it back.")
}

func status() {
    print("awake: \(loadConfig().awake)   running: \(appIsRunning())")
    for r in loadSessions().sorted(by: { $0.updated > $1.updated }) {
        print("- [\(r.state.label)] \(r.displayTitle): \(r.message ?? "")")
    }
}

let commands: [String: () -> Void] = [
    "wake": { setAwake(true) },
    "sleep": { setAwake(false) },
    "status": status,
    "help": { print(usage) },
]

/// Words accepted by `/pet`; no argument toggles.
let aliases = ["on": "wake", "show": "wake", "off": "sleep", "hide": "sleep"]

func petCommand(_ word: String?) {
    guard let word = word?.lowercased() else {
        setAwake(!(loadConfig().awake && appIsRunning()))
        return
    }
    guard let run = commands[aliases[word] ?? word] else { fail(usage) }
    run()
}

Paths.ensure()
let argv = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }   // LaunchServices noise

switch argv.first {
case nil, "app": runApp()
case "hook": runHook()
case "cmd": petCommand(argv.dropFirst().first)
case let name? where commands[name] != nil: commands[name]!()
default: fail(usage)
}
