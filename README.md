# agent-resume

**Status: Feature Complete / Archived**

Auto-resume AI coding agents through rate limits. Unified cascade across Claude, Gemini, Codex, Copilot, and Aider — ordered by quality tier, with per-agent rate limit detection.

One shell script. Zero required dependencies. macOS-first. 93 tests passing.

```bash
agent-resume --loop -c "finish the refactor"
```

Smart routing finds the best available agent. When it hits a rate limit, it cascades to the next: Opus → Gemini → Sonnet → Codex → Haiku → Copilot → Aider → wait → retry. You walk away, it keeps working.

> **Note:** This project is feature-complete for its headless/overnight automation use case. The interactive cascade use case needs a fundamentally different architecture — see [Limitations](#limitations) and [Why a Desktop App is Better](#why-a-desktop-app-is-better).

---

## How It Works

```
agent-resume --loop -c "finish the refactor"

1. Probe all installed agents by quality tier
   ├── Claude Opus (T1) → available? Run it.
   ├── Gemini (T1) → available? Run it.
   ├── Claude Sonnet (T2) → ...
   └── continues down the list

2. Rate limited mid-task? Cascade to next agent.

3. All agents exhausted?
   ├── Parse reset timestamp
   ├── Live countdown timer
   ├── macOS notification when lifted
   └── Resume on best available

4. (--loop) Go to 1
```

**Default behavior (routing):** Probes all installed agents, routes to the first one that's available.

**On rate limit (cascade):** Walks down the quality tiers, trying each agent until one works.

**`--no-cascade`:** Only use the routed agent. Wait if it's limited.

---

## Quality Tiers

Agents are ordered by coding benchmark quality (SWE-bench Verified, April 2026):

| Tier | Agents | Quality |
|------|--------|---------|
| T1 | Claude Opus, Gemini | Frontier (80%+ SWE-bench) |
| T2 | Claude Sonnet, Codex | Strong (75-80%) |
| T3 | Claude Haiku, Copilot, Aider | Good / Budget |

Override with `--order`:

```bash
agent-resume --order gemini,claude-opus,codex -c  # Gemini first
agent-resume --order claude-sonnet -c              # Sonnet only
```

---

## Features

### Unified Agent Registry

Every agent is a first-class citizen with its own:
- **Rate limit detection patterns** — Gemini: `RESOURCE_EXHAUSTED`, `429`. Codex: `exceeded retry limit`. Copilot: `rate_limited`. Aider: `RateLimitError`.
- **Headless execution flag** — Claude: `-p`, Gemini: `-p`, Codex: `exec`, Copilot: `-p`, Aider: `--message --yes`
- **Probe command** — lightweight check if the agent is available and not rate-limited

### Smart Routing

Default behavior: probes all installed agents in tier order, routes your task to the best available one. No configuration needed — just run `agent-resume -c` and it figures out what's available.

### Rate Limit Detection

Detects rate limits for **every supported agent**, not just Claude:
- **Claude**: 3 output formats (unix timestamp, 12h time, timezone-aware)
- **Gemini**: `RESOURCE_EXHAUSTED`, `RATE_LIMIT_EXCEEDED`, `QUOTA_EXHAUSTED`, HTTP 429
- **Codex**: `exceeded retry limit.*429`, `rate_limit_exceeded`, `insufficient_quota`
- **Copilot**: `rate_limited`, `you've exceeded`, `Copilot token usage`
- **Aider**: `RateLimitError` (litellm), `rate_limit_error`, HTTP 429

### Inter-Agent Delegation

Run a task on a specific agent headlessly, capture output, inject as context into the next task:

```bash
agent-resume delegate gemini "query Stitch for user signup metrics"
```

### Task Queues

Process a markdown file of tasks sequentially with rate-limit resilience:

```bash
agent-resume tasks sprint.md --loop
```

```markdown
- [ ] Refactor auth module to use JWT
delegate:gemini Query Stitch for user signups
- [ ] Update docs with Stitch data from above
- [x] Already done (skipped)
```

### Status Command

Check all agents at a glance:

```bash
agent-resume status
```

```
agent-resume v2.0.0 — status

  [T1] claude-opus       available
  [T1] gemini            available
  [T2] claude-sonnet     limited
  [T2] codex             not installed
  [T3] claude-haiku      available
  [T3] copilot           not installed
  [T3] aider             not installed

  cli-continues          not found
```

### Loop Mode

Exhausts ALL installed agents before waiting. Essential for overnight autonomous runs.

- Detects rate limits **during** execution (not just before)
- Re-runs the full cascade on each retry
- Prevents macOS sleep via `caffeinate`

### Permission Modes

```bash
agent-resume -c                                # Default: prompt for each action
agent-resume --permission-mode auto -c         # Claude decides based on risk
agent-resume --permission-mode acceptEdits -c  # Auto-approve edits
agent-resume --skip-permissions -c             # Full unattended mode
```

### Flag Pass-Through

Forward flags to Claude CLI:

```bash
agent-resume -c -- --worktree myfeature --name "overnight-refactor"
```

### Sleep Prevention, Signal Handling, Logging

- `caffeinate` auto-runs on macOS for loop/task modes
- Proper cleanup on exit (kills child processes)
- `--log events.log` traces every probe, cascade, fallback, and execution

---

## Limitations

This project works well for headless/overnight automation, but be honest about what it can't do:

### Headless mode kills the agent UX

The CLI wrapper approach runs every agent in headless `-p` mode. That means no interactive file diffs, no permission prompts, no conversation flow. You're trading the agent's best feature (interactive collaboration) for automation. This is fine for "run overnight and check in the morning" but bad for anything where you'd want to steer the agent mid-task.

### No context handoff between agents

When agent-resume cascades mid-task (e.g., Opus hits a limit, switches to Gemini), the next agent starts from scratch with just the same prompt. There's no transfer of what the previous agent learned, what files it was editing, or what decisions it made. Each agent re-discovers the codebase independently.

### Probing is slow

Even with parallel/optimistic routing, probing agents takes real time. These CLIs weren't designed to be health-checked — a "probe" is just a lightweight prompt execution. With multiple agents, the startup latency is noticeable.

### Rate limit detection is fragile

Detection depends on parsing stderr/stdout text for specific strings (`RESOURCE_EXHAUSTED`, `usage limit reached`, etc.). If any agent changes their error message format, detection breaks silently. There's no stable API for "am I rate limited?" — it's all regex on human-readable output.

### Only useful for headless automation

If you're sitting at your terminal and want to interactively develop with the best available agent, this tool doesn't help. It's designed for fire-and-forget: queue a task, walk away, check results later.

---

## Why a Desktop App is Better

Building this project surfaced an architectural insight: the CLI wrapper approach hits a ceiling. The interactive cascade use case needs a fundamentally different architecture.

**A daemon/desktop app can watch a real interactive session** — instead of wrapping the CLI in headless mode, a background process can monitor an active terminal session and detect rate limits without taking over the agent's UX.

**Native notifications with action buttons** — instead of silently cascading, a desktop app can show a macOS notification: "Claude hit rate limit. Switch to Gemini?" with Yes/No buttons. The user stays in control.

**Context injection across agents** — a desktop app can capture the conversation state, file changes, and decisions from the rate-limited session and inject them as context into the next agent. No more starting from scratch.

**Each agent keeps its native terminal experience** — no headless mode. You get interactive diffs, permission prompts, and conversation flow exactly as the agent intended.

**This is the direction the project is heading.** The cascade logic belongs in a desktop app (like [CodeVetter](https://github.com/sarthakagrawal927/codevetter)) that can orchestrate agents without degrading their UX. agent-resume proved the concept; a desktop app is the right delivery mechanism.

---

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/sarthakagrawal927/agent-resume/main/install.sh | bash
```

Or manually:

```bash
git clone https://github.com/sarthakagrawal927/agent-resume.git
cd agent-resume
chmod +x agent-resume.sh
ln -s "$(pwd)/agent-resume.sh" ~/.local/bin/agent-resume
```

### Requirements

- **Bash 3+** (ships with macOS)
- At least one AI coding agent installed:

| Agent | Install |
|-------|---------|
| Claude Code | [claude.ai/code](https://claude.ai/code) |
| Gemini CLI | [github.com/google-gemini/gemini-cli](https://github.com/google-gemini/gemini-cli) |
| Codex CLI | `npm i -g @openai/codex` |
| Copilot CLI | `npm i -g @github/copilot` |
| Aider | `pip install aider-chat` |

Optional: **cli-continues** (`npm i -g continues`) for interactive cross-agent context handoff.

---

## Usage

```
agent-resume [options] [prompt]          Route to best agent, cascade on limit
agent-resume status                      Show all agents and their status
agent-resume delegate <agent> <task>     Run a task on a specific agent
agent-resume tasks <file>                Process a task file
```

### Options

| Flag | Description |
|------|-------------|
| `-c, --continue` | Continue previous conversation (Claude) |
| `-r, --resume <id>` | Resume a specific Claude session by ID |
| `-m, --model <model>` | Force a specific Claude model |
| `-f, --fallback <agent>` | Preferred agent when primary is limited |
| `--order <a,b,c>` | Custom cascade order (comma-separated) |
| `--no-cascade` | Don't cascade — only use the routed agent |
| `--loop` | Keep retrying through ALL agents until success |
| `--permission-mode <mode>` | Claude permission mode |
| `--skip-permissions` | Shorthand for `--permission-mode bypassPermissions` |
| `--log <file>` | Log events to file |
| `--test <seconds>` | Simulate rate limit with countdown |
| `-- <flags>` | Forward remaining flags to Claude CLI |

### Agent Names

`claude-opus`, `claude-sonnet`, `claude-haiku`, `gemini`, `codex`, `copilot`, `aider`

---

## Examples

```bash
# Smart route to best available, resume conversation
agent-resume -c

# Exhaust all agents, keep retrying overnight
agent-resume --loop --permission-mode auto -c "get test coverage to 80%"

# Gemini first, then Opus
agent-resume --order gemini,claude-opus -c

# Opus only, wait if limited (no cascade)
agent-resume --no-cascade -m opus -c

# Delegate to Gemini for data it can access
agent-resume delegate gemini "query Stitch for user signups last 30 days"

# Process a task queue
agent-resume tasks sprint.md --loop --skip-permissions

# Check what's available
agent-resume status
```

---

## Running Tests

```bash
bash test.sh
# 93 passed, 0 failed
```

---

## What Makes agent-resume Different (and Where It Falls Short)

Every other tool in this space is Claude-specific. agent-resume treats **all AI coding agents as equal participants** in a unified quality-tiered cascade. Claude's native `--fallback-model` only handles overload (not rate limits), and only within Claude models. We cascade across vendors.

That said, the CLI wrapper approach has a hard ceiling. Wrapping interactive agents in headless mode strips away their best features. The unified cascade concept is sound, but the right implementation is a background daemon that monitors real sessions — not a script that takes over the terminal. See [Why a Desktop App is Better](#why-a-desktop-app-is-better).

---

## Inspiration & Prior Art

Built from scratch after evaluating the Claude Code automation ecosystem:

- **[claude-auto-resume](https://github.com/terryso/claude-auto-resume)** — original idea of rate limit detection + countdown + auto-resume
- **[cli-continues](https://github.com/AidfulAI/cli-continues)** — cross-agent context handoff concept
- **[claude-squad](https://github.com/smtg-ai/claude-squad)** — model/session diversity as a resilience strategy
- **[continuous-claude](https://github.com/AnandChowdhary/continuous-claude)** — task queues, `caffeinate` for overnight runs, cost tracking via `stream-json`
- **[Claude-Autopilot](https://github.com/benbasha/Claude-Autopilot)** — delegation results flowing as context between tasks

---

## License

MIT
