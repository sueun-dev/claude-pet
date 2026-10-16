#!/bin/bash
# Removes Claude Pet's hooks and commands. Pass --purge to also delete ~/.claude-pet
# (the app and its state).
set -euo pipefail

DEST="$HOME/.claude-pet"
[ -x "$DEST/bin/claude-pet" ] && "$DEST/bin/claude-pet" sleep >/dev/null 2>&1 || true
pkill -f "$DEST/ClaudePet.app/Contents/MacOS/claude-pet" 2>/dev/null || true

rm -f "$HOME/.claude/commands/pet.md"

SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  /usr/bin/python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
s = json.load(open(path))
hooks = s.get("hooks", {})
for ev in list(hooks):
    hooks[ev] = [g for g in hooks[ev]
                 if not any("claude-pet hook" in h.get("command", "") for h in g.get("hooks", []))]
    if not hooks[ev]:
        del hooks[ev]
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(s, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
PY
fi

if [ "${1:-}" = "--purge" ]; then rm -rf "$DEST"; echo "Removed $DEST"; fi
echo "Claude Pet uninstalled."
