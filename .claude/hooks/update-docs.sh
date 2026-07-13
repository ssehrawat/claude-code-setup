#!/bin/bash
# update-docs.sh — Stop hook that triggers doc-maintainer and qa-expert subagents
# when source code files have been modified during a user turn.
#
# Install location: ~/.claude/hooks/update-docs.sh
# Referenced from:  ~/.claude/settings.json (Stop event)
#
# Source classification comes from the shared library
# ~/.claude/lib/classify-changes.sh (single source of truth, PLAN-004 D17).
# When the library is missing (install predating ~/.claude/lib), an inline
# fallback replicates the SAME boundary — .sql included, core.quotepath=false
# included — so both install states classify identically.
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
#   - Single-turn autopilot → sentinel created and removed within one
#     turn, so the bypass above never fires. Cleanup touches a
#     finished-marker instead; the next Stop fire saves the fingerprint,
#     consumes the marker, and skips.
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
# This inline pattern is the FAIL-OPEN FALLBACK for installs predating
# ~/.claude/lib. It includes .sql to match the shared library (D19): the
# fallback exists for safety during the un-reinstalled window, not to preserve
# the pre-D19 boundary — without .sql here, a .sql-only diff would be "not
# source" to this hook but "source" to the qa/autopilot guards on the same
# machine, which is exactly the cross-consumer drift D17 eliminates.
SOURCE_EXT_PATTERN='\.(ts|tsx|js|jsx|mjs|cjs|py|rs|go|java|rb|cpp|c|h|hpp|cs|swift|kt|scala|ex|exs|clj|zig|sh|lua|php|dart|sql)$'

# ── Shared change classifier (single source of truth, PLAN-004 D17) ──
# WHY guarded: a Stop hook must never block Claude's stop over its own config.
# If the library is missing (install.sh not re-run yet), fall back to local
# definitions that replicate the shared library's behavior — same allowlist
# (.sql included) and same quotepath handling — so both install states agree.
if [ -f "$HOME/.claude/lib/classify-changes.sh" ]; then
  . "$HOME/.claude/lib/classify-changes.sh"
else
  collect_changed_files() {
    # WHY core.quotepath=false: matches the shared library — git C-quotes
    # non-ASCII paths by default, and the trailing quote defeats the
    # $-anchored extension match.
    { git -c core.quotepath=false diff --name-only HEAD 2>/dev/null
      git -c core.quotepath=false ls-files --others --exclude-standard 2>/dev/null
    } | sort -u | grep -v '^[[:space:]]*$'
  }
  source_files_from_stdin() {
    grep -E "$SOURCE_EXT_PATTERN"
  }
fi

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
  SA_SOURCE=$(collect_changed_files | source_files_from_stdin)
  if [ -n "$SA_SOURCE" ]; then
    SA_FP=$(printf '%s\n' "$SA_SOURCE" | sort | compute_hash)
    printf '%s' "$SA_FP" > "$FINGERPRINT_FILE" 2>/dev/null
    log "Updated fingerprint after agent run: $SA_FP"
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
    AP_SOURCE=$(collect_changed_files | source_files_from_stdin)
    if [ -n "$AP_SOURCE" ]; then
      AP_FP=$(printf '%s\n' "$AP_SOURCE" | sort | compute_hash)
      printf '%s' "$AP_FP" > "$FINGERPRINT_FILE" 2>/dev/null
      log "Saved fingerprint during autopilot bypass"
    fi
    exit 0
  fi
fi

# ── Autopilot finished-marker: save fingerprint and consume ──
# WHY: a single-turn autopilot run creates AND removes its sentinel inside
# one turn, and Stop only fires between turns — so the sentinel bypass above
# never executes and no fingerprint is ever saved for that run. The command
# cannot save it either: the fingerprint file is keyed by session_id, which
# only this hook receives. The marker is the handoff — autopilot touches it
# at cleanup; the first Stop fire after that saves the fingerprint here,
# consumes the marker, and skips, instead of re-triggering agents on work
# the autopilot run already tested and documented.
if [ -f "$PROJECT_DIR/.claude/.autopilot-finished" ]; then
  log "autopilot finished-marker present — saving fingerprint and consuming marker"
  AF_SOURCE=$(collect_changed_files | source_files_from_stdin)
  if [ -n "$AF_SOURCE" ]; then
    AF_FP=$(printf '%s\n' "$AF_SOURCE" | sort | compute_hash)
    printf '%s' "$AF_FP" > "$FINGERPRINT_FILE" 2>/dev/null
    log "Saved fingerprint from finished-marker: $AF_FP"
  fi
  rm -f "$PROJECT_DIR/.claude/.autopilot-finished" 2>/dev/null
  exit 0
fi

# ── Check for source file changes ────────────────────────────
ALL_CHANGED=$(collect_changed_files)
log "Changed (diff vs HEAD + untracked, unique): $(count_lines "$ALL_CHANGED") files"

SOURCE_FILES=""
if [ -n "$ALL_CHANGED" ]; then
  SOURCE_FILES=$(printf '%s\n' "$ALL_CHANGED" | source_files_from_stdin)
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
