#!/bin/bash
# Exercises tools/ingest-meetings.sh's live path against a throwaway vault and
# a fake `claude`, so the lock, the refusals, the post-run checks and the state
# file are proved without spending quota or touching the real vault.
#
# Usage: tools/test-ingest-meetings.sh      (exit 0 = every case passed)

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/ingest-meetings.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/ingest-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

export HOME="$T/home"
export VAULT="$T/vault"
export CLAUDE_BIN="$T/fake-claude"
STATE="$HOME/Library/Application Support/SpeechLocal"
LOG="$HOME/Library/Logs/SpeechLocal/ingest.log"
mkdir -p "$HOME" "$VAULT/raw/meetings" "$VAULT/wiki/source-summaries"

pass=0; fail=0
check() {  # check <description> <command...>
    local what="$1"; shift
    if "$@"; then pass=$((pass + 1)); echo "ok   $what"
    else fail=$((fail + 1)); echo "FAIL $what"; fi
}
logged() { grep -q "$1" "$LOG"; }

# A fake claude. FAKE_MODE picks its behaviour; it speaks the same JSON the
# real CLI prints with --output-format json.
cat > "$CLAUDE_BIN" <<'EOF'
#!/bin/bash
prompt="$2"
rel="$(printf '%s\n' "$prompt" | head -1 | sed 's/.*wiki: //')"
name="$(basename "$rel")"
reply() { printf '{"type":"result","is_error":false,"num_turns":3,"session_id":"fake","total_cost_usd":0.01,"result":"done\\nINGEST-RESULT: %s"}\n' "$1"; }
case "${FAKE_MODE:-ok}" in
    ok)
        printf -- '---\nsources:\n  - %s\n---\n' "$rel" > "wiki/source-summaries/Summary of $name"
        echo "- ingested $rel" >> wiki/log.md
        git add wiki/ >/dev/null && git commit -qm "Ingest $name" && git push -q 2>/dev/null
        reply "OK Summary of $name" ;;
    lies)   reply "OK nothing really" ;;
    raw)    echo tampered >> "$rel"; reply "OK" ;;
    failed) reply "FAILED could not read" ;;
    crash)  echo "auth expired" >&2; exit 1 ;;
    hang)   sleep 30 ;;
esac
EOF
chmod +x "$CLAUDE_BIN"

meeting() {
    printf -- '---\ntitle: %s\n---\n\n# %s\n\n## Transcript\n\n%s\n' "$1" "$1" "$2" \
        > "$VAULT/raw/meetings/$1.md"
}
meeting 2026-08-01-old "An old meeting from before the install."
meeting 2026-09-10-standup "We agreed to ship on Friday."
meeting 2026-09-11-empty "_Nothing was transcribed._"
meeting 2026-09-12-review "Review of the budget."

git init -q --bare "$T/remote.git"
(
    cd "$VAULT" && git init -q && git config user.email t@t && git config user.name t \
        && echo "# Log" > wiki/log.md && git add -A && git commit -qm init \
        && git remote add origin "$T/remote.git" && git push -q -u origin HEAD 2>/dev/null
)
head_now() { git -C "$VAULT" rev-parse HEAD; }

# 1. No since date anywhere: a live run refuses.
"$SCRIPT" >/dev/null; rc=$?
check "no since date -> refuses" [ "$rc" -eq 1 ]
check "no since date -> logged" logged "REFUSE no since date"

# 2. Dry run writes nothing.
rm -f "$LOG"
"$SCRIPT" --dry-run --since 2026-09-01 > "$T/dry.txt"
check "dry run lists the oldest pending as THIS RUN" grep -q "THIS RUN raw/meetings/2026-09-10-standup.md" "$T/dry.txt"
check "dry run skips the empty meeting" grep -q "empty  raw/meetings/2026-09-11-empty.md" "$T/dry.txt"
check "dry run ignores files older than since" grep -q "older than since: 1" "$T/dry.txt"
check "dry run writes no log" [ ! -e "$LOG" ]
check "dry run writes no state" [ ! -e "$STATE/ingested.txt" ]

# 3. Happy path: one meeting (max 1), oldest first, recorded after checks pass.
mkdir -p "$STATE"; echo 2026-09-01 > "$STATE/ingest-since"
FAKE_MODE=ok "$SCRIPT" >/dev/null; rc=$?
check "happy path exits 0" [ "$rc" -eq 0 ]
check "happy path records the oldest pending" grep -qx "raw/meetings/2026-09-10-standup.md" "$STATE/ingested.txt"
check "happy path records only one (max 1)" [ "$(wc -l < "$STATE/ingested.txt" | tr -d ' ')" -eq 1 ]
check "happy path logs OK with cost" logged "OK raw/meetings/2026-09-10-standup.md.*cost_usd=0.01"
check "happy path pushed" [ "$(git -C "$VAULT" rev-parse HEAD)" = "$(git -C "$T/remote.git" rev-parse HEAD)" ]

# 4. The next run takes the next one; the one after finds nothing.
FAKE_MODE=ok "$SCRIPT" >/dev/null
check "second run takes the next meeting" grep -qx "raw/meetings/2026-09-12-review.md" "$STATE/ingested.txt"
before="$(head_now)"
FAKE_MODE=ok "$SCRIPT" >/dev/null; rc=$?
check "third run: nothing to ingest, exit 0" [ "$rc" -eq 0 ]
check "third run: no commit" [ "$(head_now)" = "$before" ]
check "empty meeting never recorded as ingested" [ "$(grep -c empty "$STATE/ingested.txt")" -eq 0 ]

# 5. A file already named in wiki/log.md (ingested by hand) is not redone.
meeting 2026-09-13-byhand "Handled manually."
echo "- by hand: 2026-09-13-byhand.md" >> "$VAULT/wiki/log.md"
git -C "$VAULT" commit -qam "hand ingest"
"$SCRIPT" --dry-run > "$T/dry2.txt"
check "file named in wiki/log.md counts as done" grep -q "done   raw/meetings/2026-09-13-byhand.md (named in wiki/log.md)" "$T/dry2.txt"
git -C "$VAULT" add raw && git -C "$VAULT" commit -qm "file raw"

# 6. Uncommitted changes in the vault: refuse, run nothing.
meeting 2026-09-14-next "Next steps."
git -C "$VAULT" add raw && git -C "$VAULT" commit -qm "file raw"
echo "Omar is typing" >> "$VAULT/wiki/log.md"
FAKE_MODE=ok "$SCRIPT" >/dev/null; rc=$?
check "dirty vault -> refuses" [ "$rc" -eq 1 ]
check "dirty vault -> logged" logged "REFUSE vault has uncommitted changes"
check "dirty vault -> not recorded" [ "$(grep -c 09-14 "$STATE/ingested.txt")" -eq 0 ]
git -C "$VAULT" checkout -q -- wiki/log.md

# 7. Another live run holds the lock.
mkdir -p "$STATE/ingest.lock"; sleep 60 & holder=$!; echo "$holder" > "$STATE/ingest.lock/pid"
FAKE_MODE=ok "$SCRIPT" >/dev/null
check "held lock -> refuses" logged "REFUSE another run holds the lock (pid $holder)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
# ... and a lock left by a dead process is taken over.
FAKE_MODE=failed "$SCRIPT" >/dev/null
check "stale lock -> removed" logged "WARN removing stale lock"
check "lock released after the run" [ ! -e "$STATE/ingest.lock" ]

# 8. The session says it failed / says OK but did nothing / crashes / hangs.
check "reported failure -> logged, not recorded" logged "FAIL raw/meetings/2026-09-14-next.md: session did not report success"
FAKE_MODE=lies "$SCRIPT" >/dev/null; rc=$?
check "claimed OK without work -> fails verification" logged "FAIL raw/meetings/2026-09-14-next.md: no source-summary names it"
check "claimed OK without work -> exit 1" [ "$rc" -eq 1 ]
FAKE_MODE=crash "$SCRIPT" >/dev/null
check "non-zero claude exit -> logged with stderr" logged "claude exited 1 .*auth expired"
INGEST_TIMEOUT=2 FAKE_MODE=hang "$SCRIPT" >/dev/null
check "hung session -> killed at timeout" logged "timed out after"
check "none of the failures recorded" [ "$(grep -c 09-14 "$STATE/ingested.txt")" -eq 0 ]

# 9. A session that changes raw/ is caught and never recorded.
FAKE_MODE=raw "$SCRIPT" >/dev/null
check "raw change -> RAW CHANGED" logged "FAIL RAW CHANGED during raw/meetings/2026-09-14-next.md"
check "raw change -> not recorded" [ "$(grep -c 09-14 "$STATE/ingested.txt")" -eq 0 ]

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
