# axi-memory

Filesystem + git agent memory CLI with TOON output. Durable memory that survives across sessions and machines, stored as markdown + YAML frontmatter in a git repo.

Following the [AXI 10 principles](https://axi.md): TOON output, minimal schemas, content-first home view, truncation with `--full`, definitive empty states, structured errors on stdout, exit 0/1/2.

## Install

Requires bash, git, and ripgrep (`rg`).

```bash
npm i -g @masculinecache/mem
mem --version   # 0.1.0
```

Or without npm — clone the repo and put `mem` on your `PATH`:

```bash
git clone https://github.com/masculinecache/axi-memory.git
ln -s "$(pwd)/axi-memory/mem" ~/.local/bin/mem
```

## Documentation

| Doc | Contents |
|---|---|
| [docs/design.md](docs/design.md) | Why filesystem + git + markdown; the memory model; triage; L0 abstracts; ranking/lifecycle; sync model; search strategy |
| [docs/integration.md](docs/integration.md) | Harness-neutral integration: the shell / tool / hook surfaces, tool mapping, recall and capture patterns |
| [docs/harnesses.md](docs/harnesses.md) | Survey of hook/lifecycle equivalents across agent harnesses (Claude Code, Codex, pi, Grok, Kimi) |

## Quick Start

```bash
# Initialize (idempotent)
mem init

# Add a memory
mem add --type decision --title "Use pnpm not npm" --body "Lockfile determinism matters" --tags "tooling,frontend" --priority 80

# Search
mem search "pnpm"

# View full detail
mem show d-2026-07-19-use-pnpm-not-npm --full

# List all
mem list

# Sync with remote
mem sync
```

## Commands

### `mem` (no args) — Home View
Content-first dashboard showing recent memories + counts by type.

```bash
mem
```
Output:
```
bin: ./mem
description: filesystem + git agent memory (TOON)
store: /home/user/memories
remote: origin
counts[5]{type,count}:
  constraint,13
  decision,100
  failure,30
  howto,90
  preference,3
total: 236 memories
recent[5]{id,type,title,confidence}:
  d-2026-08-28-auth-401,decision,JWT strategy,0.9
  ...
help[3]:
  Run `mem search "<query>"` to find by keyword
  Run `mem add --type <type> --title "<title>"` to add a memory
  Run `mem sync` to pull+push from the remote
```

### `mem init` — Initialize Store
Creates the directory structure and git repo. Idempotent.

```bash
mem init
```

### `mem add` — Create Memory
```bash
mem add --type decision --title "Use pnpm" \
  --body "Never run npm install in this repo." \
  --tags "tooling,frontend" \
  --priority 80 \
  --confidence 0.9 \
  --scope example-api
```

Required: `--type` (constraint|decision|failure|howto|preference), `--title`

Optional: `--body`, `--abstract` (≤120 chars for L0 recall), `--scope`, `--tags`, `--confidence` (0.0-1.0), `--priority` (0-100), `--verified` (YYYY-MM-DD), `--force` (bypass security gate)

Security gate: refuses credential-like values (API keys, tokens, passwords) unless `--force` is passed.

### `mem search` — Keyword Search
Ripgrep-based search across all memories, ranked by priority desc × freshness.

```bash
mem search "auth"                    # search all
mem search "jwt" --type failure      # constrain to type
mem search "deploy" --limit 10       # top 10 (injection budget cap)
mem search "bug" --min-priority 70   # relevance floor
mem search "config" --inject         # compact: id + abstract only
```

Output: TOON list with `id,type,title,confidence` + total count.

### `mem show` — Full Detail
```bash
mem show d-2026-07-19-auth-401        # truncated body (500 bytes)
mem show d-2026-07-19-auth-401 --full # complete body
```

IDs can be full (`d-2026-07-19-auth-401`) or suffix (`2026-07-19-auth-401`).

### `mem list` — Filtered Listing
```bash
mem list                              # all, priority-ranked
mem list --type failure               # filter by type
mem list --tag auth --limit 20        # filter by tag
mem list --min-priority 60            # floor
```

Output: TOON list with `id,type,title,confidence` + total count.

### `mem update` — Edit Memory
Bumps `version` (+1), records `updated`, writes conventional commit.

```bash
mem update d-2026-07-19-auth-401 --priority 90 --confidence 0.95
mem update d-2026-07-19-auth-401 --body "revised steps" --tags "auth,jwt,bug"
```

No-op detection: if nothing changed, exits 0 with no commit.

### `mem merge` — Merge Two Memories
```bash
mem merge d-2026-07-19-keep d-2026-08-03-absorb      # apply
mem merge d-2026-07-19-keep d-2026-08-03-absorb --dry-run  # preview
```

Keeps `keep-id`, absorbs body+tags, max priority/confidence, version = max+1. Absorbed file git-removed (recoverable from history).

### `mem dedup` — Find Near-Duplicates (OS-side, no LLM)
```bash
mem dedup                              # dry-run
mem dedup --threshold 0.5 --type howto
mem dedup --apply                      # merge candidates (higher priority kept)
```

Normalizes titles, compares token sets by Jaccard within same type, bucketed by first token to avoid O(N²).

### `mem review` — Review Inbox
```bash
mem review                       # confidence < 0.5 or unverified
mem review --min-confidence 0.8  # raise the bar
```

Lists memories needing human/agent decision. Clear with `mem update <id> --confidence 0.8 --verified 2026-08-29`.

### `mem status` — Operational Health
```bash
mem status
```
Shows store path, memory count, disk usage, remote URL + reachability, sync state (ahead/behind), last commit time, contextual hints.

### `mem sync` — Git Pull + Push
```bash
mem sync
```
Pulls with `--rebase` (30s timeout), then pushes. Reports unpushed/unpulled counts.

### `mem stats` — Usage Statistics
```bash
mem stats
```
Shows searches/hits/rate, adds/dupes, last search/add timestamps from `$MEM_DIR/.stats`.

## Memory Types

| Type | Prefix | Priority Guide |
|------|--------|----------------|
| constraint | `c-` | 80 |
| decision | `d-` | 70 |
| failure | `f-` | 75 |
| howto | `h-` | 60 |
| preference | `p-` | 50 |

ID format: `<prefix>-<YYYY-MM-DD>-<slug>`

## Configuration

| Env | Default |
|-----|---------|
| `MEM_DIR` | `$HOME/memories` |
| `MEM_REMOTE` | `origin` |

## Output Format (TOON)

All list commands emit [TOON](https://toonformat.dev/):
```
mem[3]{id,type,title,confidence}:
  d-2026-07-19-x,decision,Title A,0.9
  f-2026-07-20-y,failure,Title B,0.8
  h-2026-07-21-z,howto,Title C,0.7
count: 3 of 47 total
```

Empty state:
```
mem[0]{id,type,title,confidence}:
count: 0 of 0 total
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (including no-ops) |
| 1 | Error (intent cannot be satisfied) |
| 2 | Usage error (missing required flag, unknown flag/command) |

## Sync Model

Local: `$MEM_DIR` (working dir with `.git/`)
Remote: bare repo at `$MEM_REMOTE` (default `origin`)

`mem sync` = `git pull --rebase && git push`. Conflicts are git conflicts — resolve manually.

## License

MIT