#!/bin/bash
# claude-resume — Auto-resume Claude Code with model cascading, cross-agent
# fallback, inter-agent delegation, and long-running task support.
# macOS-first. Zero required deps. Optional: cli-continues for cross-agent handoff.

set -euo pipefail

VERSION="1.2.0"
TIMEOUT_SECS=300
BUFFER_SECS=10
RATE_LIMIT_EXIT=2

# --- Defaults ---
PROMPT="continue"
CONTINUE=false
RESUME_SESSION=""
FALLBACK_TOOL=""
FALLBACK_AGENTS=()
MODEL=""
CASCADE=true
LOOP=false
SKIP_PERMS=false
PERM_MODE=""
TEST_SECS=0
TASK_FILE=""
SUBCOMMAND=""
DELEGATE_AGENT=""
DELEGATE_TASK=""
DELEGATE_CONTEXT=""
PROFILES=()
LOG_FILE=""
CAFFEINATE_PID=""
PASS_THROUGH_FLAGS=()

# Models to cascade through (cheapest last)
CASCADE_MODELS=("sonnet" "haiku")
# Agents to try as fallback (checked for installation)
KNOWN_AGENTS=("gemini" "codex" "copilot" "aider")

# ============================================================================
# Helpers
# ============================================================================

die()    { echo "Error: $1" >&2; exit "${2:-1}"; }
info()   { echo ":: $1"; }
debug()  { [ "${DEBUG:-}" = "1" ] && echo "[debug] $1" >&2 || true; }

notify() {
  local msg="$1"
  info "$msg"
  command -v osascript &>/dev/null && \
    osascript -e "display notification \"$msg\" with title \"claude-resume\"" 2>/dev/null || true
}

log_event() {
  [ -z "$LOG_FILE" ] && return
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Prevent sleep during long-running operations (macOS)
start_caffeinate() {
  if command -v caffeinate &>/dev/null; then
    caffeinate -dims &
    CAFFEINATE_PID=$!
    debug "caffeinate started (pid=$CAFFEINATE_PID)"
  fi
}

stop_caffeinate() {
  if [ -n "$CAFFEINATE_PID" ]; then
    kill "$CAFFEINATE_PID" 2>/dev/null
    CAFFEINATE_PID=""
  fi
}

# Clean up child processes on exit (preserves exit code)
cleanup() {
  local exit_code=$?
  stop_caffeinate
  log_event "SESSION_END"
  exit $exit_code
}
trap cleanup EXIT INT TERM

# Cross-platform timeout (macOS ships bash 3 + no GNU timeout)
run_timeout() {
  local secs=$1; shift
  if command -v gtimeout &>/dev/null; then
    gtimeout --foreground "$secs" "$@"; return $?
  elif command -v timeout &>/dev/null; then
    timeout --foreground "$secs" "$@" 2>/dev/null || timeout "$secs" "$@"; return $?
  else
    "$@" &
    local pid=$! watcher
    ( sleep "$secs" && kill "$pid" 2>/dev/null ) &
    watcher=$!
    wait "$pid" 2>/dev/null; local ret=$?
    kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
    [ $ret -ge 128 ] && return 124
    return $ret
  fi
}

fmt_time() {
  if date --version &>/dev/null 2>&1; then
    date -d "@$1" "+%H:%M:%S"
  else
    date -r "$1" "+%H:%M:%S"
  fi
}

# Check if output contains a rate limit message
# Covers known Claude Code output formats (2024-2026):
#   - "Claude AI usage limit reached"
#   - "limit reached...resets Xam/pm"
#   - "hit your limit...resets Xam/pm (TZ)"
#   - "You're out of extra usage"
#   - "rate limit exceeded"
#   - "usage limit" / "resets at"
is_rate_limited() {
  echo "$1" | grep -qiE "(usage limit reached|limit reached.*resets|hit your limit|out of.*(extra )?usage|rate.?limit|usage limit.*resets)"
}

# ============================================================================
# Rate Limit Detection
# ============================================================================

# Parse reset timestamp from Claude output → stdout. Returns 1 on failure.
parse_reset_time() {
  local output="$1"

  # Format 1: Claude AI usage limit reached|<unix_timestamp>
  if echo "$output" | grep -q "Claude AI usage limit reached|"; then
    echo "$output" | awk -F'|' '{print $2}' | grep -o '[0-9]*' | head -1
    return 0
  fi

  # Format 2/3: "...limit reached...resets Xam/pm" or "...hit your limit...resets Xam/pm (TZ)"
  local time_str tz_str
  time_str=$(echo "$output" | grep -oE '[0-9]+(:[0-9]+)?[ap]m' | head -1)
  [ -z "$time_str" ] && return 1

  tz_str=$(echo "$output" | grep -oE '\([A-Za-z_/]+\)' | tr -d '()' | head -1)

  local hour minute period hour24
  period=$(echo "$time_str" | grep -oE '[ap]m')

  if echo "$time_str" | grep -q ':'; then
    hour=$(echo "$time_str" | cut -d: -f1)
    minute=$(echo "$time_str" | sed 's/[ap]m//' | cut -d: -f2)
  else
    hour=$(echo "$time_str" | sed 's/[ap]m//')
    minute=0
  fi

  if [ "$period" = "am" ]; then
    hour24=$(( hour == 12 ? 0 : hour ))
  else
    hour24=$(( hour == 12 ? 12 : hour + 12 ))
  fi

  local now today_reset tz_prefix=""
  now=$(date +%s)
  [ -n "$tz_str" ] && tz_prefix="TZ=$tz_str"

  if date --version &>/dev/null 2>&1; then
    today_reset=$(env $tz_prefix date -d "today ${hour24}:${minute}:00" +%s 2>/dev/null) || return 1
  else
    local today_date
    today_date=$(env $tz_prefix date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
    today_reset=$(env $tz_prefix date -j -f "%Y-%m-%d %H:%M:%S" "${today_date} ${hour24}:${minute}:00" +%s 2>/dev/null) || return 1
  fi

  if [ "$now" -gt "$today_reset" ]; then
    if date --version &>/dev/null 2>&1; then
      today_reset=$(env $tz_prefix date -d "tomorrow ${hour24}:${minute}:00" +%s 2>/dev/null) || return 1
    else
      local tomorrow
      tomorrow=$(env $tz_prefix date -j -v+1d +%Y-%m-%d 2>/dev/null || date -j -v+1d +%Y-%m-%d)
      today_reset=$(env $tz_prefix date -j -f "%Y-%m-%d %H:%M:%S" "${tomorrow} ${hour24}:${minute}:00" +%s 2>/dev/null) || return 1
    fi
  fi

  echo "$today_reset"
}

# Check if a model is rate-limited → "ok", "limited|<timestamp>", or "limited"
check_model() {
  local model_flag=""
  [ -n "${1:-}" ] && model_flag="--model $1"

  local output
  output=$(run_timeout "$TIMEOUT_SECS" claude $model_flag -p 'check' 2>&1) || true

  if is_rate_limited "$output"; then
    local ts
    ts=$(parse_reset_time "$output") && echo "limited|$ts" || echo "limited"
  else
    echo "ok"
  fi
}

# ============================================================================
# Countdown
# ============================================================================

countdown() {
  local target=$1 remaining
  while true; do
    remaining=$((target - $(date +%s)))
    [ "$remaining" -le 0 ] && break
    printf "\r  %02d:%02d:%02d remaining " $((remaining/3600)) $(((remaining%3600)/60)) $((remaining%60))
    sleep 1
  done
  printf "\r  Rate limit lifted!                         \n"
}

# ============================================================================
# Cross-Agent Fallback
# ============================================================================

has_continues() {
  command -v npx &>/dev/null && npx continues --version &>/dev/null 2>&1
}

fallback_handoff() {
  local tool="$1"
  if ! has_continues; then
    info "cli-continues not available. Install: npm i -g continues"
    info "Falling back to countdown-only mode."
    return 1
  fi
  info "Handing off to $tool via cli-continues..."
  npx continues resume --in "$tool" --preset standard 2>/dev/null
}

# ============================================================================
# Inter-Agent Delegation
# ============================================================================

# Run a task on another agent headlessly, capture and return output
delegate_to_agent() {
  local agent="$1" task="$2"

  # Map agent → headless flag
  local flag="-p"
  case "$agent" in
    copilot) flag="--prompt" ;;
  esac

  # Direct CLI execution (preferred — no dependency on cli-continues)
  if command -v "$agent" &>/dev/null; then
    info "Delegating to $agent: ${task:0:80}..."
    local tmpfile
    tmpfile=$(mktemp)

    # Run with real-time output + capture
    set +e
    "$agent" $flag "$task" 2>&1 | tee "$tmpfile"
    local ret=${PIPESTATUS[0]}
    set -e

    local result
    result=$(cat "$tmpfile")
    rm -f "$tmpfile"

    if [ $ret -ne 0 ]; then
      info "Warning: $agent exited with code $ret"
    fi

    echo "$result"
    return $ret
  fi

  # Fallback: interactive handoff via cli-continues
  if has_continues; then
    info "$agent CLI not found. Attempting interactive handoff via cli-continues..."
    npx continues resume --in "$agent" --preset standard 2>/dev/null
    return $?
  fi

  die "$agent CLI not found and cli-continues not available."
}

# ============================================================================
# Resume Claude
# ============================================================================

# Build claude command as an array (safe — no eval injection)
build_claude_cmd() {
  local model_override="${1:-}"
  CLAUDE_CMD=("claude")

  # Permission mode (prefer --permission-mode over --dangerously-skip-permissions)
  if [ -n "$PERM_MODE" ]; then
    CLAUDE_CMD+=("--permission-mode" "$PERM_MODE")
  elif [ "$SKIP_PERMS" = true ]; then
    CLAUDE_CMD+=("--dangerously-skip-permissions")
  fi

  if [ -n "$RESUME_SESSION" ]; then
    CLAUDE_CMD+=("--resume" "$RESUME_SESSION")
  elif [ "$CONTINUE" = true ]; then
    CLAUDE_CMD+=("-c")
  fi
  if [ -n "$model_override" ]; then
    CLAUDE_CMD+=("--model" "$model_override")
  elif [ -n "$MODEL" ]; then
    CLAUDE_CMD+=("--model" "$MODEL")
  fi

  # Forward any pass-through flags to claude
  if [ ${#PASS_THROUGH_FLAGS[@]} -gt 0 ]; then
    CLAUDE_CMD+=("${PASS_THROUGH_FLAGS[@]}")
  fi
}

# Run Claude and return: 0=success, 2=rate limited during execution
resume_claude() {
  local model_override="${1:-}"
  build_claude_cmd "$model_override"

  local effective_prompt="$PROMPT"
  # Inject delegation context if available
  if [ -n "$DELEGATE_CONTEXT" ]; then
    effective_prompt="Context from delegated agent:
${DELEGATE_CONTEXT}

Task: ${PROMPT}"
    DELEGATE_CONTEXT=""
  fi

  CLAUDE_CMD+=("-p" "$effective_prompt")

  info "Running: ${CLAUDE_CMD[*]::8}... -p \"${effective_prompt:0:80}...\""
  log_event "RUN: ${CLAUDE_CMD[*]::8}... prompt=${effective_prompt:0:120}"

  local tmpfile
  tmpfile=$(mktemp)

  set +e
  "${CLAUDE_CMD[@]}" 2>&1 | tee "$tmpfile"
  local ret=${PIPESTATUS[0]}
  set -e

  # Check if Claude hit a rate limit during execution
  if is_rate_limited "$(cat "$tmpfile")"; then
    log_event "RATE_LIMITED during execution"
    rm -f "$tmpfile"
    return $RATE_LIMIT_EXIT
  fi

  log_event "EXIT: code=$ret"
  rm -f "$tmpfile"
  return $ret
}

# ============================================================================
# Core: Handle Rate Limits + Cascade + Fallback + Wait
# ============================================================================

wait_for_reset() {
  local status="$1"
  local reset_ts=""
  if [[ "$status" == limited\|* ]]; then
    reset_ts="${status#limited|}"
  fi

  if [ -n "$reset_ts" ]; then
    local wait_secs=$((reset_ts - $(date +%s)))
    if [ "$wait_secs" -gt 0 ]; then
      info "Waiting until $(fmt_time "$reset_ts") for rate limit to lift..."
      countdown "$reset_ts"
      notify "Claude rate limit lifted!"
      sleep "$BUFFER_SECS"
    fi
  else
    info "Couldn't parse reset time. Waiting 5 minutes..."
    sleep 300
  fi
}

# ============================================================================
# Status Check
# ============================================================================

show_status() {
  echo "claude-resume v$VERSION — status"
  echo ""

  # Check primary model
  local primary="${MODEL:-opus}"
  printf "  %-12s " "$primary"
  local s
  s=$(check_model "$MODEL")
  if [ "$s" = "ok" ]; then
    echo "available"
  elif [[ "$s" == limited\|* ]]; then
    echo "limited — resets $(fmt_time "${s#limited|}")"
  else
    echo "limited"
  fi

  # Check cascade models
  for m in "${CASCADE_MODELS[@]}"; do
    [ "$m" = "$MODEL" ] && continue
    printf "  %-12s " "$m"
    s=$(check_model "$m")
    if [ "$s" = "ok" ]; then
      echo "available"
    elif [[ "$s" == limited\|* ]]; then
      echo "limited — resets $(fmt_time "${s#limited|}")"
    else
      echo "limited"
    fi
  done

  # Check installed agents
  echo ""
  echo "  Agents:"
  for tool in "${KNOWN_AGENTS[@]}"; do
    printf "  %-12s " "$tool"
    if command -v "$tool" &>/dev/null; then
      echo "installed"
    else
      echo "not found"
    fi
  done

  printf "  %-12s " "cli-continues"
  if has_continues; then
    echo "installed"
  else
    echo "not found"
  fi
}

# ============================================================================
# Core: Handle Rate Limits + Cascade + Fallback + Wait
# ============================================================================

run_once() {
  # Test mode: simulate rate limit
  if [ "$TEST_SECS" -gt 0 ]; then
    local fake_ts=$(($(date +%s) + TEST_SECS))
    info "[test] Simulating rate limit, resets in ${TEST_SECS}s"
    countdown "$fake_ts"
    sleep "$BUFFER_SECS"
    resume_claude ""
    return $?
  fi

  # Step 1: Check current model
  info "Checking rate limit status..."
  local status
  status=$(check_model "$MODEL")
  debug "check_model returned: $status"
  log_event "CHECK: model=${MODEL:-default} status=$status"

  if [ "$status" = "ok" ]; then
    info "No rate limit detected."
    resume_claude ""
    return $?
  fi

  # Step 2: Model cascade — try cheaper models
  if [ "$CASCADE" = true ]; then
    for alt_model in "${CASCADE_MODELS[@]}"; do
      [ "$alt_model" = "$MODEL" ] && continue
      info "Rate limited. Trying $alt_model..."
      local alt_status
      alt_status=$(check_model "$alt_model")

      if [ "$alt_status" = "ok" ]; then
        info "Available on $alt_model — switching."
        log_event "CASCADE: $alt_model"
        resume_claude "$alt_model"
        return $?
      fi
      debug "$alt_model status: $alt_status"
    done
    info "All Claude models are rate limited."
  fi

  # Step 4: Cross-agent fallback — try ALL installed agents
  # Build list: explicit fallback first, then auto-detect installed agents
  local agents_to_try=()
  [ -n "$FALLBACK_TOOL" ] && agents_to_try+=("$FALLBACK_TOOL")
  for a in "${KNOWN_AGENTS[@]}"; do
    # Skip if already in list or not installed
    [[ " ${agents_to_try[*]} " == *" $a "* ]] && continue
    command -v "$a" &>/dev/null && agents_to_try+=("$a")
  done

  for agent in "${agents_to_try[@]}"; do
    info "All Claude models limited. Trying $agent..."
    log_event "FALLBACK: $agent"

    # Try direct headless delegation first
    if command -v "$agent" &>/dev/null; then
      local flag="-p"
      case "$agent" in copilot) flag="--prompt" ;; esac

      info "Running task on $agent while Claude recovers..."
      local tmpfile
      tmpfile=$(mktemp)
      set +e
      "$agent" $flag "$PROMPT" 2>&1 | tee "$tmpfile"
      local agent_ret=${PIPESTATUS[0]}
      set -e
      rm -f "$tmpfile"

      if [ $agent_ret -eq 0 ]; then
        info "$agent completed the task."
        log_event "FALLBACK_SUCCESS: $agent"
        return 0
      fi
      info "$agent failed (exit $agent_ret). Trying next..."
      continue
    fi

    # Try via cli-continues
    if has_continues; then
      if fallback_handoff "$agent"; then
        local recheck
        recheck=$(check_model "$MODEL")
        if [ "$recheck" = "ok" ]; then
          info "Claude is available again!"
          resume_claude ""
          return $?
        fi
      fi
    fi
  done

  if [ ${#agents_to_try[@]} -gt 0 ]; then
    info "All installed agents exhausted."
  fi

  # Step 5: Wait for reset
  log_event "WAITING for reset"
  wait_for_reset "$status"

  # Step 6: Resume on Claude
  resume_claude ""
}

# ============================================================================
# Long-Running Task File Processing
# ============================================================================

# Task file format (one task per line):
#   # Comments (skipped)
#   - [ ] Regular task for Claude
#   - [x] Completed task (skipped)
#   delegate:gemini Query Stitch for signups
#   Regular task without markdown prefix
#
# Delegation results are injected as context into the next Claude task.

process_tasks() {
  local file="$1"
  [ -f "$file" ] || die "Task file not found: $file"

  # Count actionable tasks
  local total=0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*#|^[[:space:]]*$ ]] && continue
    [[ "$line" =~ \[x\]|\[X\] ]] && continue
    total=$((total + 1))
  done < "$file"

  info "Processing $total tasks from $file"

  local task_num=0
  while IFS= read -r line; do
    # Skip comments, blanks, completed tasks
    [[ "$line" =~ ^[[:space:]]*#|^[[:space:]]*$ ]] && continue
    [[ "$line" =~ \[x\]|\[X\] ]] && continue

    task_num=$((task_num + 1))

    # Strip markdown task prefix: "- [ ] " or "- "
    local task="$line"
    task="${task#- \[ \] }"
    task="${task#- }"
    task="${task#\[ \] }"

    info "[$task_num/$total] $task"

    # Check for delegation prefix: "delegate:<agent> <task>"
    if [[ "$task" =~ ^delegate:([a-zA-Z0-9_-]+)[[:space:]]+(.+)$ ]]; then
      local agent="${BASH_REMATCH[1]}"
      local subtask="${BASH_REMATCH[2]}"
      local result
      result=$(delegate_to_agent "$agent" "$subtask") || true
      DELEGATE_CONTEXT="$result"
      info "Delegation to $agent complete. Result will be injected into next Claude task."
    else
      # Run as Claude task, with rate limit handling
      PROMPT="$task"
      if [ "$LOOP" = true ]; then
        # Keep retrying until this task succeeds
        while true; do
          run_once && break
          info "Rate limited during task. Retrying..."
          sleep "$BUFFER_SECS"
        done
      else
        run_once
      fi
    fi

    echo ""
  done < "$file"

  notify "All $total tasks completed!"
}

# ============================================================================
# CLI
# ============================================================================

show_help() {
  cat <<EOF
claude-resume v$VERSION — Auto-resume Claude Code with model cascading + fallback

USAGE
  claude-resume [options] [prompt]          Resume or run Claude
  claude-resume status                      Show rate limit status for all models
  claude-resume delegate <agent> <task>     Delegate a task to another AI agent
  claude-resume tasks <file>                Process a task file

OPTIONS
  -c, --continue           Continue previous conversation
  -r, --resume <id>        Resume a specific session by ID
  -f, --fallback <tool>    Preferred fallback agent (tried first before auto-detect)
  -m, --model <model>      Force specific Claude model
  --no-cascade             Disable model cascade (Opus → Sonnet → Haiku)
  --loop                   Keep retrying through ALL available models/agents
  --permission-mode <mode> Claude permission mode (auto, acceptEdits, bypassPermissions)
  --skip-permissions       Shorthand for --permission-mode bypassPermissions
  --log <file>             Log events (rate limits, cascades, fallbacks) to file
  --test <seconds>         Simulate rate limit with N-second wait
  -h, --help               Show help
  -v, --version            Show version
  -- <flags>               Forward remaining flags to Claude CLI

EXAMPLES
  claude-resume -c                              # Resume previous conversation
  claude-resume -r abc123 "keep going"          # Resume specific session
  claude-resume --loop -c                       # Keep going through ALL agents
  claude-resume -f gemini -c                    # Try Gemini first if limited
  claude-resume -m sonnet "fix the bug"         # Force Sonnet
  claude-resume status                          # Check all model/tool status
  claude-resume --permission-mode auto -c       # Safer than --skip-permissions
  claude-resume -c -- --worktree myfeature      # Pass flags to Claude

  claude-resume delegate gemini "query Stitch for user signups"
  claude-resume tasks my-tasks.md --loop --skip-permissions

TASK FILE FORMAT
  # Comments are skipped
  - [ ] Refactor auth module to use JWT
  - [ ] Add tests for all endpoints
  delegate:gemini Query Stitch for user signups last 7 days
  - [ ] Update docs with Stitch data from above
  - [x] Already done (skipped)

  Delegation results are automatically injected as context into the next task.

CASCADE ORDER (--loop exhausts all before stopping)
  Claude models (Opus → Sonnet → Haiku) → All installed agents → Wait → Retry

ENVIRONMENT
  DEBUG=1    Enable debug output
EOF
}

[ "${TEST_MODE:-}" = "1" ] && return 0 2>/dev/null || true

# --- Parse subcommands first ---
if [ "${1:-}" = "delegate" ]; then
  SUBCOMMAND="delegate"
  shift
  [ $# -lt 1 ] && die "Usage: claude-resume delegate <agent> <task>"
  DELEGATE_AGENT="$1"; shift
  [ $# -lt 1 ] && die "Usage: claude-resume delegate <agent> <task>"
  DELEGATE_TASK="$1"; shift
elif [ "${1:-}" = "tasks" ]; then
  SUBCOMMAND="tasks"
  shift
  [ $# -lt 1 ] && die "Usage: claude-resume tasks <file>"
  TASK_FILE="$1"; shift
elif [ "${1:-}" = "status" ]; then
  SUBCOMMAND="status"
  shift
fi

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
  case $1 in
    -c|--continue)        CONTINUE=true; shift ;;
    -r|--resume)          RESUME_SESSION="${2:?--resume requires a session ID}"; shift 2 ;;
    -f|--fallback)        FALLBACK_TOOL="${2:?--fallback requires a tool name}"; shift 2 ;;
    -m|--model)           MODEL="${2:?--model requires a model name}"; shift 2 ;;
    --no-cascade)         CASCADE=false; shift ;;
    --loop)               LOOP=true; shift ;;
    --permission-mode)    PERM_MODE="${2:?--permission-mode requires a mode}"; shift 2 ;;
    --skip-permissions)   SKIP_PERMS=true; shift ;;
    --log)                LOG_FILE="${2:?--log requires a file path}"; shift 2 ;;
    --test)               TEST_SECS="${2:?--test requires seconds}"; shift 2 ;;
    -h|--help)            show_help; exit 0 ;;
    -v|--version)         echo "claude-resume v$VERSION"; exit 0 ;;
    --)                   shift; PASS_THROUGH_FLAGS+=("$@"); break ;;
    -*)                   die "Unknown option: $1" ;;
    *)                    PROMPT="$1"; shift ;;
  esac
done

# ============================================================================
# Execute
# ============================================================================

# Delegate subcommand doesn't need Claude CLI
if [ "$SUBCOMMAND" = "delegate" ]; then
  delegate_to_agent "$DELEGATE_AGENT" "$DELEGATE_TASK"
  exit $?
fi

# Everything else needs Claude CLI
command -v claude &>/dev/null || die "Claude CLI not found. Install: https://claude.ai/code"

# Initialize log file
[ -n "$LOG_FILE" ] && log_event "SESSION_START: v$VERSION args=$*"

if [ "$SUBCOMMAND" = "status" ]; then
  show_status
  exit 0
fi

if [ "$SUBCOMMAND" = "tasks" ]; then
  process_tasks "$TASK_FILE"
  exit $?
fi

# Prevent sleep for long-running operations
if [ "$LOOP" = true ] || [ "$SUBCOMMAND" = "tasks" ]; then
  start_caffeinate
fi

# Default: single run or loop
if [ "$LOOP" = true ]; then
  while true; do
    run_once
    ret=$?
    [ $ret -eq 0 ] && break
    if [ $ret -eq $RATE_LIMIT_EXIT ]; then
      info "Hit rate limit during execution. Re-running cascade..."
    else
      info "Claude exited with code $ret. Retrying in ${BUFFER_SECS}s..."
    fi
    sleep "$BUFFER_SECS"
  done
else
  run_once
fi
