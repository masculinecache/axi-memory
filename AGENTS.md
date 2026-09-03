# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## GitHub credentials (captain order)

Every GitHub operation on this repo uses the **masculinecache** account only — never global personal credentials.

- `gh`/`gh-axi` calls: export `GH_CONFIG_DIR=$HOME/.config/gh-masculinecache` first; never rely on ambient gh config.
- The committed `.mise.toml` carries this rule for mise-driven shells: `GH_REPO=masculinecache/axi-memory`, `GH_CONFIG_DIR=$HOME/.config/gh-masculinecache`. If mise is not active, export them by hand.
- `git push` already works as masculinecache via the repo-local credential helper — do not alter it.
- On gh auth failure (403/wrong account): stop and report blocked; never retry with different credentials.

## Build / test / package

- Tests: `./tests/run.sh` (sandboxed, asserts TOON output + exit codes + git trail).
- Lint: `shellcheck -S error ./mem ./tests/run.sh`.
- Package: `npm publish --dry-run` verifies tarball contents; clean-install smoke test is
  `npm i -g . --prefix /tmp/memtest` then `mem --help` / `mem --version` (also a CI `package` job).
- **Version lives in three places that must move together**: `MEM_VERSION` in `./mem`,
  `version` in `package.json`, and the assertion in `.github/workflows/ci.yml` (`package` job).
- GitHub `ubuntu-latest` runners do NOT ship ripgrep — the `ci` job installs it.
  `mem search` depends on `rg` and fails loud (exit 1) when it is missing or the regex is invalid.
- `npm publish` itself is intentionally never run by agents — publishing is a human/captain action.

## Public-docs redaction rule

This repo is public. `docs/` and `README.md` must never expose the opencode-internal hook
surface this tool's reference adapter builds on (message hooks, session lifecycle events,
plugin/extension wiring, fleet-state concepts) nor fleet internals (hostnames, paths, other
repos, procedures). Harness guidance stays harness-neutral; per-harness surveys cite public
documentation only. Before merging doc changes, grep for those concepts.


## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
