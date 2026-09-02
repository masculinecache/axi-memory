# Harness survey: hooks and lifecycle equivalents

`mem` is harness-neutral, but adapters need a concrete anchor in each harness.
This survey maps the integration surfaces from
[integration.md](integration.md) — shell, tool interface, lifecycle hooks —
onto the public customization mechanisms of popular coding-agent harnesses.

Researched from public documentation; last surveyed September 2026. Hook
systems move fast — treat each linked page as authoritative.

## Summary

| Harness | Hook mechanism | Config location | Session-start anchor | Turn-end / idle anchor | Tool interface |
|---|---|---|---|---|---|
| [Claude Code](#claude-code) | Hooks (command/http/prompt/agent) | `~/.claude/settings.json`, `.claude/settings.json` | `SessionStart` | `Stop`, `SubagentStop`, `SessionEnd` | MCP servers, Agent SDK hooks |
| [Codex CLI](#codex-cli) | Hooks (`hooks.json` or inline TOML) | `~/.codex/hooks.json`, `[hooks]` in `config.toml` | `SessionStart` | `Stop`, `SessionEnd`* | MCP servers, plugins |
| [pi](#pi) | TypeScript extensions | `~/.pi/agent/extensions/`, `.pi/extensions/` | `agent_start`, `session_start` | `turn_end`, `session_end` | `pi.registerTool()` |
| [Grok Build](#grok-build) | Hooks (command/http) | `~/.grok/hooks/*.json`, `[hooks]` in `config.toml` | `SessionStart` | `Stop`, `SessionEnd` | MCP servers, skills/plugins |
| [Kimi CLI](#kimi-cli) | Hooks (`[[hooks]]` TOML) | `~/.kimi-code/config.toml` | `SessionStart` | `Stop`, `SessionEnd` | MCP servers, plugins (beta) |

\* Codex events are thread/turn-scoped; see the Codex section.

A useful property of this generation of harnesses: **Claude Code's hook
contract (JSON event on stdin, exit-code decisions) has become a de-facto
standard.** Codex and Grok reuse the event names and payload shapes, and Grok
can import Claude Code/Cursor hook configs directly — so one adapter script
often serves several harnesses unchanged.

---

## Claude Code

*Docs: <https://code.claude.com/docs/en/hooks> (reference),
<https://code.claude.com/docs/en/hooks-guide> (guide)*

Hooks are user-defined commands (or HTTP endpoints, prompts, or agent
spawns) bound to lifecycle events, configured in JSON settings files at user,
project, or enterprise level.

Events fire in three cadences:

- **Once per session:** `SessionStart` (startup/resume/clear/compact),
  `SessionEnd`
- **Once per turn:** `UserPromptSubmit`, `Stop`, `StopFailure`
- **Every tool call:** `PreToolUse`, `PostToolUse` (plus
  `PostToolUseFailure`, `PermissionRequest`, and subagent/compaction events
  such as `SubagentStart`, `SubagentStop`, `PreCompact`, `PostCompact`,
  `Notification`, ...)

Contract: the hook receives a JSON event on **stdin**; decisions return via
stdout JSON or exit codes (exit 2 blocks blocking-capable events). Most
useful for `mem`: `SessionStart` and `UserPromptSubmit` hooks can return
`hookSpecificOutput.additionalContext`, which is injected into the model's
context — exactly what session-start and topic-shift recall need.

mem mapping:

- Session-start recall → `SessionStart` hook →
  `mem search --inject --limit 10` → `additionalContext`
- Topic-shift recall → `UserPromptSubmit` hook (prompt text arrives on stdin)
- Turn-end capture → `Stop` hook (or `SessionEnd` for a final
  `mem sync`)
- Tool interface → MCP server hosting the three-tool wrapper, or the
  Claude Agent SDK's in-process hooks

## Codex CLI

*Docs: <https://developers.openai.com/codex/hooks>,
<https://developers.openai.com/codex/config-advanced>*

Codex supports lifecycle hooks discovered from `hooks.json` files or inline
`[hooks]` tables in `config.toml`, at user (`~/.codex/`) or project
(`.codex/`) scope, plus plugin-bundled hooks.

Documented events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PostToolUse`, `PermissionRequest`, `PreCompact`, `PostCompact`,
`SubagentStart`, `SubagentStop`, `Stop`. The event names, stdin JSON payload
shape (`session_id`, `transcript_path`, `cwd`, `hook_event_name`, `model`,
`turn_id`), and output fields mirror Claude Code's contract, so a Claude Code
hook script generally runs unchanged. `SessionStart` and `SubagentStart` run
at thread scope; the rest run at turn scope (there is no separate `SessionEnd`
— `Stop` plus the legacy notification below are the end anchors).

Also relevant: the older `notify` config key (`notify = ["cmd", ...]`) fires
an external program on `agent-turn-complete` — enough for end-of-session
`mem sync` without the full hooks system.

mem mapping:

- Session-start recall → `SessionStart` hook (supports
  `additionalContext` output)
- Topic-shift recall → `UserPromptSubmit` hook (plain stdout is added as
  developer context)
- Turn-end capture / sync → `Stop` hook, or the legacy `notify` program
- Tool interface → MCP servers configured in `config.toml`

## pi

*Docs: <https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md>*

pi (the coding agent from the
[pi-mono](https://github.com/badlogic/pi-mono) toolkit) unifies hooks and
custom tools into one **extension system**: TypeScript modules loaded at
startup from `~/.pi/agent/extensions/` or project `.pi/extensions/` (via
jiti — no build step). An extension receives an `ExtensionAPI` and can:

- subscribe to lifecycle events with `pi.on(event, handler)` — including
  `agent_start`, `session_start`, `session_end`, `turn_start`, `turn_end`,
  and `tool_call` (which can block a tool call)
- register tools with `pi.registerTool({ name, parameters, execute })`
- register commands and providers

Unlike the stdin/exit-code harnesses above, pi adapters are in-process
TypeScript: an extension can run `mem search --inject` with
`child_process`, parse the TOON lines, and inject them as a custom message or
context — same patterns, different plumbing.

mem mapping:

- Session-start recall → `pi.on("session_start")` or `pi.on("agent_start")`
- Topic-shift recall → `pi.on("turn_start")` with keyword-similarity logic
- Turn-end capture / sync → `pi.on("turn_end")`, `pi.on("session_end")`
- Tool interface → `pi.registerTool()` hosting `memory_search` / `memory_add`
  / `memory_show`

## Grok Build

*Docs: <https://docs.x.ai/build/features/hooks> (user guide:
[xai-org/grok-build](https://github.com/xai-org/grok-build) repo docs)*

Grok Build (xAI's Rust coding agent) supports command and HTTP hooks bound to
lifecycle events, configured as JSON files in `~/.grok/hooks/*.json` or
project `.grok/hooks/*.json`, inline `[hooks]` in `config.toml`, or bundled
with plugins.

The event set and JSON stdin/exit-code contract follow the Claude Code shape
(`PreToolUse`, `PostToolUse`, `SessionStart`, `Stop`, `SessionEnd`,
`Notification`, compaction and subagent events...), and Grok can additionally
**load `~/.claude/settings.json` / `~/.cursor/hooks.json` directly** — a
Claude-targeted mem adapter is reusable as-is. Notable details: hook
processes get `GROK_HOOK_EVENT`/`GROK_SESSION_ID`-style environment
variables, matching hooks from multiple files all run, and project hooks
require an explicit folder-trust grant.

mem mapping:

- Session-start recall → `SessionStart` hook
- Topic-shift recall → `UserPromptSubmit` hook
- Turn-end capture / sync → `Stop` / `SessionEnd` hooks
- Tool interface → MCP servers, or the skills/plugins system

## Kimi CLI

*Docs: <https://moonshotai.github.io/kimi-code/en/customization/hooks.html>
(repo: [MoonshotAI/kimi-code](https://github.com/MoonshotAI/kimi-code))*

Kimi Code CLI's hooks system (beta) runs a shell command when a lifecycle
event fires, configured in the `[[hooks]]` array of `~/.kimi-code/config.toml`
with four fields: `event`, `matcher` (regex filter), `command`, `timeout`.

Documented events include: `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `PermissionRequest`, `PermissionResult`, `Stop`,
`StopFailure`, `TurnStarted`, `SessionStart` (startup/resume), `SessionEnd`
(exit/archive), `SessionHeartbeat`, `SubagentStart`, `SubagentStop`,
`TaskStarted`, `Interrupt`, `PreCompact`, `PostCompact`, `Notification`.

Contract: JSON event on stdin; exit 0 allows (stdout may be appended to
context on context-capable events), exit 2 blocks blockable events
(`PreToolUse`, `Stop`, `UserPromptSubmit`), other codes fail-open. Matching
hooks run in parallel; failures never interrupt the session. Kimi also has a
plugins (beta) system and MCP support for the tool surface.

mem mapping:

- Session-start recall → `SessionStart` hook
- Topic-shift recall → `UserPromptSubmit` hook (prompt text on stdin;
  returned text is appended to context)
- Turn-end capture / sync → `Stop` hook / `SessionEnd` hook
  (`SessionHeartbeat` is available for periodic housekeeping)
- Tool interface → MCP servers or the plugins (beta) system

---

## Portability notes for adapter authors

1. **Write the hook script once, harness-neutral.** Read the JSON event from
   stdin, branch on `hook_event_name`, shell out to `mem`, print
   `additionalContext`-style JSON where the harness supports it. The same
   script drops into Claude Code, Codex, Grok, and Kimi with only config-file
   changes.
2. **Never throw into the harness.** A crashing hook must not break the
   session — wrap everything in try/catch, log, and exit 0. Fail-open is the
   norm across these harnesses; honor it in your adapter too.
3. **Budget your injections.** Session-start recall ≤600 chars, topic-shift
   recall ≤3 abstract lines. The compact `--inject` output exists precisely
   so adapters can be generous with triggers and stingy with tokens.
4. **Respect trust prompts.** Several harnesses gate project-scoped hooks
   behind folder trust; document that your mem adapter's hook config must be
   trusted once.
