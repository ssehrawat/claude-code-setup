#!/bin/bash
# clear-turn-lock.sh — UserPromptSubmit hook that clears the turn lock
# so the Stop hook can fire fresh for the new user turn.
#
# Install location: ~/.claude/hooks/clear-turn-lock.sh
# Referenced from:  ~/.claude/settings.json (UserPromptSubmit event)
#
# This is the companion to update-docs.sh (the Stop hook). Together
# they implement turn-scoped dedup: the Stop hook creates a lock after
# triggering the maintenance agents, and this hook clears it when a
# new user prompt arrives.
#
# No timers. No TTLs. Pure event-driven.

TURN_LOCK_DIR="$HOME/.claude/hooks/.turn-locks"
LOG_FILE="$HOME/.claude/hooks/update-docs.log"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [prompt] $*" >> "$LOG_FILE" 2>/dev/null
}

log "─── UserPromptSubmit hook fired ───"

INPUT=$(cat)

SESSION_ID=$(printf '%s' "$INPUT" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' 2>/dev/null)
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="no-session-id"
fi

TURN_LOCK="$TURN_LOCK_DIR/$SESSION_ID.lock"

# ── Autopilot guard ──────────────────────────────────────────
# During autopilot, UserPromptSubmit fires for internal subagent
# invocations, not real user messages. Clearing the lock here would
# break the Stop hook's turn-scoped dedup.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null)
fi
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(pwd)"
fi

if [ -f "$PROJECT_DIR/.claude/.autopilot-active" ]; then
  log "Autopilot active — skipping lock clear (session=$SESSION_ID)"
  exit 0
fi

if [ -f "$TURN_LOCK" ]; then
  rm -f "$TURN_LOCK" 2>/dev/null
  log "Cleared turn lock: $TURN_LOCK (session=$SESSION_ID)"
else
  log "No turn lock to clear (session=$SESSION_ID)"
fi

exit 0
