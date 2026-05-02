#!/bin/bash
# update-docs.sh — Stop hook that triggers doc-maintainer and qa-expert subagents
# when source code files have been modified during a user turn.
#
# Install location: ~/.claude/hooks/update-docs.sh
# Referenced from:  ~/.claude/settings.json (Stop event)
#
# ═══════════════════════════════════════════════════════════════
# DEDUP STRATEGY — Fingerprint-based (stateless, single hook)
# ═══════════════════════════════════════════════════════════════
# The semantic we want: "agents run when the set of changed source
# files differs from what was last processed."
#
# Implementation:
#   - On each Stop fire, compute the sorted list of uncommitted +
#     untracked source files and hash it into a fingerprint.
#   - Compare against the last-processed fingerprint (stored per
#     session). If identical, skip — the agents already handled
#     this exact set of changes.
#   - No companion hook needed. No timers. No turn locks.
#
# Why this works:
#   - After agents run → Stop fires again → same files → same
#     fingerprint → skip.
#   - After commit → no uncommitted files → empty list → skip.
#   - New changes → different file list → new fingerprint → trigger.
#   - Autopilot mode → sentinel present → save fingerprint + skip.
#     When sentinel is removed, fingerprint still matches → skip.
#
# The fingerprint is keyed by Claude Code session_id so parallel
# sessions in different terminals don't interfere.
# ═══════════════════════════════════════════════════════════════
#
# Control flow (per Claude Code hook API):
#   - exit 0 with empty stdout = let Claude stop normally
#   - exit 0 with JSON {"decision": "block", "reason": "..."} = prevent
#     stopping, inject the reason as instructions
#
# Debug log: ~/.claude/hooks/update-docs.log

LOG_FILE="$HOME/.claude/hooks/update-docs.log"
FINGERPRINT_DIR="$HOME/.claude/hooks/.fingerprints"

# WHY: Source extensions listed explicitly rather than using a broad wildcard.
# Only files that plausibly need test/doc maintenance should trigger agents.
SOURCE_EXT_PATTERN='\.(ts|tsx|js|jsx|mjs|cjs|py|rs|go|java|rb|cpp|c|h|hpp|cs|swift|kt|scala|ex|exs|clj|zig|sh|lua|php|dart)$'

# WHY: 2 hours is generous enough to cover any realistic autopilot run,
# but short enough that a crashed sentinel doesn't block the hook forever.
STALE_SENTINEL_MINUTES=120

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
mkdir -p "$FINGERPRINT_DIR" 2>/dev/null

# Housekeeping: clean stale fingerprints + baselines from ended sessions (>7 days old)
find "$FINGERPRINT_DIR" -name "*.fingerprint" -mtime +7 -delete 2>/dev/null
find "$FINGERPRINT_DIR" -name "*.baseline" -mtime +7 -delete 2>/dev/null

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [stop] $*" >> "$LOG_FILE" 2>/dev/null
}

count_lines() {
  if [ -z "$1" ]; then
    echo 0
  else
    printf '%s\n' "$1" | grep -c -v '^[[:space:]]*$' 2>/dev/null || echo 0
  fi
}

# WHY: macOS ships md5 not md5sum, and some minimal environments have neither.
# cksum is POSIX-guaranteed so it serves as the last-resort fallback.
compute_hash() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum | cut -d' ' -f1
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q
  else
    cksum | cut -d' ' -f1
  fi
}

log "─── Stop hook fired ───"

INPUT=$(cat)

# ── Parse session_id ─────────────────────────────────────────
SESSION_ID=$(printf '%s' "$INPUT" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' 2>/dev/null)
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="no-session-id"
fi
FINGERPRINT_FILE="$FINGERPRINT_DIR/$SESSION_ID.fingerprint"
log "session_id=$SESSION_ID"

# ── Claude Code's built-in loop guard ────────────────────────
# WHY: We still update the fingerprint here even though we're skipping.
# The agents that just ran may have created new source files (test files,
# docs). Without updating, the next non-guarded Stop fire would see a
# fingerprint mismatch and re-trigger agents unnecessarily.
STOP_ACTIVE=$(printf '%s' "$INPUT" | grep -o '"stop_hook_active"[[:space:]]*:[[:space:]]*true' 2>/dev/null)
if [ -n "$STOP_ACTIVE" ]; then
  log "stop_hook_active=true — updating fingerprint and exiting 0"
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
  if [ -z "$PROJECT_DIR" ]; then
    PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null)
  fi
  if [ -z "$PROJECT_DIR" ]; then
    PROJECT_DIR="$(pwd)"
  fi
  cd "$PROJECT_DIR" 2>/dev/null
  SA_DIFF=$(git diff --name-only HEAD 2>/dev/null)
  SA_UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)
  SA_ALL=$( { printf '%s\n' "$SA_DIFF"; printf '%s\n' "$SA_UNTRACKED"; } | sort -u | grep -v '^[[:space:]]*$' 2>/dev/null )
  if [ -n "$SA_ALL" ]; then
    SA_SOURCE=$(printf '%s\n' "$SA_ALL" | grep -E "$SOURCE_EXT_PATTERN" 2>/dev/null)
    if [ -n "$SA_SOURCE" ]; then
      SA_FP=$(printf '%s\n' "$SA_SOURCE" | sort | compute_hash)
      printf '%s' "$SA_FP" > "$FINGERPRINT_FILE" 2>/dev/null
      log "Updated fingerprint after agent run: $SA_FP"
    fi
  fi
  exit 0
fi

# ── Resolve project directory ────────────────────────────────
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null)
fi
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(pwd)"
fi
log "PROJECT_DIR=$PROJECT_DIR"
cd "$PROJECT_DIR" 2>/dev/null

# ── Autopilot bypass with stale sentinel check ───────────────
# Autopilot commands handle qa-expert + doc-maintainer themselves.
# If the sentinel is present, save the fingerprint (so post-autopilot
# Stop fires see "already processed") and skip.
# Stale sentinels (>2h) are auto-cleaned to prevent permanent blocking.
if [ -f "$PROJECT_DIR/.claude/.autopilot-active" ]; then
  if find "$PROJECT_DIR/.claude/.autopilot-active" -maxdepth 0 -mmin +$STALE_SENTINEL_MINUTES 2>/dev/null | grep -q .; then
    log "WARNING: autopilot sentinel is >2h old — stale, removing"
    rm -f "$PROJECT_DIR/.claude/.autopilot-active" 2>/dev/null
  else
    log "autopilot sentinel present — computing fingerprint and skipping"
    # WHY: Save the fingerprint now so that when autopilot finishes and
    # removes the sentinel, the next Stop fire sees "already processed"
    # and skips. Without this, post-autopilot would double-trigger agents.
    AP_DIFF=$(git diff --name-only HEAD 2>/dev/null)
    AP_UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)
    AP_ALL=$( { printf '%s\n' "$AP_DIFF"; printf '%s\n' "$AP_UNTRACKED"; } | sort -u | grep -v '^[[:space:]]*$' 2>/dev/null )
    if [ -n "$AP_ALL" ]; then
      AP_SOURCE=$(printf '%s\n' "$AP_ALL" | grep -E "$SOURCE_EXT_PATTERN" 2>/dev/null)
      if [ -n "$AP_SOURCE" ]; then
        AP_FP=$(printf '%s\n' "$AP_SOURCE" | sort | compute_hash)
        printf '%s' "$AP_FP" > "$FINGERPRINT_FILE" 2>/dev/null
        log "Saved fingerprint during autopilot bypass"
      fi
    fi
    exit 0
  fi
fi

# ── Check for source file changes ────────────────────────────
DIFF_HEAD=$(git diff --name-only HEAD 2>/dev/null)
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)

log "Strategy: diff vs HEAD=$(count_lines "$DIFF_HEAD") files, untracked=$(count_lines "$UNTRACKED") files"

ALL_CHANGED=$(
  {
    printf '%s\n' "$DIFF_HEAD"
    printf '%s\n' "$UNTRACKED"
  } | sort -u | grep -v '^[[:space:]]*$' 2>/dev/null
)
log "Combined unique: $(count_lines "$ALL_CHANGED") files"

SOURCE_FILES=""
if [ -n "$ALL_CHANGED" ]; then
  SOURCE_FILES=$(printf '%s\n' "$ALL_CHANGED" | grep -E "$SOURCE_EXT_PATTERN" 2>/dev/null)
fi

SOURCE_COUNT=$(count_lines "$SOURCE_FILES")
log "Source files matched: $SOURCE_COUNT"

# ── Compute current fingerprint (defined even with 0 source files) ──
if [ -n "$SOURCE_FILES" ]; then
  CURRENT_FINGERPRINT=$(printf '%s\n' "$SOURCE_FILES" | sort | compute_hash)
else
  CURRENT_FINGERPRINT="empty"
fi

# ── Baseline: snapshot of dirty source files at session start ────────
# WHY: Without a baseline, the hook fires on any pre-existing dirty
# tree the moment a session starts, regardless of whether Claude
# touched anything. The baseline is captured on the first Stop fire
# of a session; subsequent Stops compare against it, so agents only
# fire when source files actually changed during this session.
BASELINE_FILE="$FINGERPRINT_DIR/$SESSION_ID.baseline"
if [ ! -f "$BASELINE_FILE" ]; then
  printf '%s' "$CURRENT_FINGERPRINT" > "$BASELINE_FILE" 2>/dev/null
  log "First Stop in session — saved baseline: $CURRENT_FINGERPRINT, exiting 0"
  exit 0
fi

BASELINE_FP=$(cat "$BASELINE_FILE" 2>/dev/null)
if [ "$BASELINE_FP" = "$CURRENT_FINGERPRINT" ]; then
  log "Source file set unchanged from session baseline ($BASELINE_FP) — exiting 0"
  exit 0
fi

# ── Skip if no source files remain (e.g. user reverted changes) ──────
if [ "$SOURCE_COUNT" -eq 0 ] || [ -z "$SOURCE_FILES" ]; then
  log "No source files changed — exiting 0"
  exit 0
fi

# ── Fingerprint dedup against last processed set ─────────────
if [ -f "$FINGERPRINT_FILE" ] && [ "$(cat "$FINGERPRINT_FILE" 2>/dev/null)" = "$CURRENT_FINGERPRINT" ]; then
  log "Fingerprint unchanged ($CURRENT_FINGERPRINT) — already processed, exiting 0"
  exit 0
fi

printf '%s' "$CURRENT_FINGERPRINT" > "$FINGERPRINT_FILE" 2>/dev/null
log "New fingerprint: $CURRENT_FINGERPRINT"

# ── Ensure docs/plans directory exists ───────────────────────
mkdir -p "$PROJECT_DIR/docs/plans" 2>/dev/null

# ── Truncate file list if too long ───────────────────────────
FILE_LIST=$(printf '%s\n' "$SOURCE_FILES" | head -10)
if [ "$SOURCE_COUNT" -gt 10 ]; then
  FILE_LIST="$FILE_LIST
... and $((SOURCE_COUNT - 10)) more files"
fi

log "Found $SOURCE_COUNT source files changed — blocking stop with instructions"

# ── Escape for JSON ──────────────────────────────────────────
# WHY: awk is portable across GNU and BSD (macOS). The GNU-only sed
# idiom ':a;N;$!ba' fails silently on BSD sed, producing invalid JSON.
FILE_LIST_JSON=$(printf '%s\n' "$FILE_LIST" | awk '{if(NR>1) printf "\\n"; printf "%s", $0}')

# ── Block the stop and instruct Claude to run the agents ────
cat <<EOF
{"decision": "block", "reason": "Source files were modified ($SOURCE_COUNT files). You MUST now run these two subagents in parallel before stopping:\n\n1. Run the **doc-maintainer** agent to create or update architecture docs, API docs, CLAUDE.md, README.md, and any other affected documentation.\n\n2. Run the **qa-expert** agent to review test coverage, write missing tests, update existing tests, run the test suite, and check eval coverage.\n\nBoth agents MUST run — do not skip either. Changed files:\n$FILE_LIST_JSON"}
EOF

log "Exit 0 with decision:block — agents will be triggered"
exit 0
