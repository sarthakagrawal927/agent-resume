# claude-resume

Auto-resume Claude Code through rate limits with intelligent model cascading, exhaustive cross-agent fallback, inter-agent delegation, and long-running task queues.

One shell script. Zero required dependencies. macOS-first. 86 tests passing.

```
claude-resume --loop -c "finish the refactor"
```

Rate limited on Opus? It tries Sonnet. Sonnet limited? Haiku. All Claude models gone? Automatically tries every installed agent (Gemini, Codex, Copilot, Aider). Everything exhausted? Waits with a countdown, notifies you, and resumes. You walk away, it keeps working.

---

## Features

### Rate Limit Detection & Auto-Resume

The core feature. Detects Claude Code rate limits by parsing CLI output, shows a live countdown timer, and automatically resumes your conversation when the cooldown expires.

- Parses **3 known Claude output formats** for rate limit messages (unix timestamp, 12h time with AM/PM, timezone-aware formats)
- Live `HH:MM:SS` countdown in-terminal
- **macOS native notifications** via `osascript` when the limit lifts
- Configurable buffer time after reset (default 10s) to avoid hitting the limit again immediately

```bash
claude-resume -c                        # Check status, wait if needed, resume
claude-resume -c "finish the refactor"  # Resume with a specific prompt
```

### Model Cascading

When your current model (e.g. Opus) is rate-limited, automatically cascade through cheaper models before giving up:

```
Opus (limited) → Sonnet → Haiku → [all installed agents] → wait for reset
```

- Tries each model in order via `claude --model <model> -p 'check'`
- Switches transparently — your task continues on the first available model
- Disable with `--no-cascade` if you only want the exact model you specified

```bash
claude-resume -c                    # Default: cascade through all models
claude-resume -c --no-cascade       # Only use your current/specified model
claude-resume -c -m sonnet          # Start with Sonnet, cascade to Haiku if needed
```

### Exhaustive Agent Fallback

When **all** Claude models are rate-limited, the loop doesn't stop. It automatically detects and tries every installed AI agent on your system:

1. **Preferred fallback** (`-f gemini`) — tried first if specified
2. **Auto-detect** — scans for `gemini`, `codex`, `copilot`, `aider` CLIs
3. **Direct headless execution** — runs the agent with your prompt, captures output
4. **cli-continues fallback** — if the agent CLI isn't installed locally, attempts interactive handoff via [cli-continues](https://github.com/AidfulAI/cli-continues)

The loop only stops when **every installed model and agent is exhausted**.

```bash
claude-resume --loop -c                 # Try ALL installed agents automatically
claude-resume -f gemini --loop -c       # Prefer Gemini, then auto-detect others
```

### Inter-Agent Delegation

Run a specific task on another AI agent **headlessly**, capture its output, and inject the result as context into Claude's next task.

- Direct CLI execution — calls `gemini -p "task"`, `codex -p "task"`, etc.
- Real-time output streaming via `tee` — see what the delegate is doing
- Results automatically injected as context into the next Claude prompt
- Falls back to cli-continues interactive handoff if the agent CLI isn't installed locally

```bash
# Standalone delegation
claude-resume delegate gemini "query Stitch for user signup metrics last 30 days"
claude-resume delegate codex "generate a Python script to parse CSV files"

# Inside a task file (results flow into the next task automatically)
delegate:gemini Query Stitch for user signups
- [ ] Update the API docs with the Stitch data from above
```

**Use case**: Gemini can access Google Stitch, Claude can't. Delegate the data-fetching to Gemini, then have Claude process the results.

### Long-Running Task Queues

Process a file of tasks sequentially, with full rate-limit handling between each task. Walk away, come back to everything done.

- **Markdown task format** — use standard `- [ ]` checkboxes
- **Completed tasks skipped** — `- [x]` items are ignored on re-run
- **Inline delegation** — prefix a line with `delegate:<agent>` to run it on another AI
- **Context chaining** — delegation results are automatically injected into the next Claude task
- **Rate limit resilience** — with `--loop`, retries through rate limits on every task
- **Sleep prevention** — automatically runs `caffeinate` on macOS to prevent sleep during long runs

```bash
claude-resume tasks my-tasks.md --loop --skip-permissions
```

**Task file format:**

```markdown
# Sprint tasks — processed sequentially

- [ ] Refactor auth module to use JWT tokens
- [ ] Add unit tests for all auth endpoints
delegate:gemini Query Google Stitch for user signup metrics last 30 days
- [ ] Update the API docs with the Stitch data from above
- [ ] Set up rate limiting on public endpoints
- [x] Set up CI pipeline (already done, will be skipped)
```

### Status Command

Check the rate limit status of all Claude models and installed agents at a glance:

```bash
claude-resume status
```

```
claude-resume v1.2.0 — status

  opus         available
  sonnet       limited — resets 09:30:00
  haiku        available

  Agents:
  gemini       installed
  codex        not found
  copilot      not found
  aider        not found
  cli-continues not found
```

### Loop Mode

Keep retrying through repeated rate limits until the task succeeds. Exhausts **all** models and agents before waiting.

- Detects rate limits **during** Claude execution (not just before)
- Re-runs the full cascade on each retry (model cascade → agent fallback → wait)
- Works with both single prompts and task files
- Prevents macOS sleep via `caffeinate`

```bash
claude-resume --loop -c "get test coverage from 0% to 80%"
claude-resume tasks sprint.md --loop
```

### Permission Modes

Three tiers of permission control, from safest to most autonomous:

```bash
claude-resume -c                                # Default: Claude prompts for each action
claude-resume --permission-mode auto -c         # Claude decides based on risk
claude-resume --permission-mode acceptEdits -c  # Auto-approve edits, prompt for bash
claude-resume --skip-permissions -c             # Full unattended mode (no prompts)
```

`--permission-mode` maps to Claude's native permission system — safer than the blunt `--dangerously-skip-permissions`.

### Flag Pass-Through

Forward any flags directly to Claude CLI using `--`:

```bash
claude-resume -c -- --worktree myfeature       # Use git worktree
claude-resume -c -- --name "overnight-refactor" # Name the session
claude-resume -c -- --output-format stream-json # Stream JSON output
```

### Sleep Prevention

Long-running operations (loop mode, task files) automatically run `caffeinate -dims` on macOS to prevent your machine from sleeping. Cleaned up automatically on exit via signal handlers.

### Session Resume

Resume a specific Claude session by ID instead of just continuing the most recent one:

```bash
claude-resume -r 13fb9e25-976d-4dfb-8aea-299723ddb8c9 "keep going"
```

### Event Logging

Log all events (rate limits, cascades, fallbacks, session starts/ends) to a file:

```bash
claude-resume --log ~/claude-resume.log --loop -c
```

```
[2026-04-04 14:23:01] SESSION_START: v1.2.0
[2026-04-04 14:23:05] CHECK: model=default status=limited|1712234400
[2026-04-04 14:23:08] CASCADE: sonnet
[2026-04-04 14:23:10] RUN: claude --model sonnet... prompt=finish the refactor
[2026-04-04 14:45:32] RATE_LIMITED during execution
[2026-04-04 14:45:35] FALLBACK: gemini
[2026-04-04 14:45:40] FALLBACK_SUCCESS: gemini
[2026-04-04 14:45:40] SESSION_END
```

### Cross-Platform Timeout

macOS ships without GNU `timeout`. The script handles this transparently:

1. `gtimeout` (GNU coreutils via Homebrew) — preferred
2. `timeout` (Linux) — with `--foreground` flag fallback
3. Pure shell fallback — `background process + kill` for systems with neither

### Test / Simulation Mode

Dry-run the countdown and resume flow without actually hitting any rate limits:

```bash
claude-resume --test 5                  # Simulate a 5-second rate limit
claude-resume --test 60 -c              # 60-second simulation with conversation continue
```

### Debug Mode

See exactly what's happening under the hood:

```bash
DEBUG=1 claude-resume -c
```

---

## Installation

```bash
# Clone
git clone https://github.com/sarthakagrawal927/claude-resume.git
cd claude-resume

# Make executable
chmod +x claude-resume.sh

# Symlink to PATH
ln -s "$(pwd)/claude-resume.sh" /usr/local/bin/claude-resume
```

### Requirements

- **Claude Code CLI** (`claude`) — [install](https://claude.ai/code)
- **Bash 3+** (ships with macOS)

### Optional

- **cli-continues** — for cross-agent context handoff: `npm i -g continues`
- **Gemini CLI** — for delegation: [install](https://github.com/google-gemini/gemini-cli)
- **Codex CLI** — for delegation: `npm i -g @openai/codex`

---

## Usage

```
claude-resume [options] [prompt]          Resume or run Claude
claude-resume status                      Show rate limit status for all models
claude-resume delegate <agent> <task>     Delegate a task to another AI agent
claude-resume tasks <file>                Process a task file
```

### Options

| Flag | Description |
|------|-------------|
| `-c, --continue` | Continue previous Claude conversation |
| `-r, --resume <id>` | Resume a specific session by ID |
| `-f, --fallback <tool>` | Preferred fallback agent (tried first before auto-detect) |
| `-m, --model <model>` | Force a specific Claude model |
| `--no-cascade` | Disable automatic model cascade |
| `--loop` | Keep retrying through ALL available models/agents |
| `--permission-mode <mode>` | Claude permission mode (auto, acceptEdits, bypassPermissions) |
| `--skip-permissions` | Shorthand for `--permission-mode bypassPermissions` |
| `--log <file>` | Log events to file |
| `--test <seconds>` | Simulate a rate limit with an N-second countdown |
| `-- <flags>` | Forward remaining flags to Claude CLI |
| `-h, --help` | Show help |
| `-v, --version` | Show version |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `DEBUG=1` | Enable verbose debug output |

---

## How It Works

```
User runs: claude-resume --loop -c "finish the refactor"

1. Check current model (Opus by default)
   ├── OK → run Claude, done
   └── Rate limited →

2. Model cascade
   ├── Try Sonnet → OK? Run with Sonnet, done
   ├── Try Haiku → OK? Run with Haiku, done
   └── All Claude models limited →

3. Exhaustive agent fallback
   ├── Try Gemini (if installed) → completed? Done
   ├── Try Codex (if installed) → completed? Done
   ├── Try Copilot (if installed) → completed? Done
   ├── Try Aider (if installed) → completed? Done
   └── All agents exhausted →

4. Wait for reset
   ├── Parse reset timestamp from Claude output
   ├── Show live countdown timer
   ├── Send macOS notification when lifted
   └── Resume Claude

5. (--loop) If rate limited again during execution → go to 1
```

---

## Running Tests

```bash
bash test.sh
# 86 passed, 0 failed, 86 total
```

Tests cover: CLI arg parsing, rate limit format parsing (all 3 formats), `is_rate_limited` detection (8 positive + 4 negative patterns), task file processing, subcommand routing, edge cases, and `build_claude_cmd` array construction.

---

## Inspiration & Prior Art

This project was built from scratch after evaluating existing tools in the Claude Code automation space. Each solved a piece of the puzzle — claude-resume combines the best ideas into one cohesive tool.

### [claude-auto-resume](https://github.com/terryso/claude-auto-resume)

The original inspiration. A ~500-line shell script that detects rate limits, shows a countdown, and resumes. We rebuilt from scratch because:
- macOS support was broken (open PRs #19, #20, #21 unmerged)
- No model cascading — waits even when cheaper models are available
- No retry loop — one resume per invocation
- `--dangerously-skip-permissions` was the only mode

**What we took**: The core idea of output-parsing rate limit detection and countdown-based auto-resume.

### [cli-continues](https://github.com/AidfulAI/cli-continues)

Cross-tool context handoff. When rate-limited on one AI, seamlessly switch to another with your full conversation context preserved.

**What we took**: Cross-agent fallback concept. Integrated via `npx continues resume --in <tool>`.

### [claude-squad](https://github.com/smtg-ai/claude-squad)

Full TUI for managing multiple parallel Claude sessions with tmux isolation and git worktrees. 6,800+ stars.

**What we took**: The idea that model/session diversity is a resilience strategy.

### [continuous-claude](https://github.com/AnandChowdhary/continuous-claude)

Purpose-built for long autonomous loops with cost tracking via `--output-format stream-json`.

**What we took**: The task queue concept, and the insight that `caffeinate` is essential for overnight runs.

### [Claude-Autopilot](https://github.com/benbasha/Claude-Autopilot)

VS Code extension with task queuing, health monitoring, and error recovery.

**What we took**: Delegation results flowing as context between tasks, and sleep prevention.

### Native Claude Code Features

Claude Code now supports `--continue`, `--resume <session>`, `--model`, `--fallback-model` (overload only), `--permission-mode`, `--max-budget-usd`, and `--worktree`. These handle pieces of what we do, but can't orchestrate the full cascade + exhaustive fallback + delegation + task queue flow. Notably, `--fallback-model` only handles **overload**, not **rate limits** — that gap is our core differentiation.

---

## Roadmap

- [ ] **Cost tracking** — parse `total_cost_usd` from `--output-format stream-json`, enforce budget caps
- [ ] **Duration limits** — `--max-duration 2h` for time-boxed execution
- [ ] **Completion signals** — detect when the agent says "done" and stop the loop
- [ ] **Shared task notes** — persistent context file across loop iterations
- [ ] **Per-project config** — `.claude-resume.yml` for project-specific defaults
- [ ] **Homebrew formula** — `brew install claude-resume`

---

## License

MIT
