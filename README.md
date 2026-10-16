# Claude Pet

Your Claude Code sessions in the macOS menu bar — see what every session is doing, get told
when one needs you, and answer permission prompts without switching windows. The idea of
Codex Pets, done as a native menu bar item with a Liquid Glass panel.

> Unofficial community project; not affiliated with or endorsed by Anthropic.

## What it does

- **Menu bar item** — a monochrome ✦ and the number of active sessions, like the system's own
  items. It turns orange when a session needs input, green when one is ready, red when one is blocked.
- **Liquid Glass panel** — click the item for one row per session: state, title, latest progress
  ("Editing auth.ts", "Running npm test"), and elapsed time. Click a row to jump back to that
  session: the exact Claude desktop session (via `claude://code/continue?session=…`), or the
  terminal/IDE a CLI session runs in. Opening a finished row clears it; **Clear** clears them all.
- **Alerts** — when a session starts needing you, the panel drops down on its own for 4 seconds.
- **Permission prompts** — when Claude asks to run something, the panel drops down with the
  command and **Deny · Always Allow · Allow Once**, and stays until you answer or click
  elsewhere. Claude shows its own dialog at the same time and takes whichever answer comes
  first, so either place works. Requests the panel can't show in full (see [Security](#security)),
  questions and plan reviews are shown but must be answered in Claude.
- **`/pet`** — toggles the item; `/pet on`, `/pet off`, `/pet status`.

## Requirements

- macOS 26 or later (Liquid Glass)
- Xcode Command Line Tools (`xcode-select --install`) to build
- Claude Code — the desktop app, the CLI, or an IDE extension

## Install

```bash
git clone https://github.com/sueun-dev/claude-pet.git
cd claude-pet
scripts/install.sh
```

The installer builds the app into `~/.claude-pet`, adds the `/pet` command, and adds one hook
entry per Claude Code event to `~/.claude/settings.json` (backed up first as
`settings.json.claude-pet-backup`). To remove everything it added:

```bash
scripts/uninstall.sh            # hooks and /pet
scripts/uninstall.sh --purge    # also the app and its state in ~/.claude-pet
```

Everything stays on your Mac: no network access, no analytics.

## Security

Answering permission prompts outside Claude must not become a way around them:

- **Only Claude Pet can answer.** The panel's answer reaches the waiting hook over a Unix socket,
  never a file, and the hook accepts it only from a process running the Claude Pet executable
  itself — signed with the hardened runtime, so nothing can be injected into it. An agent that
  can write files, or run `curl`, `nc` or `python`, cannot approve its own request, and the
  release build has no command-line way to answer.
- **Only what you can see.** Buttons appear only when the panel can show the whole request: the
  full command, path or URL, at most 400 characters and 6 lines, with no control or invisible
  formatting characters and no long runs of spaces that could push part of a command out of view.
  Tools whose input it can't show (MCP tools, for example) must be answered in Claude.
- **Private state.** `~/.claude-pet` is readable only by you (700/600).

## How it works

```
Claude Code ──hook event (JSON)──▶ claude-pet hook ──writes──▶ ~/.claude-pet/sessions/<id>.json
                                         ▲                                │
                 prompts/<id>.sock ──────┘                                │ kqueue file watch
                 (Allow / Deny)                                           ▼
/pet, Hide ──▶ config.json ─────────────────────────────▶ menu bar item + Liquid Glass panel
```

- **One binary, two roles.** With no arguments it is the menu bar app; with a command it is the
  CLI that Claude Code's hooks call.
- **No polling.** The app watches `~/.claude-pet` with kqueue and reacts to file changes; a 15 s
  timer only ages out stale sessions. The menu bar label redraws only when its icon or count
  changes, and the panel's rows only while the panel is open.
- **Permission answers.** The `PermissionRequest` hook listens on a socket, records the prompt,
  and waits (up to 570 s, under its 600 s hook timeout) for the panel's answer, then prints the
  decision. If you answer in Claude instead, the hook sees the prompt close and exits without one.

Measured on Apple silicon: about 8 ms per hook event; with busy sessions and the panel
closed, the app sits at about 0.1 % CPU and 20 MB of memory.

### Known limitation

Claude Code doesn't tell hooks when you answer its own dialog. If you answer there, the
panel's prompt clears when that command finishes, or when Claude's turn ends if you denied it.
Pressing its buttons in the meantime does nothing.

## Development

```bash
scripts/build.sh            # build/ClaudePet.app
tests/run_tests.sh          # CLI, hook state machine and answer security, against a throwaway CLAUDE_PET_HOME
tests/run_app_checks.sh     # the real menu bar app, driven by synthetic clicks (needs a GUI session)
```

```
Sources/
  main.swift                       CLI dispatch and app entry
  Core/Store.swift                 ~/.claude-pet files, session model, app lock and launch
  Core/AnswerChannel.swift         the socket that carries the panel's answer to the waiting hook
  Hook/HookHandler.swift           hook event → session state; waits for permission answers
  MenuBar/MenuBarController.swift  status item, dropdown panel, file watching, actions
  MenuBar/SessionViews.swift       SwiftUI: menu bar label, Liquid Glass panel, rows, prompt buttons
commands/pet.md                    the /pet slash command
scripts/                           build, install, uninstall
tests/                             run_tests.sh, run_app_checks.sh, app_checks/
```

## License

[MIT](LICENSE)
