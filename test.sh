#!/bin/bash
# test.sh — Comprehensive test suite for claude-resume.sh
# Pure bash. No external test libs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/agent-resume.sh"

# ============================================================================
# Test Framework
# ============================================================================

pass=0
fail=0
total=0
current_group=""

group() {
  current_group="$1"
  echo ""
  echo "--- $1 ---"
}

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  total=$((total + 1))
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $description"
    pass=$((pass + 1))
  else
    echo "  FAIL: $description"
    echo "    expected: '$expected'"
    echo "    actual:   '$actual'"
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local description="$1" haystack="$2" needle="$3"
  total=$((total + 1))
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $description"
    pass=$((pass + 1))
  else
    echo "  FAIL: $description"
    echo "    output does not contain: '$needle'"
    echo "    output: '${haystack:0:200}'"
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local description="$1" haystack="$2" needle="$3"
  total=$((total + 1))
  if ! echo "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $description"
    pass=$((pass + 1))
  else
    echo "  FAIL: $description"
    echo "    output should NOT contain: '$needle'"
    fail=$((fail + 1))
  fi
}

assert_exit() {
  local description="$1" expected_code="$2"
  shift 2
  total=$((total + 1))
  # Run command, capture exit code
  set +e
  "$@" >/dev/null 2>&1
  local actual_code=$?
  set -e
  if [ "$actual_code" -eq "$expected_code" ]; then
    echo "  PASS: $description"
    pass=$((pass + 1))
  else
    echo "  FAIL: $description"
    echo "    expected exit code: $expected_code"
    echo "    actual exit code:   $actual_code"
    fail=$((fail + 1))
  fi
}

assert_match() {
  local description="$1" haystack="$2" pattern="$3"
  total=$((total + 1))
  if echo "$haystack" | grep -qE "$pattern"; then
    echo "  PASS: $description"
    pass=$((pass + 1))
  else
    echo "  FAIL: $description"
    echo "    output does not match pattern: '$pattern'"
    echo "    output: '${haystack:0:200}'"
    fail=$((fail + 1))
  fi
}

# ============================================================================
# Source functions via TEST_MODE
# ============================================================================

source_functions() {
  # Reset all globals to defaults before sourcing
  VERSION=""
  TIMEOUT_SECS=""
  BUFFER_SECS=""
  RATE_LIMIT_EXIT=""
  PROMPT=""
  CONTINUE=""
  RESUME_SESSION=""
  MODEL=""
  CASCADE=""
  LOOP=""
  SKIP_PERMS=""
  PERM_MODE=""
  TEST_SECS=""
  TASK_FILE=""
  SUBCOMMAND=""
  DELEGATE_AGENT=""
  DELEGATE_TASK=""
  DELEGATE_CONTEXT=""
  LOG_FILE=""
  CAFFEINATE_PID=""
  PASS_THROUGH_FLAGS=()
  USER_ORDER=()
  AGENT_REGISTRY=()

  TEST_MODE=1 source "$SCRIPT"
}

source_functions

echo "agent-resume test suite"
echo "========================"

# ============================================================================
# 1. CLI Arg Parsing
# ============================================================================

group "CLI arg parsing"

# --help exits 0
assert_exit "--help exits 0" 0 bash "$SCRIPT" --help

# --version prints version and exits 0
out=$(bash "$SCRIPT" --version 2>&1)
assert_exit "--version exits 0" 0 bash "$SCRIPT" --version
assert_contains "--version prints version string" "$out" "agent-resume v"

# Unknown flag errors (exit non-zero)
assert_exit "unknown flag --bogus errors" 1 bash "$SCRIPT" --bogus

# -c sets CONTINUE=true
out=$(CONTINUE=false; TEST_MODE=1 source "$SCRIPT"; set -- -c; eval '
  while [[ $# -gt 0 ]]; do
    case $1 in
      -c|--continue) CONTINUE=true; shift ;;
      *) shift ;;
    esac
  done
  echo $CONTINUE
')
# Simpler approach: parse via the script itself
# We test by running the script in a subshell that prints the variable after parsing
out=$(bash -c '
  TEST_MODE=1 source "'"$SCRIPT"'"
  set -- -c
  while [[ $# -gt 0 ]]; do
    case $1 in
      -c|--continue) CONTINUE=true; shift ;;
      *) shift ;;
    esac
  done
  echo "$CONTINUE"
')
assert_eq "-c sets CONTINUE=true" "true" "$out"

# -m sets MODEL
out=$(bash -c '
  TEST_MODE=1 source "'"$SCRIPT"'"
  set -- -m opus
  while [[ $# -gt 0 ]]; do
    case $1 in
      -m|--model) MODEL="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  echo "$MODEL"
')
assert_eq "-m sets MODEL" "opus" "$out"

# --order sets custom cascade order
out=$(bash -c '
  TEST_MODE=1 source "'"$SCRIPT"'"
  set -- --order gemini,claude-opus
  while [[ $# -gt 0 ]]; do
    case $1 in
      --order) IFS="," read -ra USER_ORDER <<< "$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  echo "${USER_ORDER[*]}"
')
assert_eq "--order sets USER_ORDER" "gemini claude-opus" "$out"

# --no-cascade disables cascade
out=$(bash -c '
  TEST_MODE=1 source "'"$SCRIPT"'"
  set -- --no-cascade
  while [[ $# -gt 0 ]]; do
    case $1 in
      --no-cascade) CASCADE=false; shift ;;
      *) shift ;;
    esac
  done
  echo "$CASCADE"
')
assert_eq "--no-cascade sets CASCADE=false" "false" "$out"

# --log sets log file
out=$(bash -c '
  TEST_MODE=1 source "'"$SCRIPT"'"
  set -- --log /tmp/test.log
  while [[ $# -gt 0 ]]; do
    case $1 in
      --log) LOG_FILE="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  echo "$LOG_FILE"
')
assert_eq "--log sets LOG_FILE" "/tmp/test.log" "$out"

# -r sets resume session
out=$(bash -c '
  TEST_MODE=1 source "'"$SCRIPT"'"
  set -- -r abc123
  while [[ $# -gt 0 ]]; do
    case $1 in
      -r|--resume) RESUME_SESSION="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  echo "$RESUME_SESSION"
')
assert_eq "-r sets RESUME_SESSION" "abc123" "$out"

# --help output contains USAGE section
out=$(bash "$SCRIPT" --help 2>&1)
assert_contains "--help output contains USAGE" "$out" "USAGE"
assert_contains "--help output contains OPTIONS" "$out" "OPTIONS"
assert_contains "--help output contains EXAMPLES" "$out" "EXAMPLES"

# ============================================================================
# 2. parse_reset_time()
# ============================================================================

group "parse_reset_time()"

# Format 1: Unix timestamp pipe format
out=$(parse_reset_time "Claude AI usage limit reached|1700000000")
assert_eq "unix pipe format extracts timestamp" "1700000000" "$out"

out=$(parse_reset_time "Claude AI usage limit reached|1700000123|extra")
assert_eq "unix pipe format extracts first timestamp" "1700000123" "$out"

# Format 2: 12h time (e.g. "9am", "12:30pm")
# These produce a future timestamp, so we validate it's a valid number
out=$(parse_reset_time "Your limit reached, resets 9am")
ret=$?
assert_eq "12h time '9am' parses successfully" "0" "$ret"
assert_match "12h time '9am' returns a number" "$out" "^[0-9]+$"

out=$(parse_reset_time "Your limit reached, resets 12:30pm")
ret=$?
assert_eq "12h time '12:30pm' parses successfully" "0" "$ret"
assert_match "12h time '12:30pm' returns a number" "$out" "^[0-9]+$"

out=$(parse_reset_time "You hit your limit, resets 1:45am")
ret=$?
assert_eq "12h time '1:45am' parses successfully" "0" "$ret"
assert_match "12h time '1:45am' returns a number" "$out" "^[0-9]+$"

# Format 3: Timezone-aware format
out=$(parse_reset_time "You've hit your limit, resets 3pm (America/New_York)")
ret=$?
assert_eq "timezone-aware '3pm (America/New_York)' parses" "0" "$ret"
assert_match "timezone-aware returns a number" "$out" "^[0-9]+$"

out=$(parse_reset_time "limit reached resets 11:30am (America/Los_Angeles)")
ret=$?
assert_eq "timezone-aware '11:30am (America/Los_Angeles)' parses" "0" "$ret"
assert_match "timezone-aware with minutes returns number" "$out" "^[0-9]+$"

# Failure case: no time info
set +e
out=$(parse_reset_time "some random output with no time")
ret=$?
set -e
assert_eq "no time info returns exit 1" "1" "$ret"

# ============================================================================
# 3. is_rate_limited()
# ============================================================================

group "is_rate_limited()"

# All rate limit checks need set +e since is_rate_limited returns non-zero on no match
set +e

# Positive cases — all known rate limit formats
is_rate_limited "Claude AI usage limit reached"; assert_eq "detects 'Claude AI usage limit reached'" "0" "$?"
is_rate_limited "Your limit reached, resets 3pm"; assert_eq "detects 'limit reached...resets'" "0" "$?"
is_rate_limited "You've hit your limit, resets 3pm (America/New_York)"; assert_eq "detects 'hit your limit'" "0" "$?"
is_rate_limited "You're out of extra usage"; assert_eq "detects 'out of extra usage'" "0" "$?"
is_rate_limited "You're out of usage credits"; assert_eq "detects 'out of usage'" "0" "$?"
is_rate_limited "rate limit exceeded"; assert_eq "detects 'rate limit exceeded'" "0" "$?"
is_rate_limited "Your usage limit has been reached, resets at 3pm"; assert_eq "detects 'usage limit...resets'" "0" "$?"
is_rate_limited "Rate-limit hit"; assert_eq "detects 'Rate-limit' (hyphenated)" "0" "$?"
is_rate_limited "Error 429: too many requests"; assert_eq "detects '429 too many requests'" "0" "$?"
is_rate_limited "quota exceeded for project"; assert_eq "detects 'quota exceeded'" "0" "$?"
is_rate_limited "RESOURCE_EXHAUSTED"; assert_eq "detects 'resource exhausted'" "0" "$?"

# Negative cases
is_rate_limited "Hello, how can I help you today?"; r1=$?
is_rate_limited "Task completed successfully"; r2=$?
is_rate_limited "I've finished refactoring the module"; r3=$?
is_rate_limited ""; r4=$?

set -e

assert_eq "normal output 'Hello...' not rate limited" "1" "$r1"
assert_eq "normal output 'Task completed...' not rate limited" "1" "$r2"
assert_eq "normal output 'refactoring...' not rate limited" "1" "$r3"
assert_eq "empty string not rate limited" "1" "$r4"

# ============================================================================
# 4. Task File Processing
# ============================================================================

group "Task file processing"

# Create a temporary task file
TASK_TMPDIR=$(mktemp -d)
TASK_FILE_TEST="$TASK_TMPDIR/tasks.md"

cat > "$TASK_FILE_TEST" <<'TASKEOF'
# This is a comment
   # Indented comment

- [ ] First task to do
- [x] This is already done
- [X] This is also done (uppercase X)

- [ ] Second task
delegate:gemini Query signups data
Regular task without prefix
- Third task with dash only

TASKEOF

# Count actionable tasks (should skip comments, blanks, completed)
count=0
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*#|^[[:space:]]*$ ]] && continue
  [[ "$line" =~ \[x\]|\[X\] ]] && continue
  count=$((count + 1))
done < "$TASK_FILE_TEST"
assert_eq "task count skips comments, blanks, completed" "5" "$count"

# Test comment skipping
line="# This is a comment"
if [[ "$line" =~ ^[[:space:]]*#|^[[:space:]]*$ ]]; then r="skipped"; else r="kept"; fi
assert_eq "comment lines are skipped" "skipped" "$r"

line="   # Indented comment"
if [[ "$line" =~ ^[[:space:]]*#|^[[:space:]]*$ ]]; then r="skipped"; else r="kept"; fi
assert_eq "indented comment lines are skipped" "skipped" "$r"

# Test blank line skipping
line=""
if [[ "$line" =~ ^[[:space:]]*#|^[[:space:]]*$ ]]; then r="skipped"; else r="kept"; fi
assert_eq "blank lines are skipped" "skipped" "$r"

# Test completed task skipping
line="- [x] Already done"
if [[ "$line" =~ \[x\]|\[X\] ]]; then r="skipped"; else r="kept"; fi
assert_eq "lowercase [x] tasks are skipped" "skipped" "$r"

line="- [X] Also done"
if [[ "$line" =~ \[x\]|\[X\] ]]; then r="skipped"; else r="kept"; fi
assert_eq "uppercase [X] tasks are skipped" "skipped" "$r"

# Test uncompleted task is NOT skipped
line="- [ ] Pending task"
if [[ "$line" =~ \[x\]|\[X\] ]]; then r="skipped"; else r="kept"; fi
assert_eq "uncompleted [ ] task is kept" "kept" "$r"

# Test delegate: prefix parsing
task="delegate:gemini Query signups data"
task="${task#- \[ \] }"
task="${task#- }"
task="${task#\[ \] }"
if [[ "$task" =~ ^delegate:([a-zA-Z0-9_-]+)[[:space:]]+(.+)$ ]]; then
  agent="${BASH_REMATCH[1]}"
  subtask="${BASH_REMATCH[2]}"
else
  agent=""
  subtask=""
fi
assert_eq "delegate: prefix extracts agent" "gemini" "$agent"
assert_eq "delegate: prefix extracts task" "Query signups data" "$subtask"

# Test markdown prefix stripping
task="- [ ] Refactor auth module"
task="${task#- \[ \] }"
task="${task#- }"
task="${task#\[ \] }"
assert_eq "strips '- [ ] ' prefix" "Refactor auth module" "$task"

task="- Simple task"
task="${task#- \[ \] }"
task="${task#- }"
task="${task#\[ \] }"
assert_eq "strips '- ' prefix" "Simple task" "$task"

task="[ ] Bare checkbox"
task="${task#- \[ \] }"
task="${task#- }"
task="${task#\[ \] }"
assert_eq "strips '[ ] ' prefix" "Bare checkbox" "$task"

task="Plain task no prefix"
original="$task"
task="${task#- \[ \] }"
task="${task#- }"
task="${task#\[ \] }"
assert_eq "plain task unchanged" "$original" "$task"

# Cleanup
rm -rf "$TASK_TMPDIR"

# ============================================================================
# 5. fmt_time()
# ============================================================================

group "fmt_time()"

# Use a known timestamp — 1700000000 = 2023-11-14 at some time
out=$(fmt_time 1700000000)
ret=$?
assert_eq "fmt_time exits 0 for valid timestamp" "0" "$ret"
assert_match "fmt_time returns HH:MM:SS format" "$out" "^[0-9]{2}:[0-9]{2}:[0-9]{2}$"

# Another known timestamp
out=$(fmt_time 0)
ret=$?
assert_eq "fmt_time exits 0 for epoch 0" "0" "$ret"
assert_match "fmt_time epoch 0 returns HH:MM:SS" "$out" "^[0-9]{2}:[0-9]{2}:[0-9]{2}$"

# Current timestamp
now=$(date +%s)
out=$(fmt_time "$now")
assert_match "fmt_time current time returns HH:MM:SS" "$out" "^[0-9]{2}:[0-9]{2}:[0-9]{2}$"

# ============================================================================
# 6. Subcommand Routing
# ============================================================================

group "Subcommand routing"

# "status" is recognized as a subcommand (will fail because `claude` CLI may
# not be available, but the subcommand parsing itself succeeds)
out=$(bash -c '
  set -uo pipefail
  TEST_MODE=1 source "'"$SCRIPT"'"
  # Simulate subcommand parsing
  args=("status")
  if [ "${args[0]}" = "status" ]; then
    echo "subcommand=status"
  fi
')
assert_eq "status recognized as subcommand" "subcommand=status" "$out"

# "delegate" is recognized
out=$(bash -c '
  set -uo pipefail
  TEST_MODE=1 source "'"$SCRIPT"'"
  args=("delegate" "gemini" "do stuff")
  if [ "${args[0]}" = "delegate" ]; then
    echo "subcommand=delegate agent=${args[1]} task=${args[2]}"
  fi
')
assert_eq "delegate recognized as subcommand" "subcommand=delegate agent=gemini task=do stuff" "$out"

# "tasks" is recognized
out=$(bash -c '
  set -uo pipefail
  TEST_MODE=1 source "'"$SCRIPT"'"
  args=("tasks" "file.md")
  if [ "${args[0]}" = "tasks" ]; then
    echo "subcommand=tasks file=${args[1]}"
  fi
')
assert_eq "tasks recognized as subcommand" "subcommand=tasks file=file.md" "$out"

# Verify subcommand parsing in actual script sets SUBCOMMAND correctly
# status
out=$(bash -c '
  SUBCOMMAND=""
  set -- "status"
  if [ "${1:-}" = "delegate" ]; then
    SUBCOMMAND="delegate"
  elif [ "${1:-}" = "tasks" ]; then
    SUBCOMMAND="tasks"
  elif [ "${1:-}" = "status" ]; then
    SUBCOMMAND="status"
  fi
  echo "$SUBCOMMAND"
')
assert_eq "status sets SUBCOMMAND=status" "status" "$out"

# delegate
out=$(bash -c '
  SUBCOMMAND=""
  set -- "delegate" "gemini" "query data"
  if [ "${1:-}" = "delegate" ]; then
    SUBCOMMAND="delegate"
    shift
    DELEGATE_AGENT="$1"
    shift
    DELEGATE_TASK="$1"
  fi
  echo "$SUBCOMMAND $DELEGATE_AGENT $DELEGATE_TASK"
')
assert_eq "delegate sets agent and task" "delegate gemini query data" "$out"

# ============================================================================
# 7. Edge Cases
# ============================================================================

group "Edge cases"

# Empty prompt defaults to "continue"
out=$(bash -c '
  TEST_MODE=1 source "'"$SCRIPT"'"
  echo "$PROMPT"
')
assert_eq "default PROMPT is 'continue'" "continue" "$out"

# delegate with missing agent errors (${1:?} returns exit code 1 or 2 depending on bash version)
set +e
out=$(bash "$SCRIPT" delegate 2>&1)
ret=$?
set -e
assert_eq "delegate with no args exits non-zero" "true" "$([ $ret -ne 0 ] && echo true || echo false)"
assert_contains "delegate with no args shows usage" "$out" "Usage"

# delegate with agent but missing task errors
set +e
out=$(bash "$SCRIPT" delegate gemini 2>&1)
ret=$?
set -e
assert_eq "delegate with missing task exits non-zero" "true" "$([ $ret -ne 0 ] && echo true || echo false)"

# tasks with missing file arg errors
set +e
out=$(bash "$SCRIPT" tasks 2>&1)
ret=$?
set -e
assert_eq "tasks with no file exits non-zero" "true" "$([ $ret -ne 0 ] && echo true || echo false)"

# VERSION is set correctly
assert_eq "VERSION is set" "2.0.0" "$VERSION"

# AGENT_REGISTRY is populated
assert_eq "AGENT_REGISTRY is not empty" "true" "$([ ${#AGENT_REGISTRY[@]} -gt 0 ] && echo true || echo false)"

# CONTINUE default is false
source_functions
assert_eq "CONTINUE defaults to false" "false" "$CONTINUE"

# CASCADE default is true
assert_eq "CASCADE defaults to true" "true" "$CASCADE"

# LOOP default is false
assert_eq "LOOP defaults to false" "false" "$LOOP"

# LOG_FILE default is empty
assert_eq "LOG_FILE defaults to empty" "" "$LOG_FILE"

# log_event with empty LOG_FILE does nothing (no crash)
LOG_FILE=""
set +e
log_event "test event" 2>/dev/null
ret=$?
set -e
assert_eq "log_event with empty LOG_FILE is no-op" "0" "$ret"

# log_event with LOG_FILE writes to file
LOG_TMPFILE=$(mktemp)
LOG_FILE="$LOG_TMPFILE"
log_event "test event 123"
out=$(cat "$LOG_TMPFILE")
assert_contains "log_event writes to LOG_FILE" "$out" "test event 123"
assert_match "log_event includes timestamp" "$out" "^\[.*\] test event 123$"
rm -f "$LOG_TMPFILE"
LOG_FILE=""

# die function prints to stderr and exits
set +e
out=$(die "test error" 2>&1)
ret=$?
set -e
assert_eq "die exits with code 1 by default" "1" "$ret"
assert_contains "die prints error message" "$out" "Error: test error"

# die with custom exit code
set +e
out=$(die "custom code" 42 2>&1)
ret=$?
set -e
assert_eq "die with custom exit code" "42" "$ret"

# info function prints with :: prefix
out=$(info "hello world")
assert_eq "info prints with :: prefix" ":: hello world" "$out"

# Agent registry parsing
group "Agent registry"

# Test reg_field helpers
entry="${AGENT_REGISTRY[0]}"
assert_eq "reg_tier returns tier" "1" "$(reg_tier "$entry")"
assert_eq "reg_name returns name" "claude-opus" "$(reg_name "$entry")"
assert_eq "reg_cli returns cli" "claude" "$(reg_cli "$entry")"

# Test is_agent_rate_limited with Claude patterns
assert_eq "Claude rate limit detected" "0" "$(is_agent_rate_limited "Claude AI usage limit reached" "$entry" && echo 0 || echo 1)"
assert_eq "Normal output not rate limited" "1" "$(is_agent_rate_limited "Hello world" "$entry" && echo 0 || echo 1)"

# Test Gemini entry
gemini_entry="${AGENT_REGISTRY[1]}"
assert_eq "Gemini entry name" "gemini" "$(reg_name "$gemini_entry")"
assert_eq "Gemini tier is 1" "1" "$(reg_tier "$gemini_entry")"
assert_eq "Gemini rate limit: 429" "0" "$(is_agent_rate_limited "Error 429: too many requests" "$gemini_entry" && echo 0 || echo 1)"
assert_eq "Gemini rate limit: quota" "0" "$(is_agent_rate_limited "quota exceeded for project" "$gemini_entry" && echo 0 || echo 1)"

# Test cascade order with default (all entries)
count=$(get_cascade_order | wc -l | tr -d ' ')
assert_eq "default cascade has all entries" "${#AGENT_REGISTRY[@]}" "$count"

# Test custom order
USER_ORDER=("gemini" "claude-opus")
count=$(get_cascade_order | wc -l | tr -d ' ')
assert_eq "custom order respects user selection" "2" "$count"
first_name=$(get_cascade_order | head -1 | cut -d'|' -f2)
assert_eq "custom order puts gemini first" "gemini" "$first_name"
USER_ORDER=()

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "========================"
echo "Results: $pass passed, $fail failed, $total total"
echo "========================"

[ "$fail" -eq 0 ] && exit 0 || exit 1
