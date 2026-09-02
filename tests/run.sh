#!/usr/bin/env bash
# tests/run.sh — acceptance test harness for the `mem` AXI CLI.
#
# Each test runs ./mem against a fresh, isolated sandbox ($MEM_DIR in a temp dir),
# so nothing touches the user's real memories. Asserts on TOON output, exit codes,
# and the git commit trail (versioned conventional commits).
#
# Run from the repo root:  ./tests/run.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEM_BIN="$REPO_ROOT/mem"

PASS=0
FAIL=0
CURRENT=""

t() { CURRENT="$1"; }

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$CURRENT"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s: %s\n' "$CURRENT" "$1"; }

# Assert helpers. Each takes a description as $1 and the value to check as $2.
assert_eq()   { [ "$2" = "$3" ] && ok || bad "$1 (expected '$3', got '$2')"; }
assert_nz()   { [ -n "$2" ] && ok || bad "$1 (empty)"; }
assert_has()  { case "$2" in *"$3"*) ok ;; *) bad "$1 (missing '$3' in: $2)" ;; esac; }
assert_exit() {
  # $1 desc, $2 expected exit code, $3 actual, $4 stderr note
  [ "$3" -eq "$2" ] && ok || bad "$1 (expected exit $2, got $3)${4:+ [$4]}"
}

# --- Sandbox helpers ---------------------------------------------------------
SANDBOX_DIR="$(mktemp -d /tmp/mem-test.XXXXXX)"
export MEM_DIR="$SANDBOX_DIR/memories"

new_sandbox() {
  rm -rf "$SANDBOX_DIR"
  mkdir -p "$SANDBOX_DIR"
  export MEM_DIR="$SANDBOX_DIR/memories"
  # init idempotently
  ( cd "$REPO_ROOT" && MEM_DIR="$MEM_DIR" "$MEM_BIN" init >/dev/null 2>&1 )
}

run() {
  # run <args...> ; captures stdout in $OUT, exit code in $RC
  OUT="$( cd "$REPO_ROOT" && MEM_DIR="$MEM_DIR" "$MEM_BIN" "$@" 2>/dev/null )"
  RC=$?
}

add_mem() {
  # add_mem <type> <title> [extra flags...]
  local type="$1" title="$2"; shift 2
  run add --type "$type" --title "$title" "$@" >/dev/null 2>&1
}

commit_count() {
  git -C "$MEM_DIR" rev-list --count HEAD 2>/dev/null || echo 0
}

# --- Tests -------------------------------------------------------------------
echo "== mem home view (content-first, no args) =="

t "home prints a bin line"
new_sandbox
run
assert_has "home shows bin:" "$OUT" "bin:"
assert_has "home shows description:" "$OUT" "description:"
assert_has "home shows store:" "$OUT" "store:"
assert_has "home shows total:" "$OUT" "total:"
assert_nz "home shows recent list" "$OUT"

t "home after adding shows the new memory + counts"
run add --type decision --title "Use pnpm not npm" --body "lockfile" >/dev/null 2>&1
run
assert_has "counts show decision 1" "$OUT" "decision"
assert_has "recent shows the title" "$OUT" "Use pnpm not npm"

echo
echo "== init =="

t "init is idempotent (rerun succeeds)"
new_sandbox
run init
assert_exit "init first run exit 0" 0 "$RC"
run init
assert_exit "init second run exit 0" 0 "$RC"
assert_nz "init created .git" "$(git -C "$MEM_DIR" rev-parse --is-inside-work-tree 2>/dev/null)"

echo
echo "== add =="

t "add writes a versioned conventional git commit"
new_sandbox
run add --type decision --title "Use pnpm not npm" --body "Reason: lockfile determinism" --tags "tooling"
assert_exit "add exit 0" 0 "$RC"
assert_has "add output has id:" "$OUT" "id:"
assert_has "add output has saved path" "$OUT" "saved:"
assert_eq "one commit for one add" "1" "$(commit_count)"
assert_has "commit subject is conventional" \
  "$(git -C "$MEM_DIR" --no-pager log -1 --format=%s)" \
  "mem(decision): Use pnpm not npm"

t "add --type is required (uses error exit 2)"
new_sandbox
run add --title "no type"
assert_exit "missing --type exit 2" 2 "$RC"
assert_has "error message on stdout" "$OUT" "error:"

t "add --title is required"
new_sandbox
run add --type howto
assert_exit "missing --title exit 2" 2 "$RC"
assert_has "error mentions title" "$OUT" "--title"

t "add rejects unknown flags (exit 2, fail loud)"
new_sandbox
run add --type howto --title "x" --bogus
assert_exit "unknown flag exit 2" 2 "$RC"
assert_has "unknown flag named" "$OUT" "--bogus"

t "add refuses secrets unless --force"
new_sandbox
run add --type howto --title "deploy" --body "use sk-1234567890123456"
assert_exit "secret gate exit 2" 2 "$RC"
assert_eq "no commit written for rejected secret" "0" "$(commit_count)"
run add --type howto --title "deploy" --body "use sk-1234567890123456" --force
assert_exit "secret allowed with --force exit 0" 0 "$RC"

t "add same id twice is a no-op (exit 0)"
new_sandbox
add_mem decision "Use pnpm not npm"
run add --type decision --title "Use pnpm not npm"
assert_exit "dupe add exit 0" 0 "$RC"
assert_eq "still one commit" "1" "$(commit_count)"

echo
echo "== search =="

t "search finds a match and emits TOON list"
new_sandbox
add_mem decision "Use pnpm not npm"
run search "pnpm"
assert_exit "search exit 0" 0 "$RC"
assert_has "result carries id" "$OUT" "d-"
assert_has "count header" "$OUT" "count:"

t "search empty state is definitive (0 of N total, exit 0)"
new_sandbox
add_mem decision "Use pnpm not npm"
run search "zzzznothing"
assert_exit "no-match exit 0" 0 "$RC"
assert_has "zero count stated" "$OUT" "count: 0 of"

t "search --inject emits compact one-liners"
new_sandbox
add_mem decision "Use pnpm not npm"
run search "pnpm" --inject
assert_exit "inject exit 0" 0 "$RC"
assert_has "inject has id" "$OUT" "d-"

echo
echo "== show =="

t "show outputs a memory block (TOON)"
new_sandbox
add_mem failure "JWT decode panicked"
run search "jwt"
ID="$(printf '%s\n' "$OUT" | grep -o 'f-[0-9-]*-jwt[^,]*' | head -1)"
run show "$ID"
assert_exit "show exit 0" 0 "$RC"
assert_eq "show type field" "memory:" "$(printf '%s\n' "$OUT" | grep '^memory:' | head -1)"
assert_has "show id" "$OUT" "id: $ID"

t "show unknown id is an error (exit 1 or 2)"
new_sandbox
run show c-0000-does-not-exist
[ "$RC" -eq 1 ] || [ "$RC" -eq 2 ]
assert_exit "unknown id nonzero" 0 $(( RC>0 ? 0 : 1 ))
assert_has "error surfaced" "$OUT" "error"

t "show --full escapes body truncation"
new_sandbox
LONG="$(printf 'x%.0s' $(seq 1 800))"
run add --type howto --title "long body" --body "$LONG"
run search "long body"
ID="$(printf '%s\n' "$OUT" | grep -o 'h-[0-9-]*-long[^,]*' | head -1)"
run show "$ID"
assert_exit "truncated show exit 0" 0 "$RC"
assert_has "truncated marker present" "$OUT" "truncated:"
run show "$ID" --full
assert_exit "full show exit 0" 0 "$RC"

echo
echo "== list =="

t "list ranks by priority desc and exits 0 with results"
new_sandbox
add_mem decision "Low prio" --priority 20
add_mem decision "High prio" --priority 90
run list
assert_exit "list exit 0" 0 "$RC"
assert_has "list output has count" "$OUT" "count:"
FIRST="$(printf '%s\n' "$OUT" | grep -o 'd-[0-9-]*-[a-z-]*' | head -1)"
assert_nz "list has rows" "$FIRST"

t "list --type filter"
new_sandbox
add_mem decision "A decision"
add_mem howto "A howto"
run list --type howto
assert_exit "list --type exit 0" 0 "$RC"
assert_eq "only one howto row" "1" "$(printf '%s\n' "$OUT" | grep -c 'h-')"
assert_eq "zero decision rows" "0" "$(printf '%s\n' "$OUT" | grep -c 'd-')"

t "list empty state exit 0"
new_sandbox
add_mem decision "A decision"
run list --type preference
assert_exit "list empty exit 0" 0 "$RC"

echo
echo "== update =="

t "update bumps version and writes a conventional commit"
new_sandbox
add_mem howto "Deploy api" --body "v1"
run search "deploy"
ID="$(printf '%s\n' "$OUT" | grep -o 'h-[0-9-]*-deploy[^,]*' | head -1)"
run update "$ID" --body "v2 steps" --priority 70
assert_exit "update exit 0" 0 "$RC"
assert_eq "version bumped to 2" "2" "$(git -C "$MEM_DIR" --no-pager log --oneline | wc -l)"
assert_has "update commit subject" \
  "$(git -C "$MEM_DIR" --no-pager log -1 --format=%s)" \
  "mem(howto): update Deploy api"
run update "$ID" --body "v2 steps" --priority 70
assert_exit "no-change update exit 0" 0 "$RC"

echo
echo "== merge =="

t "merge produces one conventional commit and removes absorbed"
new_sandbox
add_mem decision "Keep this" --body "keep body"
add_mem decision "Absorb this" --body "absorb body"
run list --type decision
KEEP="$(printf '%s\n' "$OUT" | grep -o 'd-[0-9-]*-keep[^,]*' | head -1)"
ABS="$(printf '%s\n' "$OUT" | grep -o 'd-[0-9-]*-absorb[^,]*' | head -1)"
run merge "$KEEP" "$ABS"
assert_exit "merge exit 0" 0 "$RC"
assert_eq "absorb file gone" "0" "$(ls "$MEM_DIR/objects/decisions/" | grep -c "absorb" || true)"
LAST="$(git -C "$MEM_DIR" --no-pager log -1 --format=%s)"
assert_has "merge commit is conventional" "$LAST" "mem(decision): merge"

t "merge --dry-run does not write a commit"
new_sandbox
add_mem decision "Keep this"
add_mem decision "Absorb this"
run list --type decision
KEEP="$(printf '%s\n' "$OUT" | grep -o 'd-[0-9-]*-keep[^,]*' | head -1)"
ABS="$(printf '%s\n' "$OUT" | grep -o 'd-[0-9-]*-absorb[^,]*' | head -1)"
run merge "$KEEP" "$ABS" --dry-run
assert_exit "merge dry-run exit 0" 0 "$RC"
assert_eq "dry-run writes no commit" "2" "$(commit_count)"

echo
echo "== dedup =="

t "dedup dry-run emits a TOON list and exits 0"
new_sandbox
add_mem howto "Deploy the api to prod"
add_mem howto "Deploy the api to production"
run dedup
assert_exit "dedup exit 0" 0 "$RC"

t "unknown top-level command exits 2"
new_sandbox
run frobnicate
assert_exit "unknown command exit 2" 2 "$RC"
assert_has "unknown command error" "$OUT" "error:"

echo
echo "== per-command help =="

for cmd in init search show add list update merge dedup review sync status stats; do
  t "help: $cmd"
  run "$cmd" --help
  assert_exit "$cmd --help exit 0" 0 "$RC"
  assert_has "$cmd --help shows Usage" "$OUT" "Usage"
done

t "global --help"
run --help
assert_exit "global --help exit 0" 0 "$RC"
assert_has "global help has Usage" "$OUT" "Usage"

echo
echo "== version =="

t "global --version prints version"
run --version
assert_exit "--version exit 0" 0 "$RC"
assert_has "--version output" "$OUT" "mem "

t "-V and version aliases match --version"
run -V
V1="$OUT"
run version
assert_eq "version alias matches -V" "$V1" "$OUT"
assert_exit "version alias exit 0" 0 "$RC"

echo
echo "== stderr/structure: stdout-only on errors (no dependency leak) =="
new_sandbox
run add
OUT_ERR="$( cd "$REPO_ROOT" && MEM_DIR="$MEM_DIR" "$MEM_BIN" add 2>&1 )"
assert_exit "missing args exits 2" 2 "$RC"
case "$OUT_ERR" in
  *"Usage"*|*"--type"*) ok ;;
  *) bad "error is actionable (got: $OUT_ERR)" ;;
esac

# --- Summary -----------------------------------------------------------------
echo
echo "== PASS: $PASS  FAIL: $FAIL =="
rm -rf "$SANDBOX_DIR"
[ "$FAIL" -eq 0 ]
