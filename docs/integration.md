# Integrating mem with an agent harness

`mem` is a plain bash CLI. It has no harness-specific code, and it needs none
to be useful — but a small adapter inside a harness turns "the agent remembers
to run mem" into "the agent is automatically reminded." This document defines
the integration contract: what a harness must provide, the minimal surfaces,
and the recall/capture patterns adapters implement. A survey of concrete
hook/lifecycle mechanisms across popular harnesses lives in
[harnesses.md](harnesses.md).

## The three surfaces

A harness needs to provide up to three things, in order of value:

| # | Surface | What it is | Required? |
|---|---------|-----------|-----------|
| 1 | **Shell** | The agent can execute commands (`bash` tool or equivalent) with environment variables (`MEM_DIR`) | Yes — the only hard requirement |
| 2 | **Tool interface** | A way to expose `mem` as first-class tools the model can call — an MCP server, custom tool registration, or simply the shell tool plus instructions | Recommended — makes recall deliberate instead of incidental |
| 3 | **Lifecycle hooks** | A way to run code at fixed moments: session start, user prompt, turn end / idle | Optional — enables automatic recall and capture |

With only surface 1, `mem` works today: put usage instructions in the
harness's instruction file (AGENTS.md / CLAUDE.md / equivalent), and the agent
runs `mem search` / `mem add` on its own initiative. Hooks and tool wrappers
are accelerators, not dependencies.

## Tool interface mapping

The sweet spot is exposing three thin tools over the CLI — minimal schemas,
mem doing all validation:

| Tool | Maps to | Schema (keep minimal) |
|------|---------|----------------------|
| `memory_search` | `mem search <query> [--type] [--limit] [--inject]` | `{ query, type?, limit? }` |
| `memory_add` | `mem add --type --title [--body] [--abstract] [--tags] [--priority]` | `{ type, title, abstract?, body?, tags?, priority? }` |
| `memory_show` | `mem show <id> [--full]` | `{ id, full? }` |

Rules of thumb:

- **Always pass `abstract` on add** (≤120 chars). It is the L0 line compact
  recall depends on (see [design.md](design.md#l0-abstracts-and-compact-recall)).
- Default `memory_search` output to the compact/inject form; the agent can
  call `memory_show` when a line matters.
- The CLI's structured errors (exit 0/1/2, `error:` + `help:` lines on
  stdout) are designed to pass through a tool result unchanged — do not
  translate them into prose.

Any MCP-capable harness can host these three tools with a ~60-line stdio MCP
server that shells out to `mem`; harnesses with native custom-tool
registration can wrap the subcommands directly.

## Automatic recall (needs surface 3)

Adapters implement two complementary recall patterns. Both are pure-shell
around `mem search --inject` and both are tuned to cost ~0 tokens when idle.

### 1. One-shot session-start recall

On session start:

1. Extract 3–8 keywords from the first user message (or prompt template).
2. Run `mem search "<keywords>" --inject --limit 10`.
3. Inject the result lines into the session's opening context.

Cap the injected block (~600 characters). This orients the agent on "what do I
already know about this topic" before it spends a token thinking.

### 2. Topic-shift recall

On each user message:

1. Extract keywords; compare them (token-set similarity, e.g. Jaccard)
   against a sliding window of the last few messages' keywords.
2. If similarity drops below a threshold (~0.3) — the conversation shifted —
   or if N messages (≥5) passed since the last recall, run
   `mem search "<keywords>" --inject --limit 3` and append the lines as a
   note to the model.
3. Otherwise do nothing. On-topic turns cost zero extra tokens.

Across a session this averages ~50–100 characters per turn: cheap enough to
leave on permanently.

## Automatic capture (needs surface 3)

- **Turn end / idle:** mine the finished turn for hard-won wins (tasks that
  took several attempts, non-obvious procedures, root-caused failures) and
  capture them via `mem add --type failure|howto|decision` with an `abstract`.
  Follow the triage rules in [design.md](design.md#triage-memory-procedure-or-nothing)
  — capture selectively, not everything.
- **After capture batches:** run `mem dedup` (dry-run) and
  `--apply` when the candidates look right.
- **Session end:** `mem sync` once, so the local commits reach the bare repo.

## Reference adapter

The reference deployment of these patterns runs on
[OpenCode](https://opencode.ai) and implements exactly the surfaces above:
the three MCP-style tools, one-shot session-start recall, topic-shift recall,
and turn-end capture. It is an *optional adapter*, not part of this package —
`mem` ships harness-neutral, and the same patterns map onto every harness
surveyed in [harnesses.md](harnesses.md) via that harness's public
customization mechanism.

## Choosing an integration level

| You have | Do this |
|---|---|
| Shell only | Instructions file: "search before you start, add when you learn" + the quick reference from the [README](../README.md) |
| Shell + MCP | Host the three-tool wrapper |
| Shell + hooks | Add session-start + topic-shift recall; turn-end capture |
| Everything | All of the above — recall and capture fade into the background |
