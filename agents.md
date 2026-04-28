# agents.md — agent-resume

## Purpose
Single-file Bash CLI. Runs AI coding agents through a cross-vendor cascade so a rate limit on one agent doesn't stall a run. Two modes: `direct` (run a prompt) and `queue` (solve open GitHub issues, open a PR).

## Stack
- Language: Bash 3+ (macOS-first; BSD date, no GNU timeout dependency)
- Testing: `bash test.sh` (~76 tests, pure-bash framework)
- Deploy: install.sh + symlink to `/usr/local/bin` or `~/.local/bin`
- Required deps: none beyond at least one AI CLI
- Queue mode also requires: `gh`, `git`, `jq`

## Repo structure
```
agent-resume.sh     # Single entry point — all logic here
install.sh          # curl-able installer
test.sh             # Test suite (sources script via TEST_MODE=1)
tiers.json          # Agent benchmark scores; auto-updated via GitHub Action
docs/               # Static landing page (separate concern)
plans/              # Archived planning docs
.github/workflows/  # update-tiers.yml — refreshes tiers.json from Aider leaderboard
```

## Key commands
```bash
bash test.sh                                  # full suite
bash agent-resume.sh status                   # probe installed agents
bash agent-resume.sh "fix the auth bug"       # direct cascade
bash agent-resume.sh --loop "..."             # exhaust all agents, retry
bash agent-resume.sh queue                    # solve open GitHub issues
bash agent-resume.sh queue --issue 42         # one issue
bash agent-resume.sh queue --label bug        # filter
```

## Architecture notes
- **Single file**, no source/include — everything in `agent-resume.sh`
- **Agent registry format**: `"tier|name|cli_cmd|probe_cmd|headless_flag|rate_limit_patterns..."` (loaded from `tiers.json` if present, else hardcoded fallback)
- **Cascade order**: T1 (Opus, Gemini) → T2 (Sonnet, Codex) → T3 (Haiku, Copilot, Aider). Walks down on rate limit; `--no-cascade` disables.
- **Rate-limit detection**: regex on combined stdout+stderr per-agent. Fragile by design — no stable API exists.
- **`run_agent_one`** is the single executor. Two output modes: tee to terminal (direct mode) or redirect to file (queue mode).
- **`cascade_run`** wraps it with cascade logic + optional `min_tier` filter (queue review pass uses `min_tier=2` to skip T1 and save quota).
- **`build_cmd`** centralizes per-agent flag construction (Claude needs `--skip-git-repo-check` + optional `--dangerously-skip-permissions` + `-c`; Codex needs `--skip-git-repo-check`; others stay raw).
- **`parse_reset_time`** handles 3 Claude formats (unix timestamp, 12h time, tz-aware).
- **Queue mode** is adapted from [claude-queue](https://github.com/nilbuild/claude-queue) (MIT). Workflow: preflight → branch → loop issues → cascade-solve → label state machine (`agent-resume:in-progress` / `:solved` / `:failed`) → review pass (T2+) → PR.
- **Queue prompts** use sentinel markers `AGENT_RESUME_NO_CODE` and `AGENT_RESUME_SUMMARY` to detect outcome — keep these stable; tests + grep depend on them.
- **Per-project config**: `.agent-resume` file in repo root is appended to every queue prompt as extra instructions.
- **Exit codes**: 0=success, 1=error/usage, 2=`RATE_LIMIT_EXIT` (rate-limited mid-execution).
- **Test mode**: `TEST_MODE=1 source agent-resume.sh` returns before CLI dispatch — exposes all functions for the test framework to call directly.

## Removed (was buggy / over-featured)
- `delegate <agent> <task>` subcommand
- `tasks <markdown_file>` subcommand (queue replaces it)
- `queue create` (text-to-issues; brittle JSON extraction from agent output)
- Flags: `-m/--model`, `-r/--resume`, `-f/--fallback`, `--order`, `--permission-mode`, `--log`, `--test`, `--` pass-through, cli-continues integration

If anyone is tempted to bring these back: the failure mode was always parsing-fragility or scope creep. Keep the surface small.

## Active context
