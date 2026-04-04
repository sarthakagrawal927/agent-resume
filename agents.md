# agent-resume — Agent Context

## What this project is
A shell script that auto-resumes AI coding agents through rate limits with a unified quality-tiered cascade across Claude, Gemini, Codex, Copilot, and Aider.

## Architecture
- Single Bash script (`agent-resume.sh`)
- macOS-first (BSD date, no GNU timeout dependency)
- Agent registry: each agent has tier, CLI binary, probe command, headless flag, and rate limit patterns
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
