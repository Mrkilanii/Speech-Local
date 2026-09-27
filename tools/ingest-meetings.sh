#!/bin/bash
# Ingest meetings SpeechLocal filed into the vault's raw/meetings/ into wiki/,
# one Claude session per meeting. See
# docs/decisions/13_meetings_reach_the_wiki_through_a_claude_session.md.
#
# The app never runs this and never uses the network. This script is the only
# part that does, and it only ever *reads* raw/: interpretation is written by a
# `claude -p` session following the vault's own ingest rules.
#
# Written for /bin/bash 3.2 (what launchd runs on macOS): no mapfile, no
# associative arrays, no ${var,,}.
#
# Usage: tools/ingest-meetings.sh [--dry-run] [--max N] [--since YYYY-MM-DD|all]
#
# Environment (all optional):
#   VAULT           vault root                (default ~/Documents/second-brain)
#   CLAUDE_BIN      claude executable         (default: `claude` on PATH)
#   INGEST_MODEL    passed as --model if set
#   INGEST_TIMEOUT  seconds per meeting before the session is killed (default 1200)

set -u

VAULT="${VAULT:-$HOME/Documents/second-brain}"
VAULT="${VAULT%/}"
STATE_DIR="$HOME/Library/Application Support/SpeechLocal"
STATE_FILE="$STATE_DIR/ingested.txt"
SINCE_FILE="$STATE_DIR/ingest-since"
LOCK_DIR="$STATE_DIR/ingest.lock"
LOG_DIR="$HOME/Library/Logs/SpeechLocal"
LOG_FILE="$LOG_DIR/ingest.log"
RUNS_DIR="$LOG_DIR/ingest-runs"
MEETINGS_REL="raw/meetings"
TIMEOUT="${INGEST_TIMEOUT:-1200}"

DRY_RUN=0
MAX=1
SINCE=""
SINCE_ORIGIN=""

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --max)
            shift
            MAX="${1:-}"
            case "$MAX" in ''|*[!0-9]*|0) echo "--max needs a positive integer" >&2; exit 2 ;; esac
            ;;
        --since)
            shift
            SINCE="${1:-}"
            SINCE_ORIGIN="--since flag"
            case "$SINCE" in
                all) ;;
                [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
                *) echo "--since needs YYYY-MM-DD or 'all'" >&2; exit 2 ;;
            esac
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# --- logging --------------------------------------------------------------
# A live run appends every line to ingest.log. It echoes to stdout only on a
# terminal: under launchd stdout already goes to ingest.log, and echoing would
# write every line twice. A dry run writes nothing anywhere but the terminal.

RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"

log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%dT%H:%M:%S%z') [$RUN_ID] $level $*"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "$line"
        return
    fi
    mkdir -p "$LOG_DIR" 2>/dev/null
    echo "$line" >> "$LOG_FILE"
    if [ -t 1 ]; then echo "$line"; fi
}

# --- since ----------------------------------------------------------------
# Without a flag, the date comes from $SINCE_FILE, which `make install-ingest`
# writes once with the install day. So a fresh install ingests meetings filed
# from that day on, never the backlog. Without either, a live run refuses:
# ingesting every old recording is a decision, not a default.

if [ -z "$SINCE" ] && [ -f "$SINCE_FILE" ]; then
    SINCE="$(tr -d '[:space:]' < "$SINCE_FILE")"
    SINCE_ORIGIN="$SINCE_FILE"
fi

# --- helpers --------------------------------------------------------------

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

# The date a raw meeting file belongs to: its YYYY-MM-DD prefix (VaultWriter
# always writes one), else its modification day.
file_day() {
    local name="$1" path="$2"
    case "$name" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*) echo "${name:0:10}" ;;
        *) date -r "$(mtime "$path")" +%Y-%m-%d ;;
    esac
}

# True when the file carries nothing to ingest: no notes and no transcript
# words, only frontmatter, headings, the You/Them legend and the placeholder.
is_empty_meeting() {
    ! awk '
        NR == 1 && $0 == "---" { infm = 1; next }
        infm && $0 == "---"   { infm = 0; next }
        infm                  { next }
        /^#/                  { next }
        /^_"You" is the microphone/ { next }
        /^_Nothing was transcribed\._$/ { next }
        { print }
    ' "$1" | grep -q '[[:alnum:]]'
}

# Why a file is already done, or nothing. Three independent records, because
# the six meetings ingested by hand before this script existed are named only
# in their source-summary pages, not in wiki/log.md or the state file.
already_ingested() {
    local rel="$1" name="$2"
    if [ -f "$STATE_FILE" ] && grep -qxF "$rel" "$STATE_FILE"; then
        echo "in state file"; return
    fi
    if grep -qF "$name" "$VAULT/wiki/log.md" 2>/dev/null; then
        echo "named in wiki/log.md"; return
    fi
    if grep -rqF "$name" "$VAULT/wiki/source-summaries" 2>/dev/null; then
        echo "named in wiki/source-summaries/"; return
    fi
}

build_prompt() {
    local rel="$1"
    cat <<EOF
Ingest exactly one raw source into this vault's wiki: ${rel}

It is a recording filed by SpeechLocal, an on-device transcription app, and it
is source material. Follow this vault's own rules exactly: CLAUDE.md,
_system/structure.md (in particular "After ingesting or syncing a snapshot"),
_system/page-conventions.md, and the ingest skill at
.agent-skills/ingest/SKILL.md. This run is unattended; nobody will answer a
question. These rules override the skill where they differ:

1. Process ${rel} and nothing else, even if other raw files look unread.
2. raw/ is immutable. Read ${rel}; never modify, rename, move or delete
   anything under raw/.
3. First read wiki/index.md and check wiki/source-summaries/. If a
   source-summary already lists ${rel} in its sources, change nothing and end
   with the line: INGEST-RESULT: ALREADY-INGESTED
4. Create one source-summary page in wiki/source-summaries/, shaped like the
   existing ones: frontmatter exactly per page-conventions.md, type
   source-summary, area set, sources listing ${rel}, a filename of the form
   "<Descriptive Title> YYYY-MM-DD.md". Say what the recording actually is:
   several earlier "meetings" were ambient captures of a video or podcast.
   The transcript is machine speech recognition and garbles proper nouns;
   label anything you infer (who is speaking, which show, which company) as an
   inference. "You" is the microphone and "Them" is the call's audio, not
   identified people. If there is too little to carry anything, the summary
   says so in a few lines and nothing else changes.
5. Merge durable knowledge (a decision, a fact, a commitment, a date) into the
   canonical owning pages in wiki/projects, wiki/concepts, wiki/people or
   wiki/entities only where it is genuinely warranted. Do not create a
   canonical page for a passing mention. Keep the link discipline in
   _system/structure.md.
6. Register every new page in wiki/index.md in its section. Append one entry
   to wiki/log.md in the existing format, naming ${rel}, the pages created and
   updated, and any uncertainty.
7. Write only inside wiki/. Do not edit any project repository or handoff
   file outside this vault.
8. Commit with git add wiki/ and one git commit whose one-line message names
   the pages, then git push. If the push fails, do not force it and do not
   rewrite history; say so in the result line.
9. End your reply with exactly one line:
   INGEST-RESULT: OK <pages created and updated>
   or INGEST-RESULT: FAILED <reason>
EOF
}

# The exact argv for one meeting. Writes are limited to wiki/ and denied in
# raw/ by permission rule ("//" is the rule syntax for an absolute path, and
# Edit rules also govern Write); dontAsk turns anything else that would prompt into
# a denial, since nobody is there to answer.
build_command() {
    local prompt="$1"
    CMD=("$CLAUDE_BIN" -p "$prompt"
        --add-dir "$VAULT"
        --output-format json
        --permission-mode dontAsk
        --tools "Read,Glob,Grep,Edit,Write,Bash"
        --allowedTools "Edit(/$VAULT/wiki/**)"
            "Bash(git status *)" "Bash(git diff *)" "Bash(git log *)"
            "Bash(git show *)" "Bash(git add *)" "Bash(git commit *)"
            "Bash(git push)" "Bash(git push *)"
        --disallowedTools "Edit(/$VAULT/raw/**)"
        --strict-mcp-config
        --no-chrome)
    if [ -n "${INGEST_MODEL:-}" ]; then CMD+=(--model "$INGEST_MODEL"); fi
}

# --- preflight ------------------------------------------------------------

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"

if [ ! -d "$VAULT" ]; then
    log REFUSE "no vault at $VAULT"
    exit 1
fi
# Absolute and resolved: the permission rules below are absolute paths.
VAULT="$(cd "$VAULT" && pwd -P)"
MEETINGS_DIR="$VAULT/$MEETINGS_REL"

if ! listing_err="$(ls "$MEETINGS_DIR" 2>&1 >/dev/null)"; then
    case "$listing_err" in
        *"Operation not permitted"*)
            log FAIL "macOS privacy denied access to $MEETINGS_DIR (Documents folder). Grant the launchd job's bash access; see docs/verification.md 'Meetings reach the wiki'." ;;
        *)
            log FAIL "cannot read $MEETINGS_DIR: $listing_err" ;;
    esac
    exit 1
fi

# --- candidates -----------------------------------------------------------
# Oldest first: by the file's day, then by modification time within the day
# (a custom meeting title would otherwise sort before an earlier untitled one).

SORTED="$(
    for path in "$MEETINGS_DIR"/*.md; do
        [ -f "$path" ] || continue
        name="$(basename "$path")"
        [ "$name" = "README.md" ] && continue
        printf '%s\t%s\t%s\n' "$(file_day "$name" "$path")" "$(mtime "$path")" "$name"
    done | sort -t "$(printf '\t')" -k1,1 -k2,2n
)"

PENDING=()
N_DONE=0; N_OLD=0; N_EMPTY=0
DONE_LINES=""
while IFS="$(printf '\t')" read -r day _ name; do
    [ -n "$name" ] || continue
    rel="$MEETINGS_REL/$name"
    if [ -n "$SINCE" ] && [ "$SINCE" != "all" ] && [[ "$day" < "$SINCE" ]]; then
        N_OLD=$((N_OLD + 1)); continue
    fi
    why="$(already_ingested "$rel" "$name")"
    if [ -n "$why" ]; then
        N_DONE=$((N_DONE + 1))
        DONE_LINES="$DONE_LINES  done   $rel ($why)
"
        continue
    fi
    if is_empty_meeting "$VAULT/$rel"; then
        N_EMPTY=$((N_EMPTY + 1))
        DONE_LINES="$DONE_LINES  empty  $rel (no notes, no transcript; never sent to Claude)
"
        continue
    fi
    PENDING+=("$rel")
done <<< "$SORTED"

# --- dry run --------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN: nothing is run, written, locked or logged."
    echo "vault:   $VAULT"
    if [ -n "$SINCE" ]; then
        echo "since:   $SINCE (from $SINCE_ORIGIN)"
    else
        echo "since:   not set. A live run would REFUSE; run 'make install-ingest' or pass --since."
    fi
    echo "max:     $MAX per run"
    echo "state:   $STATE_FILE"
    echo "log:     $LOG_FILE"
    echo "claude:  ${CLAUDE_BIN:-NOT FOUND on PATH (a live run would fail)}"
    dirty="$(git -C "$VAULT" status --porcelain 2>&1)"
    if [ -n "$dirty" ]; then
        echo "vault:   HAS UNCOMMITTED CHANGES, so a live run would refuse now:"
        echo "$dirty" | sed 's/^/           /'
    else
        echo "vault:   clean"
    fi
    echo
    echo "older than since: $N_OLD file(s), ignored"
    printf '%s' "$DONE_LINES"
    if [ "${#PENDING[@]}" -eq 0 ]; then
        echo "pending: none. A live run would do nothing."
        exit 0
    fi
    i=0
    for rel in "${PENDING[@]}"; do
        if [ "$i" -lt "$MAX" ]; then tag="THIS RUN"; else tag="later   "; fi
        echo "  $tag $rel"
        i=$((i + 1))
    done
    rel="${PENDING[0]}"
    CLAUDE_BIN="${CLAUDE_BIN:-claude}"
    build_command "$(build_prompt "$rel")"
    echo
    echo "=== prompt for $rel ==="
    build_prompt "$rel"
    echo
    echo "=== command (cwd: $VAULT) ==="
    printf '%q ' "${CMD[@]}"
    echo
    exit 0
fi

# --- live run -------------------------------------------------------------

if [ -z "$SINCE" ]; then
    log REFUSE "no since date: $SINCE_FILE is missing and no --since was given. Run 'make install-ingest' or pass --since YYYY-MM-DD|all."
    exit 1
fi

mkdir -p "$STATE_DIR" "$RUNS_DIR"

# One run at a time. mkdir is atomic; a lock whose pid is gone is stale.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        log REFUSE "another run holds the lock (pid $holder)"
        exit 0
    fi
    log WARN "removing stale lock (pid ${holder:-unknown} is not running)"
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log REFUSE "could not take the lock at $LOCK_DIR"
        exit 1
    fi
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

log START "since=$SINCE max=$MAX pending=${#PENDING[@]} done=$N_DONE empty=$N_EMPTY older=$N_OLD"

if [ "${#PENDING[@]}" -eq 0 ]; then
    log DONE "nothing to ingest"
    exit 0
fi

if [ -z "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then
    log FAIL "claude CLI not found on PATH ($PATH)"
    exit 1
fi

if ! git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
    log REFUSE "$VAULT is not a git repository"
    exit 1
fi

# Checks the session's work instead of trusting its exit code: a zero exit
# only means the CLI finished, not that the vault holds a summary.
verify() {
    local rel="$1" name="$2" before="$3" verdict="$4"
    local after problems=""
    after="$(git -C "$VAULT" rev-parse HEAD)"
    if [ -n "$(git -C "$VAULT" status --porcelain -- raw)" ] \
        || [ -n "$(git -C "$VAULT" diff --name-only "$before" "$after" -- raw)" ]; then
        log FAIL "RAW CHANGED during $rel. Nothing was reverted; inspect: git -C \"$VAULT\" log -p $before..HEAD -- raw"
        return 1
    fi
    if [ "$verdict" = "ALREADY-INGESTED" ]; then
        grep -rqF "$name" "$VAULT/wiki/source-summaries" || problems="$problems; said already ingested but no source-summary names it"
    else
        grep -rqF "$name" "$VAULT/wiki/source-summaries" || problems="$problems; no source-summary names it"
        grep -qF "$name" "$VAULT/wiki/log.md" || problems="$problems; wiki/log.md does not name it"
        [ "$after" != "$before" ] || problems="$problems; no commit was made"
        [ -z "$(git -C "$VAULT" status --porcelain)" ] || problems="$problems; vault left with uncommitted changes"
    fi
    if [ -n "$problems" ]; then
        log FAIL "$rel: ${problems#; }"
        return 1
    fi
    if [ "$after" != "$before" ]; then
        unpushed="$(git -C "$VAULT" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')"
        if [ "$unpushed" != "0" ]; then
            log WARN "$rel: committed but not pushed ($unpushed commit(s) ahead of upstream)"
        fi
    fi
    return 0
}

n=0
failed=0
for rel in "${PENDING[@]}"; do
    [ "$n" -lt "$MAX" ] || break
    n=$((n + 1))
    name="$(basename "$rel")"

    # Checked before every meeting, not once: Omar may start editing mid-run,
    # and a session committing his half-finished edits is the thing to avoid.
    dirty="$(git -C "$VAULT" status --porcelain)"
    if [ -n "$dirty" ]; then
        log REFUSE "vault has uncommitted changes, not mixing an ingest into them: $(echo "$dirty" | head -5 | tr '\n' ' ')"
        exit 1
    fi

    before="$(git -C "$VAULT" rev-parse HEAD)"
    out="$RUNS_DIR/$RUN_ID-${name%.md}.json"
    err="$RUNS_DIR/$RUN_ID-${name%.md}.stderr"
    build_command "$(build_prompt "$rel")"

    log RUN "$rel (timeout ${TIMEOUT}s, output $out)"
    started=$(date +%s)
    (cd "$VAULT" && exec "${CMD[@]}") > "$out" 2> "$err" < /dev/null &
    cpid=$!
    # Watchdog (macOS has no `timeout`). It polls rather than sleeping the
    # whole period, so it ends on its own within a second of the session.
    (
        waited=0
        while kill -0 "$cpid" 2>/dev/null; do
            if [ "$waited" -ge "$TIMEOUT" ]; then kill -TERM "$cpid" 2>/dev/null; break; fi
            sleep 1
            waited=$((waited + 1))
        done
    ) &
    wpid=$!
    wait "$cpid" 2>/dev/null
    rc=$?
    wait "$wpid" 2>/dev/null
    took=$(( $(date +%s) - started ))

    result="$(jq -r '.result // empty' "$out" 2>/dev/null)"
    verdict_line="$(printf '%s\n' "$result" | grep '^INGEST-RESULT:' | tail -1)"
    meta="$(jq -r '"session=\(.session_id // "?") turns=\(.num_turns // "?") cost_usd=\(.total_cost_usd // "?") is_error=\(.is_error // "?")"' "$out" 2>/dev/null)"

    if [ "$rc" -ne 0 ]; then
        if [ "$took" -ge "$TIMEOUT" ]; then
            log FAIL "$rel timed out after ${took}s; killed. $meta"
        else
            log FAIL "$rel: claude exited $rc after ${took}s. $meta stderr: $(tail -c 400 "$err" | tr '\n' ' ')"
        fi
        failed=1
        continue
    fi

    case "$verdict_line" in
        "INGEST-RESULT: OK"*) verdict=OK ;;
        "INGEST-RESULT: ALREADY-INGESTED"*) verdict=ALREADY-INGESTED ;;
        *) verdict=FAILED ;;
    esac
    if [ "$verdict" = "FAILED" ]; then
        log FAIL "$rel: session did not report success after ${took}s: ${verdict_line:-no INGEST-RESULT line}. $meta"
        failed=1
        continue
    fi

    if verify "$rel" "$name" "$before" "$verdict"; then
        echo "$rel" >> "$STATE_FILE"
        log OK "$rel in ${took}s. ${verdict_line#INGEST-RESULT: } $meta"
    else
        failed=1
    fi
done

log DONE "processed=$n failed=$failed"
exit "$failed"
