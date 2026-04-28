# agent-resume

Run AI coding agents with a cross-vendor cascade. When the routed agent rate-limits, falls through to the next: Claude Opus → Gemini → Sonnet → Codex → Haiku → Copilot → Aider.

Two modes:

- **Direct** — run a prompt through the cascade. Walk away, it keeps working.
- **Queue** — solve open GitHub issues end-to-end and open a PR.

One bash file. No required dependencies (beyond at least one AI CLI).

```bash
# Direct
agent-resume "fix the auth bug"
agent-resume --loop --skip-permissions "get coverage to 80%"

# Queue (the GitHub issue solver)
agent-resume queue
agent-resume queue --issue 42
agent-resume queue --label bug
```

---

## Why

Every cascade tool in this space is single-vendor. Claude's `--fallback-model` only works inside Claude. agent-resume cascades **across vendors**, so a Claude rate limit doesn't stall an overnight run.

The queue mode borrows the workflow from [claude-queue](https://github.com/nilbuild/claude-queue) (MIT) and replaces its hardcoded `claude -p` calls with this cascade. Result: a GitHub issue solver that survives rate limits across the entire agent fleet.

---

## Install

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

- Bash 3+ (ships with macOS)
- At least one AI CLI installed:

| Agent | Install |
|-------|---------|
| Claude Code | [claude.ai/code](https://claude.ai/code) |
| Gemini CLI | [github.com/google-gemini/gemini-cli](https://github.com/google-gemini/gemini-cli) |
| Codex CLI | `npm i -g @openai/codex` |
| Copilot CLI | `npm i -g @github/copilot` |
| Aider | `pip install aider-chat` |

For queue mode, also: `gh` (authenticated), `git`, `jq`.

---

## Direct Mode

```bash
agent-resume [options] "prompt"
```

Runs the prompt through the cascade. The first installed agent in tier order gets the work; if it rate-limits, the next one takes over.

| Flag | Description |
|------|-------------|
| `-c, --continue` | Continue Claude conversation (`-c` flag passthrough) |
| `--no-cascade` | Don't fall through — only use the first agent |
| `--loop` | Keep retrying through all agents until success |
| `--skip-permissions` | Pass `--dangerously-skip-permissions` to Claude (full unattended mode) |

```bash
# Single run, cascade if needed
agent-resume "refactor auth module to use JWT"

# Overnight, exhaust all agents, retry on failure
agent-resume --loop --skip-permissions "get test coverage to 80%"

# Continue Claude conversation
agent-resume -c
```

---

## Queue Mode

```bash
agent-resume queue [options]
```

Solves open GitHub issues one by one and opens a single pull request with all the fixes. Drop tasks as issues, run this overnight, review the PR in the morning.

Issues don't have to be code changes — investigative tasks like "audit the codebase for accessibility issues" work too. Whatever the agent produces gets committed.

| Flag | Default | Description |
|------|---------|-------------|
| `--issue ID` | all open | Solve specific issue(s) by ID, URL, or comma-separated IDs |
| `--max-retries N` | 3 | Max retry attempts per issue |
| `--max-turns N` | 50 | Max Claude turns per attempt |
| `--label LABEL` | all | Only process issues with this label (repeatable) |
| `--no-cascade` | | Only use the routed agent — don't fall through |

```bash
agent-resume queue                              # all open issues
agent-resume queue --issue 42                   # one issue
agent-resume queue --issue 1,2,3                # several
agent-resume queue --label bug --label urgent   # filter
agent-resume queue --max-retries 5              # be more patient
```

### What it does

1. **Preflight** — checks `gh`/`git`/`jq`, gh auth, clean working tree, at least one agent installed
2. **Labels** — creates `agent-resume:in-progress`, `:solved`, `:failed` (skips if they exist)
3. **Branch** — `agent-resume/YYYY-MM-DD` off the default branch
4. **Solve** — for each issue, cascade through agents until it produces changes or all retries fail
5. **Review pass** — runs all changes through one more agent (T2+ only, to save quota) for a cleanup pass
6. **PR** — pushes the branch and opens a PR with per-issue logs

### Per-project config

Drop a `.agent-resume` file in your repo root with extra prompt instructions:

```
Always run pnpm test after making changes.
Use TypeScript strict mode.
Never modify files in src/legacy/.
```

These get appended to every issue prompt.

### Logs

Per-run logs land in `/tmp/agent-resume-queue-DATE-TIMESTAMP/`:

```
issue-42.md             # Combined log for issue #42
issue-42-attempt-1.log  # Raw agent output, attempt 1
review.log              # Final review pass output
pr-body.md              # Generated PR description
```

---

## Status

```bash
agent-resume status
```

Probes every agent in parallel and prints availability:

```
agent-resume v3.0.0 — status

  [T1] claude-opus       ✓ available
  [T1] gemini            ✓ available
  [T2] claude-sonnet     ✗ limited — resets 15:00:00
  [T2] codex             not installed
  [T3] claude-haiku      ✓ available
  [T3] copilot           not installed
  [T3] aider             not installed
```

---

## Cascade order

By quality tier (SWE-bench Verified):

| Tier | Agents |
|------|--------|
| T1 | Claude Opus, Gemini |
| T2 | Claude Sonnet, Codex |
| T3 | Claude Haiku, Copilot, Aider |

Tier order is loaded from `tiers.json`, which is auto-updated by a GitHub Action every 15 days from the Aider leaderboard.

---

## Limitations

- **Headless mode** — every agent runs with `-p` / `exec` / `--message`, so no interactive diffs or prompts. This is what makes overnight runs possible; it's the wrong fit for sit-and-watch sessions.
- **No context handoff** — when the cascade switches mid-task, the next agent starts fresh. There's no transfer of partial work.
- **Rate limit detection is regex** — every agent's "I'm rate limited" signal is parsed from stderr/stdout text. If a vendor changes their error format, detection breaks. There's no stable API for it.

---

## Tests

```bash
bash test.sh
```

---

## Inspiration

- [claude-queue](https://github.com/nilbuild/claude-queue) — the GitHub issue queue workflow this project's queue mode is built on
- [claude-auto-resume](https://github.com/terryso/claude-auto-resume) — original rate-limit-detection-and-countdown idea
- [continuous-claude](https://github.com/AnandChowdhary/continuous-claude) — `caffeinate` for overnight runs
- [Claude-Autopilot](https://github.com/benbasha/Claude-Autopilot) — context flowing between tasks

---

## License

MIT
