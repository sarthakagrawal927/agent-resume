# Agent Rate Limit Patterns Research — 2026-04-04

## Gemini CLI (@google/gemini-cli)
- Patterns: `RESOURCE_EXHAUSTED`, `RATE_LIMIT_EXCEEDED`, `QUOTA_EXHAUSTED`, `exhausted.*quota`, `429`
- Exit code: `429` in JSON mode, `1` in text mode
- Headless: `gemini -p "prompt"`
- Probe: `gemini -p check`

## Codex CLI (@openai/codex)
- Patterns: `exceeded retry limit.*429`, `rate_limit_exceeded`, `429 Too Many`, `insufficient_quota`
- Exit code: non-zero after retries exhausted
- Headless: `codex exec "prompt"` (NOT `codex -p`)
- Probe: `codex --version` (no lightweight check available)

## GitHub Copilot CLI (@github/copilot)
- Patterns: `rate_limited`, `you've exceeded`, `you have been rate-limited`, `Copilot token usage`
- Note: `copilot` binary conflicts with AWS Copilot on some machines
- Headless: `copilot -p "prompt"`
- Probe: `copilot --version`

## Aider (paul-gauthier/aider)
- Patterns: `RateLimitError`, `Retrying in [0-9]`, `rate_limit_error`, `429.*Too Many`, `exceeded.*quota`
- Uses litellm under the hood for retry with exponential backoff
- Headless: `aider --message "prompt" --yes`
- Probe: `aider --version`

## Quality Tier Ordering (April 2026, SWE-bench Verified)
- T1: Claude Opus 4.6 (80.8%), Gemini 3.1 Pro (80.6%)
- T2: Claude Sonnet 4.6 (79.6%), Codex/GPT-5.4 (~80%)
- T3: Claude Haiku, Copilot, Aider (varies by backend)
