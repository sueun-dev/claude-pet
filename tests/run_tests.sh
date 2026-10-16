#!/bin/bash
# End-to-end checks for the CLI and the hook state machine, including how permission
# answers are accepted. Builds a test binary (with a `test-answer` command the release
# build doesn't have) and runs it against a throwaway CLAUDE_PET_HOME, so your real
# sessions and menu bar app are never touched.
#   tests/run_tests.sh
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/claude-pet-tests.XXXXXX)"   # short: socket paths are limited to 104 bytes
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/claude-pet"
swiftc -Onone -swift-version 5 -target "$(uname -m)-apple-macos26" -D TESTING \
  -framework AppKit -framework SwiftUI $(find Sources -name "*.swift") -o "$BIN" || exit 1
export CLAUDE_PET_HOME="$TMP/home"

pass=0 fail=0
ok()    { pass=$((pass + 1)); }
bad()   { fail=$((fail + 1)); printf 'FAIL %s\n  expected: %s\n  got: %s\n' "$1" "$2" "$3"; }
check() { [[ "$3" == *"$2"* ]] && ok || bad "$1" "…$2…" "$3"; }   # actual contains expected
same()  { [[ "$3" == "$2" ]] && ok || bad "$1" "$2" "$3"; }        # actual equals expected

hook() {   # feed one event; the hook must exit 0 within 5 s and print nothing
  local out="$TMP/hook.out" pid rc
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
still_waiting() { [ -n "$(jobs -rp)" ] && echo yes || echo no; }
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
request() {   # request <session> <tool> <tool_input JSON> — a PermissionRequest event
  echo "{\"session_id\":\"$1\",\"cwd\":\"/work/$1\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"$2\",\"tool_input\":$3,\"permission_suggestions\":[{\"type\":\"addRules\",\"rules\":[{\"toolName\":\"Bash\",\"ruleContent\":\"rm:*\"}],\"behavior\":\"allow\",\"destination\":\"localSettings\"}]}"
}

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
same "questions are not turned into prompts" "" "$(prompt_id s1)"

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
REQ=$(request p1 Bash '{"command":"rm -rf dist"}')

hook_bg "$REQ" "$TMP/out1"
id=$(wait_prompt p1)
check "prompt is recorded" "[Needs input] p1: Allow Bash?" "$(state 'p1')"
same "prompt shows the whole command" "rm -rf dist" "$(field p1 prompt detail)"
same "prompt is answerable from the menu bar" "True" "$(field p1 prompt answerable)"
same "prompt offers always-allow" "True" "$(field p1 prompt canAlwaysAllow)"
"$BIN" test-answer "$id" allowAlways
finish_bg
check "always allow → allow" '"behavior":"allow"' "$(cat "$TMP/out1")"
check "always allow passes the rules" '"ruleContent":"rm:*"' "$(cat "$TMP/out1")"
check "answered → prompt closed" "[Running] p1" "$(state 'p1')"
same "the socket is removed" "" "$(ls "$CLAUDE_PET_HOME/prompts")"

hook_bg "$REQ" "$TMP/out2"
id=$(wait_prompt p1)
"$BIN" test-answer "$id" allowOnce
finish_bg
same "allow once → plain allow" '{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}' \
     "$(python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1])),sort_keys=True,separators=(',',':')))" "$TMP/out2")"

hook_bg "$REQ" "$TMP/out3"
id=$(wait_prompt p1)
"$BIN" test-answer "$id" deny
finish_bg
check "deny → deny decision" '"behavior":"deny"' "$(cat "$TMP/out3")"

hook_bg "$REQ" "$TMP/out4"
wait_prompt p1 >/dev/null
hook '{"session_id":"p1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf dist"}}'
finish_bg
same "answered in Claude → hook exits silently" "" "$(cat "$TMP/out4")"
check "answered in Claude → prompt cleared" "[Running] p1" "$(state 'p1')"

hook_bg "$REQ" "$TMP/out5"
wait_prompt p1 >/dev/null
hook '{"session_id":"p1","hook_event_name":"Stop","last_assistant_message":"ok"}'
finish_bg
same "turn ended → waiting hook exits silently" "" "$(cat "$TMP/out5")"

# --- only the menu bar app can answer, and only what it showed -----------------
hook_bg "$REQ" "$TMP/out6"
id=$(wait_prompt p1)
python3 - "$CLAUDE_PET_HOME/prompts/$id.sock" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1]); s.sendall(b'{"answer":"allowAlways","tool":"Bash","detail":"rm -rf dist","challenge":""}'); s.close()
PY
echo '{"answer":"allowAlways"}' > "$CLAUDE_PET_HOME/prompts/$id.json"   # what the 1.0.0 file channel read
sleep 0.5
same "an answer from another program is ignored" "yes" "$(still_waiting)"

# Connect, pre-send an answer, then exec Claude Pet so the socket's peer *is* Claude Pet by
# the time the (stopped, then resumed) hook checks it.
hook_pid=$(jobs -rp | tail -1)
python3 - "$hook_pid" "$CLAUDE_PET_HOME/prompts/$id.sock" "$BIN" <<'PY' &
import os, signal, socket, sys, time
hook, path, binary = int(sys.argv[1]), sys.argv[2], sys.argv[3]
os.kill(hook, signal.SIGSTOP)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(path)
s.sendall(b'{"answer":"allowAlways","tool":"Bash","detail":"rm -rf dist","challenge":""}')
s.set_inheritable(True)
r, w = os.pipe(); os.set_inheritable(r, True); os.set_inheritable(w, True); os.dup2(r, 0)
if os.fork() == 0:
    time.sleep(0.3); os.kill(hook, signal.SIGCONT); os._exit(0)
os.execv(binary, [binary, "hook"])   # stays alive, blocked on a stdin that never ends
PY
attacker=$!
sleep 2
same "a process that turns into Claude Pet after connecting is ignored" "yes" "$(kill -0 "$hook_pid" 2>/dev/null && echo yes || echo no)"
kill "$attacker" 2>/dev/null; wait "$attacker" 2>/dev/null

session="$CLAUDE_PET_HOME/sessions/p1.json"
cp "$session" "$TMP/real.json"
python3 - "$session" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["prompt"]["detail"] = "ls"; json.dump(d, open(sys.argv[1], "w"))
PY
same "a click on a tampered request is refused" "1" "$("$BIN" test-answer "$id" allowOnce >/dev/null 2>&1; echo $?)"
same "…and the hook keeps waiting" "yes" "$(kill -0 "$hook_pid" 2>/dev/null && echo yes || echo no)"
cp "$TMP/real.json" "$session"
"$BIN" test-answer "$id" deny
finish_bg
check "…while the real answer still gets through" '"behavior":"deny"' "$(cat "$TMP/out6")"
same "release builds cannot answer from the command line" "1" \
     "$(scripts/build.sh >/dev/null && build/ClaudePet.app/Contents/MacOS/claude-pet test-answer "$id" allowOnce >/dev/null 2>&1; echo $?)"

# --- requests the panel can't show in full go to Claude ----------------------
hook "$(request p2 Bash '{"command":"echo hi                                         ; rm -rf ~"}')"
same "padded command → not answerable (hook did not wait)" "False" "$(field p2 prompt answerable)"
hook "$(request p3 Bash '{"command":"echo safe‮;rm -rf ~"}')"
same "invisible formatting character → not answerable" "False" "$(field p3 prompt answerable)"
hook "$(request p4 Bash "{\"command\":\"$(printf 'x%.0s' {1..450})\"}")"
same "very long command → not answerable" "False" "$(field p4 prompt answerable)"
hook "$(request p5 mcp__github__create_issue '{"title":"x","body":"y"}')"
same "tool whose input isn't shown → not answerable" "False" "$(field p5 prompt answerable)"
hook "$(request p7 Edit '{"file_path":"/work/app.ts","old_string":"a","new_string":"b"}')"
same "edit (diff not shown) → not answerable" "False" "$(field p7 prompt answerable)"
check "…but the file is still shown" "/work/app.ts" "$(field p7 prompt detail)"
"$BIN" sleep >/dev/null
hook "$(request p6 Bash '{"command":"ls"}')"
same "hidden menu bar item → not answerable (hook did not wait)" "False" "$(field p6 prompt answerable)"

# --- files stay private ---------------------------------------------------------
same "state folder is owner-only" "700" "$(stat -f %Lp "$CLAUDE_PET_HOME")"
same "session files are owner-only" "600" "$(stat -f %Lp "$CLAUDE_PET_HOME/sessions/s1.json")"

# --- CLI -----------------------------------------------------------------------
check "/pet on shows" "is on" "$("$BIN" cmd on)"
check "/pet off hides" "hidden" "$("$BIN" cmd off)"
check "status reflects hidden" "awake: false" "$("$BIN" status)"
check "/pet status lists sessions" "Fix the login bug" "$("$BIN" cmd status)"
check "unknown /pet word shows usage" "claude-pet —" "$("$BIN" cmd dance 2>&1 | head -1)"
same "unknown /pet word fails" "1" "$("$BIN" cmd dance >/dev/null 2>&1; echo $?)"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
