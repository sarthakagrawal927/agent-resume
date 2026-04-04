# Competing Tools Research — 2026-04-04

## Tier 1 — High value, should build

1. **Sleep prevention** — `caffeinate -dims &` on macOS. One line. Critical for overnight runs.
2. **Cost tracking** — parse `total_cost_usd` from `--output-format stream-json`
3. **Budget cap** (`--max-cost`) — trivial once cost tracking works. Claude also has native `--max-budget-usd`
4. **Duration limit** (`--max-duration`) — track elapsed time, stop after N hours
5. **Use `--permission-mode` instead of `--dangerously-skip-permissions`** — better security posture
6. **Forward unknown flags to `claude`** — good ergonomics, pass through anything we don't recognize
7. **Leverage native `--fallback-model`** for overload (separate from rate limit cascading)

## Tier 2 — Medium value, worth adding

8. **Shared task notes file** — persistent context across iterations (SHARED_TASK_NOTES.md)
9. **Completion signal detection** — grep for magic phrase, stop after N consecutive hits
10. **Health monitoring / hung process detection** — check if claude process is still alive
11. **Signal handling** — proper cleanup on SIGINT/SIGTERM, kill child processes
12. **Cross-tool context handoff doc** — generate markdown summary when falling back to another tool

## Tier 3 — Nice to have

13. **Per-project config file** (`.claude-resume.yml`)
14. **Structured run history/logging**
15. **Git worktree for parallel tasks** (Claude has native `-w`)

## Skip (different product category)

- Full TUI (claude-squad territory)
- VS Code extension (Claude-Autopilot territory)
- PR/CI automation (continuous-claude territory)
- 14-tool handoff (continues territory)
- PostgreSQL memory (Continuous-Claude-v3 territory)

## Key Claude CLI findings

- **`--profile` flag does NOT exist** in Claude Code v2.1.81. Our -P flag should instead use `--resume` with different session dirs or named configs.
- **`--fallback-model`** only handles overload, NOT rate limits. Our rate limit cascading is the core differentiation.
- **`--permission-mode auto`** is safer than `--dangerously-skip-permissions` — should offer this.
- **`--output-format stream-json`** gives `total_cost_usd` — enables cost tracking.
- **`--max-budget-usd`** exists natively but only in `--print` mode.
- **`--worktree` + `--tmux`** exists natively for parallel sessions.
- **`--name`** sets session display name.

## Rate limit formats (all 3 must be handled)

| Format | Pattern | Example |
|--------|---------|---------|
| Old | `Claude AI usage limit reached\|<unix_ts>` | `Claude AI usage limit reached\|1735689600` |
| New | `X-hour limit reached...resets Xam/pm` | `5-hour limit reached . resets 3am` |
| Newest | `You've hit your limit...resets Xam/pm (TZ)` | `You've hit your limit . resets 2am (Europe/Paris)` |
