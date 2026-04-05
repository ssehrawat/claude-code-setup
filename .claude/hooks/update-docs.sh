#!/bin/bash
# update-docs.sh — Stop hook that triggers doc-maintainer and qa-expert subagents
# when source code files have been modified during a user turn.
#
# Install location: ~/.claude/hooks/update-docs.sh
# Referenced from:  ~/.claude/settings.json (Stop event)
#
# ═══════════════════════════════════════════════════════════════
# DEDUP STRATEGY — Turn Lock (event-driven, no timers)
# ═══════════════════════════════════════════════════════════════
# The semantic we want: "agents run at most once per user turn."
#
# A "user turn" starts when the user submits a prompt and ends when the
# next user prompt arrives. Within a single turn, Claude Code may fire
# the Stop hook multiple times (once per subagent return, once per
# follow-up, etc.) — but we only want to run the maintenance agents once.
#
# Implementation:
#   - Stop hook creates a "turn lock" file after blocking. Subsequent
#     Stop fires see the lock and skip.
#   - UserPromptSubmit hook deletes the turn lock. The next Stop after
#     a new user prompt gets a fresh slate.
#
# The lock is keyed by Claude Code session_id so parallel sessions in
# different terminals don't interfere with each other.
#
# No timers. No windows. No TTLs. Pure event-driven.
# ═══════════════════════════════════════════════════════════════
#
# Control flow (per Claude Code hook API):
#   - exit 0 with empty stdout = let Claude stop normally
#   - exit 0 with JSON {"decision": "block", "reason": "..."} = prevent
#     stopping, inject the reason as instructions
#
# Debug log: ~/.claude/hooks/update-docs.log

TURN_LOCK_DIR="$HOME/.claude/hooks/.turn-locks"
LOG_FILE="$HOME/.claude/hooks/update-docs.log"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
mkdir -p "$TURN_LOCK_DIR" 2>/dev/null

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

log "─── Stop hook fired ───"

INPUT=$(cat)

# ── Parse session_id ─────────────────────────────────────────
SESSION_ID=$(printf '%s' "$INPUT" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' 2>/dev/null)
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="no-session-id"
fi
TURN_LOCK="$TURN_LOCK_DIR/$SESSION_ID.lock"
log "session_id=$SESSION_ID"

# ── Claude Code's built-in loop guard ────────────────────────
STOP_ACTIVE=$(printf '%s' "$INPUT" | grep -o '"stop_hook_active"[[:space:]]*:[[:space:]]*true' 2>/dev/null)
if [ -n "$STOP_ACTIVE" ]; then
  log "stop_hook_active=true — exiting 0"
  exit 0
fi

# ── Turn lock check ──────────────────────────────────────────
# If the lock exists, the maintenance agents have already been triggered
# during this user turn. Skip silently until the next UserPromptSubmit
# clears the lock.
#
# RARE EDGE CASE: If the main agent produces source changes in two
# separate batches within one turn, the second batch gets skipped here.
# Escape hatch: send any follow-up message — the UserPromptSubmit hook
# will clear the lock and the next Stop fire will pick up the new changes.
if [ -f "$TURN_LOCK" ]; then
  log "turn lock exists ($TURN_LOCK) — agents already ran this turn, exiting 0"
  log "→ To force a re-run, send any follow-up message (clears the lock)"
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

# ── Autopilot bypass ─────────────────────────────────────────
# Autopilot commands handle qa-expert + doc-maintainer themselves.
# Skip the hook entirely AND set the turn lock so any post-autopilot
# Stop fires within the same turn also skip.
if [ -f "$PROJECT_DIR/.claude/.autopilot-active" ]; then
  log "autopilot sentinel present — setting turn lock and skipping"
  touch "$TURN_LOCK" 2>/dev/null
  exit 0
fi

# ── Check for source file changes ────────────────────────────
DIFF_HEAD=$(git diff --name-only HEAD 2>/dev/null)
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)
DIFF_LAST=$(git diff --name-only HEAD~1 HEAD 2>/dev/null)

log "Strategy: diff vs HEAD=$(count_lines "$DIFF_HEAD") files, untracked=$(count_lines "$UNTRACKED") files, last commit=$(count_lines "$DIFF_LAST") files"

ALL_CHANGED=$(
  {
    printf '%s\n' "$DIFF_HEAD"
    printf '%s\n' "$UNTRACKED"
    printf '%s\n' "$DIFF_LAST"
  } | sort -u | grep -v '^[[:space:]]*$' 2>/dev/null
)
log "Combined unique: $(count_lines "$ALL_CHANGED") files"

SOURCE_FILES=""
if [ -n "$ALL_CHANGED" ]; then
  SOURCE_FILES=$(printf '%s\n' "$ALL_CHANGED" | grep -E '\.(ts|tsx|js|jsx|mjs|cjs|py|rs|go|java|rb|cpp|c|h|hpp|cs|swift|kt|scala|ex|exs|clj|zig|sh|lua|php|dart)$' 2>/dev/null)
fi

SOURCE_COUNT=$(count_lines "$SOURCE_FILES")
log "Source files matched: $SOURCE_COUNT"

if [ "$SOURCE_COUNT" -eq 0 ] || [ -z "$SOURCE_FILES" ]; then
  log "No source files changed — exiting 0"
  exit 0
fi

# ── Ensure docs/plans directory exists ───────────────────────
mkdir -p "$PROJECT_DIR/docs/plans" 2>/dev/null

# ── Truncate file list if too long ───────────────────────────
FILE_LIST=$(printf '%s\n' "$SOURCE_FILES" | head -10)
if [ "$SOURCE_COUNT" -gt 10 ]; then
  FILE_LIST="$FILE_LIST
... and $((SOURCE_COUNT - 10)) more files"
fi

log "Found $SOURCE_COUNT source files changed — blocking stop with instructions"

# ── Set turn lock BEFORE emitting decision ───────────────────
# Any subsequent Stop fire within this turn will see the lock and skip.
# The lock is cleared when the user submits their next prompt.
touch "$TURN_LOCK" 2>/dev/null
log "Turn lock created: $TURN_LOCK"

# ── Escape for JSON ──────────────────────────────────────────
FILE_LIST_JSON=$(printf '%s' "$FILE_LIST" | sed ':a;N;$!ba;s/\n/\\n/g')

# ── Block the stop and instruct Claude to run the agents ────
cat <<EOF
{"decision": "block", "reason": "Source files were modified ($SOURCE_COUNT files). You MUST now run these two subagents in parallel before stopping:\n\n1. Run the **doc-maintainer** agent to create or update architecture docs, API docs, CLAUDE.md, README.md, and any other affected documentation.\n\n2. Run the **qa-expert** agent to review test coverage, write missing tests, update existing tests, run the test suite, and check eval coverage.\n\nBoth agents MUST run — do not skip either. Changed files:\n$FILE_LIST_JSON"}
EOF

log "Exit 0 with decision:block — agents will be triggered"
exit 0
