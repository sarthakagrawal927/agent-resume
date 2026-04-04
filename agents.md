# claude-resume — Agent Context

## What this project is
A shell script that auto-resumes Claude Code after rate limits, with model cascading and cross-agent fallback.

## Architecture
- Single Bash script (`claude-resume.sh`)
- macOS-first (BSD date, no GNU timeout dependency)
- Optional integration with cli-continues (`npx continues`) for cross-agent context handoff
- Zero required external dependencies

## Key patterns
- `run_with_timeout` — cross-platform timeout (gtimeout → timeout → pure shell fallback)
- `parse_reset_time` — handles 3 known Claude output formats for rate limit messages
- Model cascade: Opus → Sonnet → Haiku before falling back to another agent
- Background countdown + macOS notification via osascript

## Conventions
- Keep it under 300 lines
- No unnecessary error messages or verbose output
- Functions return via stdout, errors to stderr
- Exit codes: 0=success, 1=error, 2=parse failure, 3=network error, 130=interrupted
