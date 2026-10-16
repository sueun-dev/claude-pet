#!/bin/bash
# End-to-end checks for the CLI and the hook state machine. Runs against a throwaway
# CLAUDE_PET_HOME, so your real sessions and menu bar app are never touched.
#   scripts/build.sh && tests/run_tests.sh
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="$PWD/build/ClaudePet.app/Contents/MacOS/claude-pet"
[ -x "$BIN" ] || { echo "build first: scripts/build.sh"; exit 1; }
export CLAUDE_PET_HOME="$(mktemp -d)"
trap 'rm -rf "$CLAUDE_PET_HOME"' EXIT

pass=0 fail=0
ok()    { pass=$((pass + 1)); }
bad()   { fail=$((fail + 1)); printf 'FAIL %s\n  expected: %s\n  got: %s\n' "$1" "$2" "$3"; }
check() { [[ "$3" == *"$2"* ]] && ok || bad "$1" "…$2…" "$3"; }   # actual contains expected
same()  { [[ "$3" == "$2" ]] && ok || bad "$1" "$2" "$3"; }        # actual equals expected

hook() {   # feed one event; the hook must exit 0 within 5 s and print nothing
  local out="$CLAUDE_PET_HOME/hook.out" pid rc
  CLAUDE_PID=$$ "$BIN" hook <<<"$1" >"$out" 2>&1 &
  pid=$!
  for _ in $(seq 250); do kill -0 "$pid" 2>/dev/null || break; sleep 0.02; done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"; wait "$pid"
    bad "hook returns: ${1:0:60}" "exit within 5 s" "still running"; return
  fi
  wait "$pid"; rc=$?
  same "hook is silent: ${1:0:60}" "rc=0 out=" "rc=$rc out=$(cat "$out")"
}
hook_bg() { CLAUDE_PID=$$ "$BIN" hook <<<"$1" >"$2" & }   # PermissionRequest waits for an answer
finish_bg() {   # wait up to 5 s for background hooks; one that is still waiting is a failure
  for _ in $(seq 50); do [ -z "$(jobs -rp)" ] && { wait; return; }; sleep 0.1; done
  kill $(jobs -rp) 2>/dev/null; wait
  bad "background hook finishes" "exit within 5 s" "still waiting"
}
state() { "$BIN" status | grep -F "$1" | head -1; }
field() {   # field <session> <key> [<subkey>] — a value from the session's JSON, or ""
  python3 - "$CLAUDE_PET_HOME/sessions/$1.json" "${@:2}" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2:]:
    value = value.get(key) if isinstance(value, dict) else None
print("" if value is None else value)
PY
}
prompt_id() { field "$1" prompt id; }
wait_prompt() { for _ in $(seq 50); do id=$(prompt_id "$1"); [ -n "$id" ] && { echo "$id"; return; }; sleep 0.1; done; }

"$BIN" sleep >/dev/null   # keep the app from launching during tests

# --- session lifecycle -------------------------------------------------------
S='"session_id":"s1","cwd":"/work/web-app"'
hook "{$S,\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"Fix the login bug\\nplease\"}"
check "prompt → running, titled from prompt" "[Running] Fix the login bug: Thinking…" "$(state 'Fix the login')"
started=$(field s1 runStart)

hook "{$S,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/a/auth.ts\"}}"
check "tool use → progress line" "Editing auth.ts" "$(state 'Fix the login')"

hook_bg "{$S,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf dist\"}}" /dev/null
wait_prompt s1 >/dev/null
check "permission → needs input" "[Needs input] Fix the login bug: Allow Bash?" "$(state 'Fix the login')"

hook "{$S,\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf dist\"}}"
finish_bg
check "answered → running again" "[Running]" "$(state 'Fix the login')"
same "elapsed time keeps counting from the prompt" "$started" "$(field s1 runStart)"

hook "{$S,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"question\":\"Which provider?\"}]}}"
hook "{$S,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"question\":\"Which provider?\"}]}}"
check "question → needs input, question text kept" "[Needs input] Fix the login bug: Which provider?" "$(state 'Fix the login')"
same "questions get no answer buttons" "" "$(prompt_id s1)"

hook "{$S,\"hook_event_name\":\"PermissionDenied\",\"tool_name\":\"Bash\",\"tool_input\":{}}"
check "denied → back to work" "[Running] Fix the login bug: Permission denied" "$(state 'Fix the login')"

hook "{$S,\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"## Summary\\n**Fixed** the \`login\` loop.\"}"
check "stop → ready with prose summary" "[Ready] Fix the login bug: Fixed the login loop." "$(state 'Fix the login')"

hook '{"session_id":"s2","cwd":"/work/api","hook_event_name":"StopFailure","error":"rate_limit"}'
check "api failure → blocked" "[Blocked] api: Stopped: rate limit" "$(state 'api')"

hook '{"session_id":"s2","hook_event_name":"SessionEnd"}'
same "session end → forgotten" "" "$(state 'api')"

hook '{"session_id":"s3","cwd":"/work/docs","hook_event_name":"UserPromptSubmit","prompt":"<system-reminder>\nctx\n</system-reminder>\nWrite the release notes"}'
check "title skips injected tags" "[Running] Write the release notes" "$(state 'release notes')"

hook 'not json'
hook '{}'

# --- permission prompts answered from the menu bar ----------------------------
P='"session_id":"p1","cwd":"/work/infra"'
REQ="{$P,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf dist\"},\"permission_suggestions\":[{\"type\":\"addRules\",\"rules\":[{\"toolName\":\"Bash\",\"ruleContent\":\"rm:*\"}],\"behavior\":\"allow\",\"destination\":\"localSettings\"}]}"

hook_bg "$REQ" "$CLAUDE_PET_HOME/out1"
id=$(wait_prompt p1)
check "prompt is recorded" "[Needs input] infra: Allow Bash?" "$(state 'infra')"
same "prompt shows the command" "rm -rf dist" "$(field p1 prompt detail)"
same "prompt offers always-allow" "True" "$(field p1 prompt canAlwaysAllow)"
echo '{"answer":"allowAlways"}' > "$CLAUDE_PET_HOME/answers/$id.json"
finish_bg
check "always allow → allow" '"behavior":"allow"' "$(cat "$CLAUDE_PET_HOME/out1")"
check "always allow passes the rules" '"ruleContent":"rm:*"' "$(cat "$CLAUDE_PET_HOME/out1")"
check "answered → prompt closed" "[Running] infra" "$(state 'infra')"
same "answer file consumed" "" "$(ls "$CLAUDE_PET_HOME/answers")"

hook_bg "$REQ" "$CLAUDE_PET_HOME/out2"
id=$(wait_prompt p1)
echo '{"answer":"allowOnce"}' > "$CLAUDE_PET_HOME/answers/$id.json"
finish_bg
same "allow once → plain allow" '{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}' \
     "$(python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1])),sort_keys=True,separators=(',',':')))" "$CLAUDE_PET_HOME/out2")"

hook_bg "$REQ" "$CLAUDE_PET_HOME/out3"
id=$(wait_prompt p1)
echo '{"answer":"deny"}' > "$CLAUDE_PET_HOME/answers/$id.json"
finish_bg
check "deny → deny decision" '"behavior":"deny"' "$(cat "$CLAUDE_PET_HOME/out3")"

hook_bg "$REQ" "$CLAUDE_PET_HOME/out4"
wait_prompt p1 >/dev/null
hook "{$P,\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf dist\"}}"
finish_bg
same "answered in Claude → hook exits silently" "" "$(cat "$CLAUDE_PET_HOME/out4")"
check "answered in Claude → prompt cleared" "[Running] infra" "$(state 'infra')"

hook_bg "$REQ" "$CLAUDE_PET_HOME/out5"
wait_prompt p1 >/dev/null
hook "{$P,\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"ok\"}"
finish_bg
same "turn ended → waiting hook exits silently" "" "$(cat "$CLAUDE_PET_HOME/out5")"

# --- CLI -----------------------------------------------------------------------
check "/pet off hides" "hidden" "$("$BIN" cmd off)"
check "status reflects hidden" "awake: false" "$("$BIN" status)"
check "/pet status lists sessions" "Fix the login bug" "$("$BIN" cmd status)"
check "unknown /pet word shows usage" "claude-pet —" "$("$BIN" cmd dance 2>&1 | head -1)"
same "unknown /pet word fails" "1" "$("$BIN" cmd dance >/dev/null 2>&1; echo $?)"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
