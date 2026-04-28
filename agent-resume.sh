#!/bin/bash
# agent-resume — Run AI coding agents with rate-limit-aware cross-vendor cascade.
#
# Two modes:
#   1. Direct:  agent-resume "prompt"        — run prompt through cascade
#   2. Queue:   agent-resume queue            — solve GitHub issues, open a PR
#
# When the routed agent rate-limits, falls through to the next installed agent
# in tier order (T1 → T2 → T3). Single bash file, no required deps.

set -euo pipefail

VERSION="3.0.0"
RATE_LIMIT_EXIT=2
PROBE_TIMEOUT=15
BUFFER_SECS=10

# --- Globals ---
SUBCOMMAND=""
PROMPT=""
CONTINUE=false
LOOP=false
CASCADE=true
SKIP_PERMS=false

QUEUE_MAX_RETRIES=3
QUEUE_MAX_TURNS=50
QUEUE_ISSUE_IDS=""
QUEUE_FILTERS=()

AGENT_REGISTRY=()
LAST_AGENT_USED=""

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"

# ============================================================================
# Helpers
# ============================================================================

die()   { echo "Error: $1" >&2; exit "${2:-1}"; }
info()  { echo ":: $1"; }
warn()  { echo ":: (warn) $1" >&2; }
debug() { [ "${DEBUG:-}" = "1" ] && echo "[debug] $1" >&2 || true; }

fmt_time() {
  if date --version &>/dev/null 2>&1; then
    date -d "@$1" "+%H:%M:%S"
  else
    date -r "$1" "+%H:%M:%S"
  fi
}

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
    [ "$ret" -ge 128 ] && return 124
    return "$ret"
  fi
}

# ============================================================================
# Agent Registry
# ============================================================================
# Format: "tier|name|cli|probe_cmd|headless_flag|rate_limit_patterns..."
# Loaded from tiers.json if present, else hardcoded fallback.

load_registry() {
  local tiers_file="$SCRIPT_DIR/tiers.json"

  if [ -f "$tiers_file" ] && command -v jq &>/dev/null; then
    debug "Loading registry from $tiers_file"
    local count
    count=$(jq '.agents | length' "$tiers_file")
    for ((i=0; i<count; i++)); do
      local tier name cli probe headless patterns
      tier=$(jq -r ".agents[$i].tier" "$tiers_file")
      name=$(jq -r ".agents[$i].name" "$tiers_file")
      cli=$(jq -r ".agents[$i].cli" "$tiers_file")
      probe=$(jq -r ".agents[$i].probe" "$tiers_file")
      headless=$(jq -r ".agents[$i].headless" "$tiers_file")
      patterns=$(jq -r ".agents[$i].patterns" "$tiers_file")
      AGENT_REGISTRY+=("${tier}|${name}|${cli}|${probe}|${headless}|${patterns}")
    done
    return
  fi

  debug "Using hardcoded registry"
  AGENT_REGISTRY=(
    "1|claude-opus|claude|claude --model opus -p check|--model opus -p|usage limit.*reached|limit reached.*resets|hit your limit|out of.*(extra )?usage|rate.?limit"
    "1|gemini|gemini|gemini -p check|-p|RESOURCE_EXHAUSTED|RATE_LIMIT_EXCEEDED|QUOTA_EXHAUSTED|exhausted.*quota|quota.*exceeded|rate.?limit.*exceeded|429"
    "2|claude-sonnet|claude|claude --model sonnet -p check|--model sonnet -p|usage limit.*reached|limit reached.*resets|hit your limit|out of.*(extra )?usage|rate.?limit"
    "2|codex|codex|codex --version|exec|exceeded retry limit.*429|rate_limit_exceeded|429 Too Many|insufficient_quota"
    "3|claude-haiku|claude|claude --model haiku -p check|--model haiku -p|usage limit.*reached|limit reached.*resets|hit your limit|out of.*(extra )?usage|rate.?limit"
    "3|copilot|copilot|copilot --version|-p|rate_limited|you.ve exceeded|you have been rate-limited|Copilot token usage"
    "3|aider|aider|aider --version|--message --yes|RateLimitError|Retrying in [0-9]|rate_limit_error|429.*Too Many|exceeded.*quota"
  )
}
load_registry

reg_field()    { echo "$1" | cut -d'|' -f$(($2 + 1)); }
reg_tier()     { reg_field "$1" 0; }
reg_name()     { reg_field "$1" 1; }
reg_cli()      { reg_field "$1" 2; }
reg_probe()    { reg_field "$1" 3; }
reg_headless() { reg_field "$1" 4; }
reg_patterns() { echo "$1" | cut -d'|' -f6-; }

is_agent_rate_limited() {
  local output="$1" entry="$2"
  local patterns
  patterns=$(reg_patterns "$entry")
  [ -z "$patterns" ] && return 1
  echo "$output" | grep -qiE "$patterns"
}

is_installed() {
  command -v "$(reg_cli "$1")" &>/dev/null
}

get_cascade_order() {
  for entry in "${AGENT_REGISTRY[@]}"; do echo "$entry"; done
}

# ============================================================================
# Rate Limit Time Parsing (Claude-specific best-effort)
# ============================================================================

parse_reset_time() {
  local output="$1"

  if echo "$output" | grep -q "Claude AI usage limit reached|"; then
    echo "$output" | awk -F'|' '{print $2}' | grep -o '[0-9]*' | head -1
    return 0
  fi

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
  local reset_ts="${1:-}"
  if [ -n "$reset_ts" ] && [ "$reset_ts" -gt 0 ] 2>/dev/null; then
    local wait_secs=$((reset_ts - $(date +%s)))
    if [ "$wait_secs" -gt 0 ]; then
      info "Waiting until $(fmt_time "$reset_ts") for rate limit to lift..."
      countdown "$reset_ts"
      sleep "$BUFFER_SECS"
      return
    fi
  fi
  info "Couldn't parse reset time. Waiting 5 minutes..."
  sleep 300
}

# ============================================================================
# Build & run an agent command
# ============================================================================

build_cmd() {
  # Outputs the command as NUL-separated parts.
  # Caller reads with: while IFS= read -r -d '' part; do cmd+=("$part"); done
  # NUL is required because prompts contain newlines (queue prompts especially).
  local entry="$1" prompt="$2"
  local cli headless
  cli=$(reg_cli "$entry")
  headless=$(reg_headless "$entry")

  local cmd=("$cli")

  if [ "$cli" = "claude" ]; then
    cmd+=("--skip-git-repo-check")
    [ "$SKIP_PERMS" = true ] && cmd+=("--dangerously-skip-permissions")
    [ "$CONTINUE" = true ] && cmd+=("-c")
  elif [ "$cli" = "codex" ]; then
    cmd+=("--skip-git-repo-check")
  fi

  read -ra headless_parts <<< "$headless"
  cmd+=("${headless_parts[@]}")
  cmd+=("$prompt")

  printf '%s\0' "${cmd[@]}"
}

# Run an agent. If output_file given: redirect stdout+stderr there silently.
# Otherwise tee to terminal AND a temp file (for rate limit detection).
# Returns: agent exit code, or RATE_LIMIT_EXIT if output matches rate limit.
run_agent_one() {
  local entry="$1" prompt="$2" output_file="${3:-}"
  local name
  name=$(reg_name "$entry")

  # Build command into an array (NUL-separated to preserve newlines in prompt)
  local cmd=()
  while IFS= read -r -d '' part; do cmd+=("$part"); done < <(build_cmd "$entry" "$prompt")

  info "Running on $name [T$(reg_tier "$entry")]..."
  LAST_AGENT_USED="$name"

  local capture
  if [ -n "$output_file" ]; then
    capture="$output_file"
    set +e
    "${cmd[@]}" > "$capture" 2>&1
    local ret=$?
    set -e
  else
    capture=$(mktemp)
    set +e
    "${cmd[@]}" 2>&1 | tee "$capture"
    local ret=${PIPESTATUS[0]}
    set -e
    stty sane 2>/dev/null || true
    printf '\033[0m' 2>/dev/null || true
  fi

  if is_agent_rate_limited "$(cat "$capture")" "$entry"; then
    [ -z "$output_file" ] && rm -f "$capture"
    return $RATE_LIMIT_EXIT
  fi

  [ -z "$output_file" ] && rm -f "$capture"
  return $ret
}

# Run cascade. Args:
#   $1 = prompt
#   $2 = output_file (empty = tee to terminal)
#   $3 = min_tier (empty = no filter; e.g. "2" means skip T1)
# Returns: agent exit code, or RATE_LIMIT_EXIT if all rate-limited
cascade_run() {
  local prompt="$1" output_file="${2:-}" min_tier="${3:-}"

  local entries=()
  while IFS= read -r entry; do
    is_installed "$entry" || continue
    if [ -n "$min_tier" ]; then
      [ "$(reg_tier "$entry")" -lt "$min_tier" ] && continue
    fi
    entries+=("$entry")
  done < <(get_cascade_order)

  [ ${#entries[@]} -eq 0 ] && die "No installed AI agents matching tier filter."

  for entry in "${entries[@]}"; do
    set +e
    run_agent_one "$entry" "$prompt" "$output_file"
    local ret=$?
    set -e

    [ $ret -ne $RATE_LIMIT_EXIT ] && return $ret

    info "$(reg_name "$entry") hit rate limit."
    [ "$CASCADE" != true ] && return $RATE_LIMIT_EXIT
    info "Cascading to next agent..."
  done

  return $RATE_LIMIT_EXIT
}

# ============================================================================
# Status — show all agents and probe availability in parallel
# ============================================================================

probe_agent() {
  local entry="$1"
  local probe_cmd
  probe_cmd=$(reg_probe "$entry")

  case "$probe_cmd" in
    claude*) probe_cmd="${probe_cmd/claude/claude --skip-git-repo-check}" ;;
  esac

  local output
  output=$(run_timeout "$PROBE_TIMEOUT" $probe_cmd 2>&1) || true

  if is_agent_rate_limited "$output" "$entry"; then
    local ts
    ts=$(parse_reset_time "$output" 2>/dev/null) && echo "limited|$ts" || echo "limited"
  else
    echo "ok"
  fi
}

show_status() {
  echo "agent-resume v$VERSION — status"
  echo ""

  local probe_dir
  probe_dir=$(mktemp -d)
  local entries=() idx=0

  while IFS= read -r entry; do
    entries+=("$entry")
    if is_installed "$entry"; then
      ( probe_agent "$entry" > "$probe_dir/$idx" ) &
    fi
    idx=$((idx + 1))
  done < <(get_cascade_order)

  echo "Probing ${#entries[@]} agents..."
  wait 2>/dev/null || true

  for i in "${!entries[@]}"; do
    local entry="${entries[$i]}"
    local name tier
    name=$(reg_name "$entry")
    tier=$(reg_tier "$entry")

    if ! is_installed "$entry"; then
      printf "  [T%s] %-16s %s\n" "$tier" "$name" "not installed"
      continue
    fi

    local status
    status=$(cat "$probe_dir/$i" 2>/dev/null || echo "limited")
    if [ "$status" = "ok" ]; then
      printf "  [T%s] %-16s %s\n" "$tier" "$name" "✓ available"
    elif [[ "$status" == limited\|* ]]; then
      printf "  [T%s] %-16s %s\n" "$tier" "$name" "✗ limited — resets $(fmt_time "${status#limited|}")"
    else
      printf "  [T%s] %-16s %s\n" "$tier" "$name" "✗ limited"
    fi
  done

  rm -rf "$probe_dir"
}

# ============================================================================
# Direct mode — single prompt via cascade, optional --loop
# ============================================================================

run_direct() {
  if [ "$LOOP" = true ]; then
    while true; do
      set +e
      cascade_run "$PROMPT" ""
      local ret=$?
      set -e
      [ $ret -eq 0 ] && break
      if [ $ret -eq $RATE_LIMIT_EXIT ]; then
        info "All agents rate limited. Waiting before retry..."
        sleep 300
      else
        info "Agent exited with code $ret. Retrying in ${BUFFER_SECS}s..."
        sleep "$BUFFER_SECS"
      fi
    done
  else
    cascade_run "$PROMPT" ""
  fi
}

# ============================================================================
# Queue — solve GitHub issues with cross-agent cascade
# ============================================================================
# Adapted from https://github.com/nilbuild/claude-queue (MIT) — Claude-only
# `claude -p` calls swapped for our cascade so a rate limit doesn't stall a run.

QUEUE_DATE=""
QUEUE_TIMESTAMP=""
QUEUE_BRANCH=""
QUEUE_LOG_DIR=""
QUEUE_LABEL_PROGRESS="agent-resume:in-progress"
QUEUE_LABEL_SOLVED="agent-resume:solved"
QUEUE_LABEL_FAILED="agent-resume:failed"
QUEUE_SOLVED=()
QUEUE_FAILED=()
QUEUE_SKIPPED=()
QUEUE_CURRENT_ISSUE=""
QUEUE_START_TIME=0

q_log()       { echo ":: [queue] $1"; }
q_warn()      { echo ":: [queue] (warn) $1" >&2; }
q_error()     { echo ":: [queue] (error) $1" >&2; }
q_success()   { echo ":: [queue] ✓ $1"; }
q_header()    { echo ""; echo "═══ $1 ═══"; echo ""; }

queue_cleanup() {
  if [ -n "$QUEUE_CURRENT_ISSUE" ]; then
    q_warn "Interrupted while working on issue #${QUEUE_CURRENT_ISSUE}"
    gh issue edit "$QUEUE_CURRENT_ISSUE" --remove-label "$QUEUE_LABEL_PROGRESS" 2>/dev/null || true
    gh issue edit "$QUEUE_CURRENT_ISSUE" --add-label "$QUEUE_LABEL_FAILED" 2>/dev/null || true
  fi
  [ -d "$QUEUE_LOG_DIR" ] && q_log "Logs: ${QUEUE_LOG_DIR}"
}

queue_preflight() {
  q_header "Preflight"

  local failed=false
  for cmd in gh git jq; do
    if command -v "$cmd" &>/dev/null; then
      q_log "  $cmd ... found"
    else
      q_error "  $cmd ... NOT FOUND"; failed=true
    fi
  done

  local any=false
  for entry in "${AGENT_REGISTRY[@]}"; do
    is_installed "$entry" && { any=true; break; }
  done
  if [ "$any" = true ]; then
    q_log "  ai agent ... at least one installed"
  else
    q_error "  ai agent ... none of claude/gemini/codex/copilot/aider installed"
    failed=true
  fi

  if gh auth status &>/dev/null; then
    q_log "  gh auth ... ok"
  else
    q_error "  gh auth ... not authenticated"; failed=true
  fi

  if git rev-parse --is-inside-work-tree &>/dev/null; then
    q_log "  git repo ... ok"
  else
    q_error "  git repo ... not inside a git repository"; failed=true
  fi

  if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
    q_log "  working tree ... clean"
  else
    q_error "  working tree ... dirty (commit or stash first)"; failed=true
  fi

  [ "$failed" = true ] && die "Preflight failed."

  mkdir -p "$QUEUE_LOG_DIR"
  q_log "  log dir ... ${QUEUE_LOG_DIR}"
}

queue_ensure_labels() {
  q_log "Ensuring labels exist..."
  gh label create "$QUEUE_LABEL_PROGRESS" --color "fbca04" --description "agent-resume in progress" --force 2>/dev/null || true
  gh label create "$QUEUE_LABEL_SOLVED"   --color "0e8a16" --description "Solved by agent-resume"   --force 2>/dev/null || true
  gh label create "$QUEUE_LABEL_FAILED"   --color "d93f0b" --description "agent-resume failed"      --force 2>/dev/null || true
}

queue_setup_branch() {
  q_header "Branch Setup"
  local default_branch
  default_branch=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name')
  q_log "Default branch: ${default_branch}"
  git fetch origin "$default_branch" --quiet

  if git show-ref --verify --quiet "refs/heads/${QUEUE_BRANCH}"; then
    q_warn "Branch ${QUEUE_BRANCH} exists, adding timestamp"
    QUEUE_BRANCH="${QUEUE_BRANCH}-${QUEUE_TIMESTAMP}"
  fi

  git checkout -b "$QUEUE_BRANCH" "origin/${default_branch}" --quiet
  q_success "Created branch: ${QUEUE_BRANCH}"
}

queue_fetch_issues() {
  local args=(--state open --json "number,title,body,labels" --limit 200 --search "sort:created-asc")
  for filter in "${QUEUE_FILTERS[@]}"; do
    args+=(--label "$filter")
  done
  gh issue list "${args[@]}"
}

queue_fetch_specific() {
  local ids_str="$1"
  local result="["
  local first=true

  IFS=',' read -ra ids <<< "$ids_str"
  for id in "${ids[@]}"; do
    id=$(echo "$id" | xargs)
    local num
    num=$(echo "$id" | grep -oE '[0-9]+$' || echo "")
    [ -z "$num" ] && { q_error "Invalid issue id: $id"; continue; }

    local data
    data=$(gh issue view "$num" --json "number,title,body,labels" 2>/dev/null) || {
      q_error "Could not fetch issue #${num}"; continue
    }
    [ "$first" = true ] && first=false || result+=","
    result+="$data"
  done
  result+="]"
  echo "$result"
}

queue_build_prompt() {
  local issue_number="$1"
  local custom=""
  if [ -f ".agent-resume" ]; then
    custom="

Project-specific instructions:
$(cat .agent-resume)"
  fi

  cat <<EOF
You are an automated assistant solving a GitHub issue in this repository.

First read the full issue:
  gh issue view ${issue_number}

Then:
1. Explore the codebase to understand structure and conventions
2. Implement a complete, correct fix
3. Run existing tests to verify your fix doesn't break anything
4. Fix tests broken by your changes

Rules:
- Do NOT create git commits
- Do NOT push anything
- Match existing code style
- Only change what's necessary to solve the issue
${custom}
If this issue does NOT require code changes (question, finding, external action),
output a line saying AGENT_RESUME_NO_CODE followed by what should happen instead.

Otherwise when done, output a line saying AGENT_RESUME_SUMMARY followed by 2-3
sentences describing what changed and why.
EOF
}

queue_process_issue() {
  local num="$1" title="$2"
  local attempt=0 solved=false
  local issue_log="${QUEUE_LOG_DIR}/issue-${num}.md"
  local checkpoint
  checkpoint=$(git rev-parse HEAD)

  QUEUE_CURRENT_ISSUE="$num"
  q_header "Issue #${num}: ${title}"

  gh issue edit "$num" --remove-label "$QUEUE_LABEL_SOLVED" --remove-label "$QUEUE_LABEL_FAILED" 2>/dev/null || true
  gh issue edit "$num" --add-label "$QUEUE_LABEL_PROGRESS" 2>/dev/null || true

  {
    echo "# Issue #${num}: ${title}"
    echo ""
    echo "**Started:** $(date)"
    echo ""
  } > "$issue_log"

  local prompt
  prompt=$(queue_build_prompt "$num")

  # Force --skip-permissions for queue mode (no interactive)
  local saved_skip="$SKIP_PERMS"
  SKIP_PERMS=true

  while [ "$attempt" -lt "$QUEUE_MAX_RETRIES" ] && [ "$solved" = false ]; do
    attempt=$((attempt + 1))
    q_log "Attempt ${attempt}/${QUEUE_MAX_RETRIES}"

    git reset --hard "$checkpoint" --quiet 2>/dev/null || true
    git clean -fd --quiet 2>/dev/null || true

    {
      echo "## Attempt ${attempt}"
      echo ""
    } >> "$issue_log"

    local attempt_log="${QUEUE_LOG_DIR}/issue-${num}-attempt-${attempt}.log"
    set +e
    cascade_run "$prompt" "$attempt_log" ""
    local ret=$?
    set -e

    if [ "$ret" -eq "$RATE_LIMIT_EXIT" ]; then
      q_warn "All agents rate limited. Waiting before retry..."
      sleep "$BUFFER_SECS"
      continue
    fi

    if [ "$ret" -ne 0 ]; then
      q_warn "${LAST_AGENT_USED} exited with code ${ret}"
      echo "**${LAST_AGENT_USED} exited code ${ret}**" >> "$issue_log"
      continue
    fi

    if grep -q "AGENT_RESUME_NO_CODE" "$attempt_log" 2>/dev/null; then
      local reason
      reason=$(grep -A 20 "AGENT_RESUME_NO_CODE" "$attempt_log" | tail -n +2 | head -10)
      q_log "Issue does not require code changes"
      {
        echo "### No code changes required (via ${LAST_AGENT_USED})"
        echo "$reason"
        echo ""
      } >> "$issue_log"
      solved=true
      q_success "Issue #${num} handled (no code changes)"
      break
    fi

    local changed
    changed=$(git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)
    if [ -z "$changed" ]; then
      q_warn "No file changes detected"
      echo "**No file changes (via ${LAST_AGENT_USED})**" >> "$issue_log"
      continue
    fi

    q_success "Changes detected (via ${LAST_AGENT_USED}):"
    while IFS= read -r f; do q_log "  ${f}"; done <<< "$changed"

    local summary
    summary=$(grep -A 20 "AGENT_RESUME_SUMMARY" "$attempt_log" 2>/dev/null | tail -n +2 | head -10 || echo "No summary provided.")

    {
      echo "### Summary (via ${LAST_AGENT_USED})"
      echo "$summary"
      echo ""
      echo "### Changed files"
      while IFS= read -r f; do echo "- \`${f}\`"; done <<< "$changed"
      echo ""
    } >> "$issue_log"

    git add -A
    git commit -m "fix: resolve #${num} - ${title}

Automated fix by agent-resume (via ${LAST_AGENT_USED}).
Closes #${num}" --quiet

    solved=true
    q_success "Solved issue #${num} on attempt ${attempt}"
  done

  SKIP_PERMS="$saved_skip"
  gh issue edit "$num" --remove-label "$QUEUE_LABEL_PROGRESS" 2>/dev/null || true

  {
    echo "**Finished:** $(date)"
    echo "**Status:** $([ "$solved" = true ] && echo "SOLVED" || echo "FAILED")"
  } >> "$issue_log"

  if [ "$solved" = true ]; then
    gh issue edit "$num" --add-label "$QUEUE_LABEL_SOLVED" 2>/dev/null || true
    gh issue comment "$num" --body-file "$issue_log" 2>/dev/null || true
    QUEUE_SOLVED+=("${num}|${title}")
  else
    gh issue edit "$num" --add-label "$QUEUE_LABEL_FAILED" 2>/dev/null || true
    gh issue comment "$num" --body "agent-resume failed after ${QUEUE_MAX_RETRIES} attempts." 2>/dev/null || true
    QUEUE_FAILED+=("${num}|${title}")
    git reset --hard "$checkpoint" --quiet 2>/dev/null || true
    git clean -fd --quiet 2>/dev/null || true
  fi

  QUEUE_CURRENT_ISSUE=""
}

queue_review() {
  q_header "Final review pass"
  local review_log="${QUEUE_LOG_DIR}/review.log"

  local prompt="You are doing a final review on automated changes in this repo.

Examine all uncommitted and recently-committed changes on this branch.
For each modified file:
1. Read the full file
2. Look for bugs, incomplete implementations, missed edge cases, style issues
3. Fix only real problems (not style preferences)

Rules:
- Do NOT create git commits
- Do NOT push
- Match existing code style

When done output AGENT_RESUME_REVIEW followed by a brief summary."

  local saved_skip="$SKIP_PERMS"
  SKIP_PERMS=true
  set +e
  cascade_run "$prompt" "$review_log" "2"
  set -e
  SKIP_PERMS="$saved_skip"

  local changed
  changed=$(git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)
  if [ -n "$changed" ]; then
    q_success "Review made fixes (via ${LAST_AGENT_USED}):"
    while IFS= read -r f; do q_log "  ${f}"; done <<< "$changed"
    git add -A
    git commit -m "chore: final review pass

Review by agent-resume (via ${LAST_AGENT_USED})." --quiet
  else
    q_log "Review found nothing to fix"
  fi
}

queue_create_pr() {
  q_header "Creating Pull Request"

  local default_branch
  default_branch=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name')
  local elapsed=$(( $(date +%s) - QUEUE_START_TIME ))
  local duration="$((elapsed/3600))h $(((elapsed%3600)/60))m $((elapsed%60))s"
  local pr_body="${QUEUE_LOG_DIR}/pr-body.md"
  local total=$(( ${#QUEUE_SOLVED[@]} + ${#QUEUE_FAILED[@]} ))

  {
    echo "## agent-resume Run Summary"
    echo ""
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Date | ${QUEUE_DATE} |"
    echo "| Duration | ${duration} |"
    echo "| Issues processed | ${total} |"
    echo "| Solved | ${#QUEUE_SOLVED[@]} |"
    echo "| Failed | ${#QUEUE_FAILED[@]} |"
    echo "| Skipped | ${#QUEUE_SKIPPED[@]} |"
    echo ""

    if [ ${#QUEUE_SOLVED[@]} -gt 0 ]; then
      echo "### Solved"; echo ""; echo "| # | Title |"; echo "|---|-------|"
      for e in "${QUEUE_SOLVED[@]}"; do echo "| #${e%%|*} | ${e#*|} |"; done
      echo ""
    fi

    if [ ${#QUEUE_FAILED[@]} -gt 0 ]; then
      echo "### Failed"; echo ""; echo "| # | Title |"; echo "|---|-------|"
      for e in "${QUEUE_FAILED[@]}"; do echo "| #${e%%|*} | ${e#*|} |"; done
      echo ""
    fi

    echo "---"; echo ""; echo "### Per-issue logs"; echo ""
    for f in "${QUEUE_LOG_DIR}"/issue-*.md; do
      [ -f "$f" ] || continue
      local n
      n=$(basename "$f" | grep -oE '[0-9]+')
      echo "<details><summary>Issue #${n}</summary>"
      echo ""
      head -c 40000 "$f"
      echo ""
      echo "</details>"
      echo ""
    done
  } > "$pr_body"

  local size
  size=$(wc -c < "$pr_body")
  if [ "$size" -gt 60000 ]; then
    q_warn "PR body ${size} bytes — truncating"
    head -c 59000 "$pr_body" > "${pr_body}.tmp"
    {
      echo ""
      echo "---"
      echo "*Truncated. Full logs: ${QUEUE_LOG_DIR}*"
    } >> "${pr_body}.tmp"
    mv "${pr_body}.tmp" "$pr_body"
  fi

  git push origin "$QUEUE_BRANCH" --quiet
  q_success "Pushed ${QUEUE_BRANCH}"

  local pr_url
  pr_url=$(gh pr create \
    --base "$default_branch" \
    --head "$QUEUE_BRANCH" \
    --title "agent-resume: Automated fixes (${QUEUE_DATE})" \
    --body-file "$pr_body")

  q_success "PR: ${pr_url}"
}

cmd_queue() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --issue)       QUEUE_ISSUE_IDS="$2"; shift 2 ;;
      --max-retries) QUEUE_MAX_RETRIES="$2"; shift 2 ;;
      --max-turns)   QUEUE_MAX_TURNS="$2"; shift 2 ;;
      --label)       QUEUE_FILTERS+=("$2"); shift 2 ;;
      --no-cascade)  CASCADE=false; shift ;;
      -h|--help)     show_queue_help; exit 0 ;;
      *)             die "Unknown queue option: $1" ;;
    esac
  done

  QUEUE_DATE=$(date +%Y-%m-%d)
  QUEUE_TIMESTAMP=$(date +%H%M%S)
  QUEUE_BRANCH="agent-resume/${QUEUE_DATE}"
  QUEUE_LOG_DIR="/tmp/agent-resume-queue-${QUEUE_DATE}-${QUEUE_TIMESTAMP}"
  QUEUE_START_TIME=$(date +%s)

  trap queue_cleanup EXIT

  echo ""
  echo "agent-resume queue v${VERSION}"
  echo ""

  queue_preflight
  queue_ensure_labels
  queue_setup_branch

  q_header "Fetching Issues"
  local issues
  if [ -n "$QUEUE_ISSUE_IDS" ]; then
    q_log "Fetching: ${QUEUE_ISSUE_IDS}"
    issues=$(queue_fetch_specific "$QUEUE_ISSUE_IDS")
  else
    issues=$(queue_fetch_issues)
  fi
  local total
  total=$(echo "$issues" | jq length)

  [ "$total" -eq 0 ] && { q_log "No open issues."; exit 0; }
  q_log "Found ${total} open issue(s)"

  for i in $(seq 0 $((total - 1))); do
    local num title labels
    num=$(echo "$issues" | jq -r ".[$i].number")
    title=$(echo "$issues" | jq -r ".[$i].title")
    labels=$(echo "$issues" | jq -r "[.[$i].labels[].name] | join(\",\")" 2>/dev/null || echo "")

    if [ -z "$QUEUE_ISSUE_IDS" ] && echo "$labels" | grep -q "agent-resume:"; then
      q_log "Skipping #${num} (already labeled)"
      QUEUE_SKIPPED+=("${num}|${title}")
      continue
    fi

    queue_process_issue "$num" "$title" || true
  done

  if [ ${#QUEUE_SOLVED[@]} -gt 0 ]; then
    queue_review
    queue_create_pr
  else
    q_warn "No issues solved. No PR created."
  fi

  q_header "Queue complete"
  local elapsed=$(( $(date +%s) - QUEUE_START_TIME ))
  q_log "Duration: $((elapsed/3600))h $(((elapsed%3600)/60))m $((elapsed%60))s"
  q_success "Solved: ${#QUEUE_SOLVED[@]}"
  [ ${#QUEUE_FAILED[@]} -gt 0 ]  && q_error "Failed: ${#QUEUE_FAILED[@]}"
  [ ${#QUEUE_SKIPPED[@]} -gt 0 ] && q_warn  "Skipped: ${#QUEUE_SKIPPED[@]}"
  q_log "Logs: ${QUEUE_LOG_DIR}"
}

# ============================================================================
# CLI
# ============================================================================

show_help() {
  cat <<EOF
agent-resume v$VERSION — AI agents with cross-vendor cascade

USAGE
  agent-resume [options] "prompt"   Run prompt through cascade
  agent-resume queue [options]       Solve GitHub issues, open a PR
  agent-resume status                Show installed agents

DIRECT MODE OPTIONS
  -c, --continue          Continue Claude conversation
  --no-cascade            Don't cascade — only use the routed agent
  --loop                  Keep retrying until success
  --skip-permissions      Pass --dangerously-skip-permissions to Claude
  -h, --help              Show this help
  -v, --version           Show version

QUEUE MODE OPTIONS
  --issue ID              Solve specific issue(s) (ID, URL, or comma-separated)
  --max-retries N         Retries per issue (default: 3)
  --max-turns N           Max Claude turns per attempt (default: 50)
  --label LABEL           Only process issues with this label (repeatable)
  --no-cascade            Don't cascade — only use the routed agent

CASCADE ORDER (by quality tier)
  T1: claude-opus, gemini
  T2: claude-sonnet, codex
  T3: claude-haiku, copilot, aider

EXAMPLES
  agent-resume "fix the auth bug"
  agent-resume --loop --skip-permissions "get coverage to 80%"
  agent-resume queue
  agent-resume queue --issue 42
  agent-resume queue --label bug
  agent-resume status

PER-PROJECT QUEUE CONFIG
  Drop a .agent-resume file in repo root with extra prompt instructions.
EOF
}

show_queue_help() {
  cat <<EOF
agent-resume queue — Solve GitHub issues with cross-agent cascade

USAGE
  agent-resume queue [options]

OPTIONS
  --issue ID              Solve specific issue(s) (ID, URL, or comma-separated)
  --max-retries N         Retries per issue (default: 3)
  --max-turns N           Max Claude turns per attempt (default: 50)
  --label LABEL           Only process issues with this label (repeatable)
  --no-cascade            Don't cascade — only use the routed agent
  -h, --help              Show this help

REQUIREMENTS
  gh, git, jq, plus at least one of: claude, gemini, codex, copilot, aider
  Authenticated gh; clean working tree

WORKFLOW
  1. Verifies dependencies + clean tree
  2. Creates branch agent-resume/YYYY-MM-DD off default
  3. For each open issue: cascade through agents until solved
  4. Final review pass (T2+ agents only)
  5. Pushes branch and opens PR
EOF
}

[ "${TEST_MODE:-}" = "1" ] && return 0 2>/dev/null || true

# --- Subcommand dispatch ---
if [ "${1:-}" = "status" ]; then
  shift
  show_status
  exit 0
elif [ "${1:-}" = "queue" ]; then
  shift
  if [ "${1:-}" = "create" ]; then
    die "queue create has been removed — write issues directly with 'gh issue create' or via your editor."
  fi
  cmd_queue "$@"
  exit $?
fi

# --- Direct mode flag parsing ---
while [[ $# -gt 0 ]]; do
  case $1 in
    -c|--continue)        CONTINUE=true; shift ;;
    --no-cascade)         CASCADE=false; shift ;;
    --loop)               LOOP=true; shift ;;
    --skip-permissions)   SKIP_PERMS=true; shift ;;
    -h|--help)            show_help; exit 0 ;;
    -v|--version)         echo "agent-resume v$VERSION"; exit 0 ;;
    -*)                   die "Unknown option: $1" ;;
    *)                    PROMPT="$1"; shift ;;
  esac
done

if [ -z "$PROMPT" ] && [ "$CONTINUE" = false ]; then
  cat >&2 <<'EOF'
Error: No prompt provided.

Usage:
  agent-resume "fix the auth bug"
  agent-resume -c "continue what we started"
  agent-resume queue
  agent-resume status

Run 'agent-resume --help' for all options.
EOF
  exit 1
fi

# When -c with no prompt, give Claude an empty continuation
[ -z "$PROMPT" ] && [ "$CONTINUE" = true ] && PROMPT="continue"

run_direct
