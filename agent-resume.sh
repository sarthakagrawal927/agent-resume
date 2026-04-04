#!/bin/bash
# agent-resume — Auto-resume AI coding agents through rate limits.
# Unified cascade across Claude, Gemini, Codex, Copilot, Aider.
# Smart routing by default, cascading on rate limit.
# macOS-first. Zero required deps.

set -euo pipefail

VERSION="2.0.0"
TIMEOUT_SECS=300
BUFFER_SECS=10
RATE_LIMIT_EXIT=2

# --- Defaults ---
PROMPT="continue"
CONTINUE=false
RESUME_SESSION=""
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
LOG_FILE=""
CAFFEINATE_PID=""
PASS_THROUGH_FLAGS=()
USER_ORDER=()

# ============================================================================
# Agent Registry
# ============================================================================
# Format: "tier|name|cli_cmd|probe_cmd|headless_flag|rate_limit_patterns"
#
# tier: 1=best, 2=mid, 3=budget (used for default routing order)
# cli_cmd: the CLI binary name
# probe_cmd: command to check if available + not rate-limited (empty = just check installation)
# headless_flag: flag to run non-interactively with a prompt
# rate_limit_patterns: pipe-separated grep -iE patterns for rate limit detection
#
# Default order interleaves vendors by quality tier.

AGENT_REGISTRY=(
  "1|claude-opus|claude|claude --model opus -p check|--model opus -p|usage limit reached|limit reached.*resets|hit your limit|out of.*(extra )?usage|rate.?limit"
  "1|gemini|gemini|gemini -p check|-p|rate limit|quota exceeded|resource.?exhausted|429|too many requests"
  "2|claude-sonnet|claude|claude --model sonnet -p check|--model sonnet -p|usage limit reached|limit reached.*resets|hit your limit|out of.*(extra )?usage|rate.?limit"
  "2|codex|codex|codex -p check|-p|rate limit|429|too many requests|quota exceeded"
  "3|claude-haiku|claude|claude --model haiku -p check|--model haiku -p|usage limit reached|limit reached.*resets|hit your limit|out of.*(extra )?usage|rate.?limit"
  "3|copilot|copilot|copilot --prompt check|--prompt|rate limit|429|too many requests"
  "3|aider|aider|aider --message check|--message|rate limit|429|too many requests"
)

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
    osascript -e "display notification \"$msg\" with title \"agent-resume\"" 2>/dev/null || true
}

log_event() {
  [ -z "$LOG_FILE" ] && return
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

start_caffeinate() {
  if command -v caffeinate &>/dev/null; then
    caffeinate -dims &
    CAFFEINATE_PID=$!
    debug "caffeinate started (pid=$CAFFEINATE_PID)"
  fi
}

stop_caffeinate() {
  [ -n "$CAFFEINATE_PID" ] && kill "$CAFFEINATE_PID" 2>/dev/null
  CAFFEINATE_PID=""
}

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

# ============================================================================
# Agent Registry Helpers
# ============================================================================

# Parse a registry entry field by index (0-based after split on |)
# Fields: 0=tier, 1=name, 2=cli_cmd, 3=probe_cmd, 4=headless_flag, 5+=rate_limit_patterns
reg_field() {
  local entry="$1" idx="$2"
  echo "$entry" | cut -d'|' -f$((idx + 1))
}

reg_tier()     { reg_field "$1" 0; }
reg_name()     { reg_field "$1" 1; }
reg_cli()      { reg_field "$1" 2; }
reg_probe()    { reg_field "$1" 3; }
reg_headless() { reg_field "$1" 4; }

# Get rate limit patterns for an agent (fields 5+, pipe-separated)
reg_patterns() {
  echo "$1" | cut -d'|' -f6-
}

# Check if output matches an agent's rate limit patterns
is_agent_rate_limited() {
  local output="$1" entry="$2"
  local patterns
  patterns=$(reg_patterns "$entry")
  [ -z "$patterns" ] && return 1
  echo "$output" | grep -qiE "$patterns"
}

# Generic rate limit check (works for any agent)
is_rate_limited() {
  echo "$1" | grep -qiE "(usage limit.*reached|limit reached.*resets|hit your limit|out of.*(extra )?usage|rate.?limit|quota exceeded|resource.?exhausted|429|too many requests|usage limit.*resets)"
}

# Check if an agent is installed
is_installed() {
  local entry="$1"
  local cli
  cli=$(reg_cli "$entry")
  command -v "$cli" &>/dev/null
}

# Probe an agent: returns "ok", "limited|<timestamp>", or "limited"
probe_agent() {
  local entry="$1"
  local probe_cmd
  probe_cmd=$(reg_probe "$entry")
  local name
  name=$(reg_name "$entry")

  debug "Probing $name: $probe_cmd"

  local output
  output=$(run_timeout "$TIMEOUT_SECS" $probe_cmd 2>&1) || true

  if is_agent_rate_limited "$output" "$entry"; then
    # Try to parse reset time (Claude-specific, others just return "limited")
    local ts
    ts=$(parse_reset_time "$output" 2>/dev/null) && echo "limited|$ts" || echo "limited"
  else
    echo "ok"
  fi
}

# Build the cascade order: user-specified order, or default tier-sorted registry
get_cascade_order() {
  if [ ${#USER_ORDER[@]} -gt 0 ]; then
    # User-defined order: look up each name in the registry
    for name in "${USER_ORDER[@]}"; do
      for entry in "${AGENT_REGISTRY[@]}"; do
        if [ "$(reg_name "$entry")" = "$name" ]; then
          echo "$entry"
          break
        fi
      done
    done
  else
    # Default: all entries in registry order (already sorted by tier)
    for entry in "${AGENT_REGISTRY[@]}"; do
      echo "$entry"
    done
  fi
}

# ============================================================================
# Rate Limit Time Parsing (Claude-specific, best-effort for others)
# ============================================================================

parse_reset_time() {
  local output="$1"

  # Format 1: Claude AI usage limit reached|<unix_timestamp>
  if echo "$output" | grep -q "Claude AI usage limit reached|"; then
    echo "$output" | awk -F'|' '{print $2}' | grep -o '[0-9]*' | head -1
    return 0
  fi

  # Format 2/3: "resets Xam/pm" or "resets Xam/pm (TZ)"
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
      notify "Rate limit lifted!"
      sleep "$BUFFER_SECS"
    fi
  else
    info "Couldn't parse reset time. Waiting 5 minutes..."
    sleep 300
  fi
}

# ============================================================================
# Inter-Agent Delegation
# ============================================================================

has_continues() {
  command -v npx &>/dev/null && npx continues --version &>/dev/null 2>&1
}

delegate_to_agent() {
  local agent="$1" task="$2"

  # Find in registry for headless flag
  local flag="-p"
  for entry in "${AGENT_REGISTRY[@]}"; do
    if [ "$(reg_name "$entry")" = "$agent" ] || [ "$(reg_cli "$entry")" = "$agent" ]; then
      local headless
      headless=$(reg_headless "$entry")
      # Extract just the flag part (e.g., "-p" from "--model opus -p")
      flag="${headless##* }"
      break
    fi
  done

  if command -v "$agent" &>/dev/null; then
    info "Delegating to $agent: ${task:0:80}..."
    local tmpfile
    tmpfile=$(mktemp)

    set +e
    "$agent" $flag "$task" 2>&1 | tee "$tmpfile"
    local ret=${PIPESTATUS[0]}
    set -e

    local result
    result=$(cat "$tmpfile")
    rm -f "$tmpfile"

    [ $ret -ne 0 ] && info "Warning: $agent exited with code $ret"
    echo "$result"
    return $ret
  fi

  if has_continues; then
    info "$agent CLI not found. Attempting handoff via cli-continues..."
    npx continues resume --in "$agent" --preset standard 2>/dev/null
    return $?
  fi

  die "$agent CLI not found and cli-continues not available."
}

# ============================================================================
# Run Agent — execute a prompt on a specific agent
# ============================================================================

run_agent() {
  local entry="$1" prompt="$2"
  local name cli headless
  name=$(reg_name "$entry")
  cli=$(reg_cli "$entry")
  headless=$(reg_headless "$entry")

  local effective_prompt="$prompt"
  if [ -n "$DELEGATE_CONTEXT" ]; then
    effective_prompt="Context from delegated agent:
${DELEGATE_CONTEXT}

Task: ${prompt}"
    DELEGATE_CONTEXT=""
  fi

  # Build command array
  local cmd=()

  if [ "$cli" = "claude" ]; then
    cmd+=("claude")
    # Claude-specific flags
    if [ -n "$PERM_MODE" ]; then
      cmd+=("--permission-mode" "$PERM_MODE")
    elif [ "$SKIP_PERMS" = true ]; then
      cmd+=("--dangerously-skip-permissions")
    fi
    if [ -n "$RESUME_SESSION" ]; then
      cmd+=("--resume" "$RESUME_SESSION")
    elif [ "$CONTINUE" = true ]; then
      cmd+=("-c")
    fi
    # headless includes model flag, e.g. "--model opus -p"
    # Split headless into words and add to cmd
    read -ra headless_parts <<< "$headless"
    cmd+=("${headless_parts[@]}")
    cmd+=("$effective_prompt")
    # Pass-through flags
    [ ${#PASS_THROUGH_FLAGS[@]} -gt 0 ] && cmd+=("${PASS_THROUGH_FLAGS[@]}")
  else
    cmd+=("$cli")
    read -ra headless_parts <<< "$headless"
    cmd+=("${headless_parts[@]}")
    cmd+=("$effective_prompt")
  fi

  info "Running on $name: ${cmd[*]::6}..."
  log_event "RUN: agent=$name prompt=${effective_prompt:0:120}"

  local tmpfile
  tmpfile=$(mktemp)

  set +e
  "${cmd[@]}" 2>&1 | tee "$tmpfile"
  local ret=${PIPESTATUS[0]}
  set -e

  if is_agent_rate_limited "$(cat "$tmpfile")" "$entry"; then
    log_event "RATE_LIMITED: $name during execution"
    rm -f "$tmpfile"
    return $RATE_LIMIT_EXIT
  fi

  log_event "EXIT: agent=$name code=$ret"
  rm -f "$tmpfile"
  return $ret
}

# ============================================================================
# Core: Smart Routing + Cascade on Rate Limit
# ============================================================================
#
# Default behavior (routing):
#   Find the best available agent (highest tier, installed, not rate-limited)
#   and run the task on it.
#
# On rate limit (cascade):
#   Walk down the cascade order trying each agent until one works.
#
# --no-cascade: only try the routed agent, fail if rate-limited.

run_once() {
  # Test mode
  if [ "$TEST_SECS" -gt 0 ]; then
    local fake_ts=$(($(date +%s) + TEST_SECS))
    info "[test] Simulating rate limit, resets in ${TEST_SECS}s"
    countdown "$fake_ts"
    sleep "$BUFFER_SECS"
    # Run on first available agent after simulated wait
    while IFS= read -r entry; do
      is_installed "$entry" || continue
      run_agent "$entry" "$PROMPT"
      return $?
    done < <(get_cascade_order)
    die "No agents available"
  fi

  # Build cascade order
  local cascade_entries=()
  local first_status=""
  while IFS= read -r entry; do
    is_installed "$entry" || continue
    cascade_entries+=("$entry")
  done < <(get_cascade_order)

  [ ${#cascade_entries[@]} -eq 0 ] && die "No AI agents installed. Install claude, gemini, codex, copilot, or aider."

  # Step 1: Route to best available agent
  info "Finding best available agent..."
  for entry in "${cascade_entries[@]}"; do
    local name
    name=$(reg_name "$entry")
    debug "Checking $name..."

    local status
    status=$(probe_agent "$entry")
    debug "$name: $status"
    log_event "PROBE: $name=$status"

    # Save first status for wait_for_reset
    [ -z "$first_status" ] && first_status="$status"

    if [ "$status" = "ok" ]; then
      info "Routing to $name"
      run_agent "$entry" "$PROMPT"
      local ret=$?

      # If it hit rate limit DURING execution, cascade to next
      if [ $ret -eq $RATE_LIMIT_EXIT ] && [ "$CASCADE" = true ]; then
        info "$name hit rate limit during execution. Cascading..."
        continue
      fi
      return $ret
    fi

    # Rate limited — cascade if enabled
    if [ "$CASCADE" = true ]; then
      info "$name is rate limited. Trying next..."
      continue
    else
      info "$name is rate limited. Cascade disabled (--no-cascade)."
      wait_for_reset "$status"
      run_agent "$entry" "$PROMPT"
      return $?
    fi
  done

  # All agents exhausted
  info "All installed agents are rate limited."
  log_event "ALL_LIMITED"

  # Wait for reset using first agent's status (most likely to have a timestamp)
  wait_for_reset "${first_status:-limited}"

  # After wait, try the first agent again
  run_agent "${cascade_entries[0]}" "$PROMPT"
}

# ============================================================================
# Status Check
# ============================================================================

show_status() {
  echo "agent-resume v$VERSION — status"
  echo ""

  while IFS= read -r entry; do
    local name cli
    name=$(reg_name "$entry")
    cli=$(reg_cli "$entry")
    local tier
    tier=$(reg_tier "$entry")

    printf "  [T%s] %-16s " "$tier" "$name"

    if ! command -v "$cli" &>/dev/null; then
      echo "not installed"
      continue
    fi

    local status
    status=$(probe_agent "$entry")
    if [ "$status" = "ok" ]; then
      echo "available"
    elif [[ "$status" == limited\|* ]]; then
      echo "limited — resets $(fmt_time "${s#limited|}")"
    else
      echo "limited"
    fi
  done < <(get_cascade_order)

  echo ""
  printf "  %-20s " "cli-continues"
  if has_continues; then echo "installed"; else echo "not found"; fi
}

# ============================================================================
# Long-Running Task File Processing
# ============================================================================

process_tasks() {
  local file="$1"
  [ -f "$file" ] || die "Task file not found: $file"

  local total=0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*#|^[[:space:]]*$ ]] && continue
    [[ "$line" =~ \[x\]|\[X\] ]] && continue
    total=$((total + 1))
  done < "$file"

  info "Processing $total tasks from $file"

  local task_num=0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*#|^[[:space:]]*$ ]] && continue
    [[ "$line" =~ \[x\]|\[X\] ]] && continue

    task_num=$((task_num + 1))

    local task="$line"
    task="${task#- \[ \] }"
    task="${task#- }"
    task="${task#\[ \] }"

    info "[$task_num/$total] $task"

    if [[ "$task" =~ ^delegate:([a-zA-Z0-9_-]+)[[:space:]]+(.+)$ ]]; then
      local agent="${BASH_REMATCH[1]}"
      local subtask="${BASH_REMATCH[2]}"
      local result
      result=$(delegate_to_agent "$agent" "$subtask") || true
      DELEGATE_CONTEXT="$result"
      info "Delegation to $agent complete. Context injected into next task."
    else
      PROMPT="$task"
      if [ "$LOOP" = true ]; then
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
agent-resume v$VERSION — Auto-resume AI agents through rate limits

USAGE
  agent-resume [options] [prompt]          Route to best agent, cascade on limit
  agent-resume status                      Show all agents and their status
  agent-resume delegate <agent> <task>     Run a task on a specific agent
  agent-resume tasks <file>                Process a task file

OPTIONS
  -c, --continue           Continue previous conversation (Claude)
  -r, --resume <id>        Resume a specific Claude session by ID
  -m, --model <model>      Force specific Claude model
  -f, --fallback <agent>   Preferred agent when primary is limited
  --order <a,b,c>          Custom cascade order (comma-separated agent names)
  --no-cascade             Don't cascade — only use the routed agent
  --loop                   Keep retrying through ALL agents until success
  --permission-mode <mode> Claude permission mode (auto, acceptEdits, bypassPermissions)
  --skip-permissions       Shorthand for --permission-mode bypassPermissions
  --log <file>             Log events to file
  --test <seconds>         Simulate rate limit with countdown
  -h, --help               Show help
  -v, --version            Show version
  -- <flags>               Forward remaining flags to Claude CLI

DEFAULT BEHAVIOR (routing)
  Probes all installed agents in tier order. Routes your task to the first
  one that's available. If it gets rate-limited mid-task, cascades to the next.

CASCADE ORDER (default, by quality tier)
  T1: Claude Opus, Gemini
  T2: Claude Sonnet, Codex
  T3: Claude Haiku, Copilot, Aider

  Override with: --order gemini,claude-opus,claude-sonnet,codex

AGENT NAMES
  claude-opus, claude-sonnet, claude-haiku, gemini, codex, copilot, aider

EXAMPLES
  agent-resume -c                                   # Route to best, resume
  agent-resume --loop -c "refactor auth module"     # Exhaust all agents
  agent-resume --order gemini,claude-opus -c        # Gemini first, then Opus
  agent-resume --no-cascade -m opus -c              # Opus only, wait if limited
  agent-resume status                               # Check all agents
  agent-resume delegate gemini "query Stitch data"  # Run on Gemini directly
  agent-resume tasks sprint.md --loop               # Process task queue

TASK FILE FORMAT
  - [ ] Refactor auth module to use JWT
  delegate:gemini Query Stitch for user signups
  - [ ] Update docs with Stitch data from above
  - [x] Already done (skipped)

ENVIRONMENT
  DEBUG=1    Enable debug output
EOF
}

[ "${TEST_MODE:-}" = "1" ] && return 0 2>/dev/null || true

# --- Parse subcommands ---
if [ "${1:-}" = "delegate" ]; then
  SUBCOMMAND="delegate"
  shift
  [ $# -lt 1 ] && die "Usage: agent-resume delegate <agent> <task>"
  DELEGATE_AGENT="$1"; shift
  [ $# -lt 1 ] && die "Usage: agent-resume delegate <agent> <task>"
  DELEGATE_TASK="$1"; shift
elif [ "${1:-}" = "tasks" ]; then
  SUBCOMMAND="tasks"
  shift
  [ $# -lt 1 ] && die "Usage: agent-resume tasks <file>"
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
    -f|--fallback)        USER_ORDER=("$2"); shift 2 ;;
    -m|--model)           MODEL="$2"; shift 2 ;;
    --order)              IFS=',' read -ra USER_ORDER <<< "$2"; shift 2 ;;
    --no-cascade)         CASCADE=false; shift ;;
    --loop)               LOOP=true; shift ;;
    --permission-mode)    PERM_MODE="${2:?--permission-mode requires a mode}"; shift 2 ;;
    --skip-permissions)   SKIP_PERMS=true; shift ;;
    --log)                LOG_FILE="${2:?--log requires a file path}"; shift 2 ;;
    --test)               TEST_SECS="${2:?--test requires seconds}"; shift 2 ;;
    -h|--help)            show_help; exit 0 ;;
    -v|--version)         echo "agent-resume v$VERSION"; exit 0 ;;
    --)                   shift; PASS_THROUGH_FLAGS+=("$@"); break ;;
    -*)                   die "Unknown option: $1" ;;
    *)                    PROMPT="$1"; shift ;;
  esac
done

# ============================================================================
# Execute
# ============================================================================

if [ "$SUBCOMMAND" = "delegate" ]; then
  delegate_to_agent "$DELEGATE_AGENT" "$DELEGATE_TASK"
  exit $?
fi

[ -n "$LOG_FILE" ] && log_event "SESSION_START: v$VERSION"

if [ "$SUBCOMMAND" = "status" ]; then
  show_status
  exit 0
fi

if [ "$SUBCOMMAND" = "tasks" ]; then
  start_caffeinate
  process_tasks "$TASK_FILE"
  exit $?
fi

# Prevent sleep for long-running operations
[ "$LOOP" = true ] && start_caffeinate

# Default: single run or loop
if [ "$LOOP" = true ]; then
  while true; do
    run_once
    ret=$?
    [ $ret -eq 0 ] && break
    if [ $ret -eq $RATE_LIMIT_EXIT ]; then
      info "Hit rate limit during execution. Re-running cascade..."
    else
      info "Exited with code $ret. Retrying in ${BUFFER_SECS}s..."
    fi
    sleep "$BUFFER_SECS"
  done
else
  run_once
fi
