# agent-resume — Agent Context

## What this project is
A shell script that auto-resumes AI coding agents through rate limits with a unified quality-tiered cascade across Claude, Gemini, Codex, Copilot, and Aider.

**Status: Feature complete / archived.** The headless overnight automation use case works. The interactive cascade use case needs a desktop app architecture — see "Architectural ceiling" below.

## Architecture
- Single Bash script (`agent-resume.sh`)
- macOS-first (BSD date, no GNU timeout dependency)
- Agent registry: each agent has tier, CLI binary, probe command, headless flag, and rate limit patterns
- `tiers.json` provides benchmark scores; a GitHub Action auto-updates it from Aider's leaderboard data
- Smart routing by default (best available), cascade on rate limit
- Optional: cli-continues for interactive cross-agent context handoff

## Agent Registry Format
```
"tier|name|cli_cmd|probe_cmd|headless_flag|rate_limit_patterns..."
```

## Key patterns
- `run_timeout` — cross-platform timeout (gtimeout → timeout → pure shell)
- `probe_agent` — check if agent is available and not rate-limited
- `run_agent` — execute on any registered agent with proper flag mapping
- `get_cascade_order` — user-defined or default tier-sorted order
- `parse_reset_time` — handles 3 Claude output formats for countdown

## Conventions
- Functions return via stdout, errors to stderr
- Exit codes: 0=success, 1=error, 2=rate limited during execution
- Agent registry is the single source of truth for all agent metadata

## Architectural ceiling
This project hits a hard limit imposed by the CLI wrapper approach:

1. **Headless-only execution.** Every agent runs in `-p` mode, which strips interactive UX (file diffs, permission prompts, conversation flow). Fine for overnight runs, bad for interactive development.

2. **No context transfer on cascade.** When switching agents mid-task, the next agent gets only the original prompt. No knowledge of what the previous agent discovered, edited, or decided.

3. **Fragile rate limit detection.** All detection is regex on stderr/stdout text. Any agent changing their error format breaks detection silently. There is no stable "am I rate limited?" API.

4. **Slow probing.** Agents weren't designed to be health-checked. Probing is a lightweight prompt execution, not a status endpoint. Startup latency is noticeable with multiple agents.

The right architecture for interactive cascade is a background daemon/desktop app that watches real terminal sessions, injects context across agents, and shows native notifications with action buttons — not a CLI wrapper that takes over the terminal. The cascade concept is proven; the delivery mechanism needs to change. See [CodeVetter](https://github.com/sarthakagrawal927/codevetter) for that direction.
