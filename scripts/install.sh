#!/bin/bash
# Installs Claude Pet: the app into ~/.claude-pet, /pet into ~/.claude/commands,
# and hook entries into ~/.claude/settings.json (backed up first). Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh

DEST="$HOME/.claude-pet"
mkdir -p "$DEST/bin" "$DEST/sessions" "$HOME/.claude/commands"
chmod 700 "$DEST"                 # sessions hold commands and messages
rm -rf "$DEST/answers"            # answer files were replaced by sockets after 1.0.0

# Stop the running app so the new binary takes over.
pkill -f "$DEST/ClaudePet.app/Contents/MacOS/claude-pet" 2>/dev/null || true

rm -rf "$DEST/ClaudePet.app"
cp -R build/ClaudePet.app "$DEST/ClaudePet.app"
ln -sf "$DEST/ClaudePet.app/Contents/MacOS/claude-pet" "$DEST/bin/claude-pet"
cp commands/pet.md "$HOME/.claude/commands/"

SETTINGS="$HOME/.claude/settings.json"
# Keep the very first backup: on re-installs the file already contains our hooks.
[ -f "$SETTINGS" ] && [ ! -f "$SETTINGS.claude-pet-backup" ] && cp "$SETTINGS" "$SETTINGS.claude-pet-backup"
/usr/bin/python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
s = json.load(open(path)) if os.path.exists(path) else {}
hooks = s.setdefault("hooks", {})
cmd = "~/.claude-pet/bin/claude-pet hook"
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
          "PermissionRequest", "PermissionDenied", "Notification", "Stop", "StopFailure", "SessionEnd"]
for ev in events:
    groups = [g for g in hooks.get(ev, [])
              if not any("claude-pet hook" in h.get("command", "") for h in g.get("hooks", []))]
    # PermissionRequest waits for an answer from the menu bar; everything else returns at once.
    timeout = 600 if ev == "PermissionRequest" else 5
    groups.append({"hooks": [{"type": "command", "command": cmd, "timeout": timeout}]})
    hooks[ev] = groups
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(s, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
PY

"$DEST/bin/claude-pet" wake
echo
echo "Claude Pet installed. Hooks added to $SETTINGS (backup: $SETTINGS.claude-pet-backup)."
echo "If an already-open Claude Code session doesn't show up, restart that session."
