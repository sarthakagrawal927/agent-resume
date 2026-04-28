#!/bin/bash
# test.sh — Test suite for agent-resume.sh
# Pure bash. No external test libs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/agent-resume.sh"

# ============================================================================
# Test framework
# ============================================================================

pass=0
fail=0
total=0

group() { echo ""; echo "--- $1 ---"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  total=$((total + 1))
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"; pass=$((pass + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: '$expected'"
    echo "    actual:   '$actual'"
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  total=$((total + 1))
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $desc"; pass=$((pass + 1))
  else
    echo "  FAIL: $desc"
    echo "    output missing: '$needle'"
    echo "    output: '${haystack:0:200}'"
    fail=$((fail + 1))
  fi
}

assert_match() {
  local desc="$1" haystack="$2" pattern="$3"
  total=$((total + 1))
  if echo "$haystack" | grep -qE "$pattern"; then
    echo "  PASS: $desc"; pass=$((pass + 1))
  else
    echo "  FAIL: $desc"
    echo "    pattern: '$pattern'"
    echo "    output: '${haystack:0:200}'"
    fail=$((fail + 1))
  fi
}

assert_exit() {
  local desc="$1" expected="$2"; shift 2
  total=$((total + 1))
  set +e
  "$@" >/dev/null 2>&1
  local actual=$?
  set -e
  if [ "$actual" -eq "$expected" ]; then
    echo "  PASS: $desc"; pass=$((pass + 1))
  else
    echo "  FAIL: $desc — expected $expected, got $actual"
    fail=$((fail + 1))
  fi
}

# ============================================================================
# Source functions via TEST_MODE
# ============================================================================

source_functions() {
  VERSION=""; CONTINUE=""; LOOP=""; CASCADE=""; SKIP_PERMS=""
  PROMPT=""; SUBCOMMAND=""
  QUEUE_MAX_RETRIES=""; QUEUE_MAX_TURNS=""; QUEUE_ISSUE_IDS=""
  QUEUE_FILTERS=()
  AGENT_REGISTRY=()
  TEST_MODE=1 source "$SCRIPT"
}
source_functions

echo "agent-resume test suite"
echo "========================"

# ============================================================================
# 1. CLI arg parsing
# ============================================================================

group "CLI arg parsing"

assert_exit "--help exits 0" 0 bash "$SCRIPT" --help
assert_exit "--version exits 0" 0 bash "$SCRIPT" --version

out=$(bash "$SCRIPT" --version 2>&1)
assert_contains "--version prints version" "$out" "agent-resume v"

assert_exit "unknown flag errors" 1 bash "$SCRIPT" --bogus

out=$(bash "$SCRIPT" --help 2>&1)
assert_contains "--help has USAGE" "$out" "USAGE"
assert_contains "--help mentions queue" "$out" "queue"
assert_contains "--help mentions status" "$out" "status"
assert_contains "--help mentions --loop" "$out" "--loop"
assert_contains "--help mentions --skip-permissions" "$out" "--skip-permissions"

# No prompt + no -c → error
set +e
out=$(bash "$SCRIPT" 2>&1)
ret=$?
set -e
assert_eq "no prompt exits non-zero" "1" "$ret"
assert_contains "no prompt shows usage" "$out" "No prompt provided"

# Removed flags must not work
assert_exit "--order is rejected" 1 bash "$SCRIPT" --order gemini "test"
assert_exit "--model is rejected" 1 bash "$SCRIPT" --model opus "test"
assert_exit "--resume is rejected" 1 bash "$SCRIPT" --resume abc "test"
assert_exit "--permission-mode rejected" 1 bash "$SCRIPT" --permission-mode auto "test"
assert_exit "--log is rejected" 1 bash "$SCRIPT" --log /tmp/x "test"
assert_exit "--test is rejected" 1 bash "$SCRIPT" --test 5 "test"

# ============================================================================
# 2. parse_reset_time()
# ============================================================================

group "parse_reset_time()"

out=$(parse_reset_time "Claude AI usage limit reached|1700000000")
assert_eq "unix pipe format extracts ts" "1700000000" "$out"

out=$(parse_reset_time "Claude AI usage limit reached|1700000123|extra")
assert_eq "unix pipe extracts first ts" "1700000123" "$out"

out=$(parse_reset_time "Your limit reached, resets 9am")
ret=$?
assert_eq "12h '9am' parses" "0" "$ret"
assert_match "12h '9am' is numeric" "$out" "^[0-9]+$"

out=$(parse_reset_time "limit, resets 12:30pm")
ret=$?
assert_eq "12h '12:30pm' parses" "0" "$ret"

out=$(parse_reset_time "resets 3pm (America/New_York)")
ret=$?
assert_eq "tz-aware '3pm (NY)' parses" "0" "$ret"

set +e
out=$(parse_reset_time "no time info here")
ret=$?
set -e
assert_eq "no time info exits 1" "1" "$ret"

# ============================================================================
# 3. is_agent_rate_limited()
# ============================================================================

group "is_agent_rate_limited()"

find_entry() {
  local target="$1"
  for e in "${AGENT_REGISTRY[@]}"; do
    [ "$(reg_name "$e")" = "$target" ] && { echo "$e"; return 0; }
  done
  return 1
}

claude_entry="$(find_entry claude-opus)"
gemini_entry="$(find_entry gemini)"
codex_entry="$(find_entry codex)"

set +e
is_agent_rate_limited "Claude AI usage limit reached" "$claude_entry"; r=$?
set -e
assert_eq "Claude detects 'usage limit reached'" "0" "$r"

set +e
is_agent_rate_limited "Hello, normal output" "$claude_entry"; r=$?
set -e
assert_eq "Claude no-match on normal output" "1" "$r"

set +e
is_agent_rate_limited "Error 429: too many requests" "$gemini_entry"; r=$?
set -e
assert_eq "Gemini detects '429'" "0" "$r"

set +e
is_agent_rate_limited "RESOURCE_EXHAUSTED" "$gemini_entry"; r=$?
set -e
assert_eq "Gemini detects 'RESOURCE_EXHAUSTED'" "0" "$r"

set +e
is_agent_rate_limited "rate_limit_exceeded" "$codex_entry"; r=$?
set -e
assert_eq "Codex detects 'rate_limit_exceeded'" "0" "$r"

# ============================================================================
# 4. Registry helpers
# ============================================================================

group "Registry helpers"

assert_eq "reg_name parses claude-opus" "claude-opus" "$(reg_name "$claude_entry")"
assert_eq "reg_cli parses claude" "claude" "$(reg_cli "$claude_entry")"
assert_match "reg_tier numeric" "$(reg_tier "$claude_entry")" "^[0-9]+$"
assert_eq "Gemini cli is gemini" "gemini" "$(reg_cli "$gemini_entry")"
assert_eq "Gemini tier is 1" "1" "$(reg_tier "$gemini_entry")"

# get_cascade_order returns all entries
count=$(get_cascade_order | wc -l | tr -d ' ')
assert_eq "cascade order has all entries" "${#AGENT_REGISTRY[@]}" "$count"

# ============================================================================
# 5. fmt_time()
# ============================================================================

group "fmt_time()"

out=$(fmt_time 1700000000)
assert_match "fmt_time HH:MM:SS" "$out" "^[0-9]{2}:[0-9]{2}:[0-9]{2}$"

out=$(fmt_time 0)
assert_match "fmt_time epoch 0 HH:MM:SS" "$out" "^[0-9]{2}:[0-9]{2}:[0-9]{2}$"

# ============================================================================
# 6. build_cmd()
# ============================================================================

group "build_cmd()"

# Claude with default flags
SKIP_PERMS=false; CONTINUE=false
out=$(build_cmd "$claude_entry" "test prompt" | tr '\0' ' ')
assert_contains "Claude cmd starts with claude" "$out" "claude"
assert_contains "Claude cmd has --skip-git-repo-check" "$out" "--skip-git-repo-check"
assert_contains "Claude cmd has --model opus" "$out" "--model opus"
assert_contains "Claude cmd has -p" "$out" "-p"
assert_contains "Claude cmd ends with prompt" "$out" "test prompt"

# Claude with --skip-permissions
SKIP_PERMS=true
out=$(build_cmd "$claude_entry" "x" | tr '\0' ' ')
assert_contains "Claude --skip-permissions adds dangerous flag" "$out" "--dangerously-skip-permissions"
SKIP_PERMS=false

# Claude with -c
CONTINUE=true
out=$(build_cmd "$claude_entry" "x" | tr '\0' ' ')
assert_contains "Claude -c flag injected" "$out" "-c"
CONTINUE=false

# Gemini cmd has no Claude-specific flags
out=$(build_cmd "$gemini_entry" "test" | tr '\0' ' ')
assert_contains "Gemini cmd starts with gemini" "$out" "gemini"
set +e
echo "$out" | grep -q -- "--dangerously-skip-permissions"; r=$?
set -e
assert_eq "Gemini cmd has no Claude-only flags" "1" "$r"

# Codex gets --skip-git-repo-check
out=$(build_cmd "$codex_entry" "test" | tr '\0' ' ')
assert_contains "Codex cmd has --skip-git-repo-check" "$out" "--skip-git-repo-check"
assert_contains "Codex cmd has exec" "$out" "exec"

# Multi-line prompt is preserved as a single arg (NUL-separated output)
multiline=$'line1\nline2\nline3'
parts=()
while IFS= read -r -d '' p; do parts+=("$p"); done < <(build_cmd "$gemini_entry" "$multiline")
last="${parts[${#parts[@]}-1]}"
assert_eq "multi-line prompt stays one arg" "$multiline" "$last"

# ============================================================================
# 7. Subcommand routing
# ============================================================================

group "Subcommand routing"

assert_exit "queue --help exits 0" 0 bash "$SCRIPT" queue --help
out=$(bash "$SCRIPT" queue --help 2>&1)
assert_contains "queue --help has USAGE" "$out" "USAGE"
assert_contains "queue --help has --issue" "$out" "--issue"
assert_contains "queue --help has --label" "$out" "--label"

# queue create removed
set +e
out=$(bash "$SCRIPT" queue create 2>&1)
ret=$?
set -e
assert_eq "queue create exits non-zero" "1" "$ret"
assert_contains "queue create error mentions removal" "$out" "removed"

# unknown queue option
set +e
bash "$SCRIPT" queue --bogus 2>&1 >/dev/null
ret=$?
set -e
assert_eq "queue --bogus exits non-zero" "1" "$ret"

# Removed subcommands no longer route — they fall through as prompts.
# We don't assert exit codes here because they'd invoke real agents.
# Just verify the help text doesn't mention them.
out=$(bash "$SCRIPT" --help 2>&1)
set +e
echo "$out" | grep -qE '\bdelegate\b'; r1=$?
echo "$out" | grep -qE '\btasks\b'; r2=$?
set -e
assert_eq "help no longer mentions delegate" "1" "$r1"
assert_eq "help no longer mentions tasks" "1" "$r2"

# ============================================================================
# 8. queue_build_prompt()
# ============================================================================

group "queue_build_prompt()"

prompt=$(queue_build_prompt "42")
assert_contains "build_prompt mentions issue number" "$prompt" "gh issue view 42"
assert_contains "build_prompt has NO_CODE marker" "$prompt" "AGENT_RESUME_NO_CODE"
assert_contains "build_prompt has SUMMARY marker" "$prompt" "AGENT_RESUME_SUMMARY"
assert_contains "build_prompt forbids commits" "$prompt" "Do NOT create git commits"

# .agent-resume custom instructions
TMPDIR_TEST=$(mktemp -d)
pushd "$TMPDIR_TEST" >/dev/null
echo "Always run pnpm test" > .agent-resume
prompt=$(queue_build_prompt "1")
assert_contains "build_prompt includes .agent-resume content" "$prompt" "Always run pnpm test"
popd >/dev/null
rm -rf "$TMPDIR_TEST"

# ============================================================================
# 9. queue_fetch_specific id parsing
# ============================================================================

group "queue id parsing"

# Parse number from URL-style input via the same regex used in queue_fetch_specific
out=$(echo "https://github.com/owner/repo/issues/42" | grep -oE '[0-9]+$')
assert_eq "URL issue id extracted" "42" "$out"

out=$(echo "42" | grep -oE '[0-9]+$')
assert_eq "Bare number id extracted" "42" "$out"

out=$(echo "abc" | grep -oE '[0-9]+$' || echo "")
assert_eq "Non-numeric id is empty" "" "$out"

# ============================================================================
# 10. Defaults & globals
# ============================================================================

group "Defaults"

source_functions
assert_eq "VERSION is 3.0.0" "3.0.0" "$VERSION"
assert_eq "CONTINUE defaults false" "false" "$CONTINUE"
assert_eq "LOOP defaults false" "false" "$LOOP"
assert_eq "CASCADE defaults true" "true" "$CASCADE"
assert_eq "SKIP_PERMS defaults false" "false" "$SKIP_PERMS"
assert_eq "QUEUE_MAX_RETRIES defaults 3" "3" "$QUEUE_MAX_RETRIES"
assert_eq "QUEUE_MAX_TURNS defaults 50" "50" "$QUEUE_MAX_TURNS"
assert_eq "AGENT_REGISTRY non-empty" "true" "$([ ${#AGENT_REGISTRY[@]} -gt 0 ] && echo true || echo false)"

# die exits with custom code
set +e
out=$(die "boom" 42 2>&1)
ret=$?
set -e
assert_eq "die exits with custom code" "42" "$ret"
assert_contains "die prints error" "$out" "Error: boom"

# info prints with :: prefix
out=$(info "hello")
assert_eq "info prefix" ":: hello" "$out"

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "========================"
echo "Results: $pass passed, $fail failed, $total total"
echo "========================"

[ "$fail" -eq 0 ] && exit 0 || exit 1
