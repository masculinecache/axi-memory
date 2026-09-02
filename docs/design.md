# axi-memory design

This document explains why `mem` exists, how its memory model works, and the
design decisions behind the store, the ranking system, and the sync model.
For the command reference, see the [README](../README.md). For wiring `mem`
into an agent harness, see [integration.md](integration.md) and the
[harness survey](harnesses.md).

## Why filesystem + git + markdown

Agent memory tools usually start as a hosted service or an embedded vector
database. `mem` deliberately starts simpler:

- **Markdown + YAML frontmatter** is human-readable, diffable, and greppable.
  No client is required to inspect or edit a memory store — `git log`, `rg`,
  or a text editor all work.
- **Git is the storage engine.** Every `add`, `update`, and `merge` is one
  conventional commit. History, conflict resolution, and multi-machine sync
  come for free instead of being built.
- **The store is the source of truth.** Anything derived (statistics, caches,
  future search indexes) is a build artifact inside `$MEM_DIR/.cache/`, which
  is gitignored. Deleting the cache never loses data.
- **Local-first.** Every read and write operates on the local working
  directory. A remote is optional; sync happens lazily when one exists.

The CLI follows the [AXI](https://axi.md) principles for agent-facing tools:
TOON output (~40% smaller than JSON), 3–4 default fields per list, a
content-first home view, truncation with a `--full` escape hatch, definitive
empty states, structured errors on stdout, and exit codes 0/1/2. A typical
search-plus-show round trip costs well under 200 tokens at small memory
counts, so an agent can consult memory without blowing its context budget.

## The memory model

### Five first-class types

The type system is deliberately small and drives everything else: the id
namespace, the on-disk layout, and suggested priorities.

| Type | Prefix | For | Suggested priority |
|------|--------|----|--------------------|
| `constraint` | `c-` | "must do X / must not do Y" — enforced rules | 80 |
| `decision` | `d-` | "we chose X over Y because Z" — rationale worth keeping | 70 |
| `failure` | `f-` | "this broke; root cause was W; fix was X" — postmortems | 75 |
| `howto` | `h-` | "to deploy Y, run A, B, C" — procedural recipes | 60 |
| `preference` | `p-` | "the user prefers X" — durable taste | 50 |

Ids encode the type so they stay unique and self-describing:

```
<type-prefix>-<YYYY-MM-DD>-<slug>
c-2026-07-19-use-pnpm
f-2026-07-19-jwt-decode-panic
```

### Frontmatter fields

```yaml
id: d-2026-07-19-adopt-mem-as-memory-system
type: decision
title: Adopt mem as memory system
scope: example-api          # free-text project/system tag (optional)
status: active
priority: 70                # 0-100, the primary sort key
confidence: 0.9             # 0.0-1.0, how sure this memory is right
version: 2                  # +1 on every update/merge
created: 2026-07-19
updated: 2026-08-03
tags: ["memory", "axi", "toon", "bash"]
abstract: "Switched to a bash+git+TOON CLI for cross-machine memory"
---
<markdown body>
```

`priority` and `version` are the two lifecycle fields: `priority` ranks the
memory in every `search`/`list` (descending — importance over match order),
and `version` records how many times the memory has been edited. Ids and types
are immutable; a title change never re-slugs the id, so external references
stay stable.

## Triage: memory, procedure, or nothing

Not every lesson belongs in the store. Before capturing, triage:

| The thing you just learned | Capture as |
|---|---|
| A one-line fact, correction, decision, or preference | A memory (`mem add`) |
| A multi-step procedure that only worked after several attempts | A durable procedure document — then a `howto` memory pointing at it |
| A failure with a root cause and a fix | A `failure` memory |
| Something only useful for the next few turns of this session | Nothing — do not capture |

A procedure is worth a *capture beyond a memory* only when it passes a
promotion test: a **verified passing check** (it worked, once), a **repeatable
verification step** (how to prove it works again), a **named failure pattern**
(what goes wrong without it), and at least one **ruled-out dead end** (an
approach that looked right and was not). Anything short of that is captured as
a low-confidence memory (`--confidence 0.3`) and matures through review rather
than being trusted immediately.

After any capture batch, run `mem dedup`. Re-learned lessons merge into the
existing memory instead of duplicating — near-duplicate titles are detected
OS-side (see below), so the dedup pass itself costs no LLM tokens.

## L0 abstracts and compact recall

Every memory can carry an `abstract`: a single line, **≤120 characters**,
stored in frontmatter. It is the level-0 (L0) summary — the one sentence an
agent reads before deciding whether to drill into the full body.

- `mem search <query> --inject` emits one compact line per result —
  `id type title — abstract` — instead of full rows. This is the output
  adapters inject as context (see [integration.md](integration.md)); it costs
  roughly a third of the default list output.
- When an `abstract` is absent, `--inject` falls back to the first 120
  characters of the body.
- **Always pass `--abstract` when adding memories programmatically.** It is
  cheap at write time and pays off on every recall.

## Ranking and lifecycle

- **Ranking:** `search` and `list` sort by `priority` (desc), then freshness
  (`verified`/`updated`/`created`), then recency. Importance over match order
  — constraints surface before trivia, and an agent capping its injection
  budget can simply take the top of the list. `--min-priority` acts as a
  relevance floor; `--limit` caps rows.
- **Updates:** `mem update` bumps `version` (+1), records `updated`, and
  writes one conventional commit. Editing an existing memory is preferred over
  duplicating it. No-op detection: if nothing changed, no commit is written
  and the CLI exits 0.
- **Merges:** `mem merge <keep> <absorb>` folds one memory into another —
  body appended under a merge header, tags unioned, priority and confidence
  maxed, version = max+1. The absorbed file is git-removed but recoverable
  from history (`git log --diff-filter=D`).
- **Dedup:** `mem dedup` normalizes titles (lowercase, non-alphanumeric →
  space) and compares token sets by Jaccard similarity within a type,
  bucketed by first token to avoid an O(N²) scan. Dry-run is the default;
  `--apply` merges each pair, keeping the higher priority. Zero LLM cost.
- **Review inbox:** `mem review` lists memories with confidence below the
  floor (default 0.5) or with no `verified` date — the queue of memories that
  still need a human or agent decision. Clear entries with
  `mem update <id> --confidence 0.8 --verified 2026-08-29`.

## Store and sync model

```
$MEM_DIR/                  (default: $HOME/memories)
  objects/
    constraints/  decisions/  failures/  howtos/  preferences/
      <id>.md
  .git/                     (working repo — one commit per write)
  .cache/                   (transient, gitignored)
  .stats                    (TSV usage counters)
```

- `MEM_DIR` relocates the store; `MEM_REMOTE` selects the git remote name
  (default `origin`).
- `mem sync` = `git pull --rebase && git push` with a timeout so an
  unreachable remote never hangs the CLI. Conflicts are ordinary git
  conflicts: open the file, merge by hand, commit.
- **Sync cadence:** local commits accumulate; sync once at session end or when
  cross-machine sync is explicitly wanted. Adding is fast (one commit each);
  syncing is the only networked operation.
- **Offline is fine:** if the remote is down, every command still works
  against the local directory. Sync happens lazily later.
- **Same-host remote note:** if the bare repo lives on the same machine as one
  of the clients, point that client's remote at the local filesystem path
  rather than a public hostname. Routing a same-host sync out through a tunnel
  or proxy and back adds latency and can time out. Other machines use the
  normal SSH URL.
- Back up the bare repo with whatever backup schedule already covers that
  host — the store is just a git repo, so standard backup tooling works.

## Search strategy: v1 literal, v2 deferred

v1 uses ripgrep for literal + regex matching across the whole markdown file
(frontmatter + body). At memory counts under ~5,000, `rg` returns tens of hits
per query and an agent can read all of them — literal matches with visible
context beat opaque similarity scores, at zero external dependency.

Semantic search is deliberately deferred until the ceiling is real: when
`search` returns >50 hits and the right one is not visible in the top few.
The v2 plan, kept here so it survives:

- sqlite-vec index as a **build artifact** in `$MEM_DIR/.cache/index.sqlite`,
  never the source of truth.
- In-process ONNX embedding (a small ~80MB model). **Never a hosted vector
  DB** — external dependencies and latency are exactly what the filesystem
  design avoids.
- Activated with `mem search <q> --features=vector`; default behavior never
  changes.
- **Embedding-model change detection:** persist `{provider, model,
  dimensions}` when the index is built; on startup, any mismatch means every
  stored vector is invalid → drop the vector tables and rebuild from the
  markdown source of truth. Without this guard, swapping embedding models
  silently corrupts retrieval.

## Gotchas

- **Never store secret values.** `mem add` refuses credential-like material
  (API keys, tokens, passwords, private keys) unless `--force` is passed.
  Record *where* a secret lives (env var, vault, secret manager), never the
  value. The store is plain text that will be synced and backed up.
- **Don't capture trivia.** Memories persist across sessions and machines. If
  it is only useful for the next few turns, it does not belong in the store.
- **Tag memories as you add them.** `mem list --tag X` is only as good as the
  tags; always include at least the project, topic, or system involved.
- **Prefer update over add.** Re-learning a lesson should bump the existing
  memory, not create a sibling — and `mem dedup` exists to clean up when the
  sibling already happened.
- **Ids are stable.** A title change never re-slugs; link memories by id, not
  by title.
- **Don't sync after every add.** Batch syncs at session end; the local git
  history is durable in the meantime.

## Sample memory

```markdown
---
id: d-2026-07-19-adopt-mem-as-memory-system
type: decision
title: Adopt mem as memory system
scope: example-api
status: active
priority: 70
confidence: 0.9
version: 2
created: 2026-07-19
updated: 2026-08-03
tags: ["memory","axi","toon","bash"]
abstract: "Switched to a bash+git+TOON CLI for cross-machine agent memory"
---

After evaluating hosted memory services, switched to a bash + git + TOON CLI.
Decided on 2026-07-19. Reasons: no external dependencies, human-readable
store, multi-machine sync via a bare git repo, and sub-200-token recall.
```
