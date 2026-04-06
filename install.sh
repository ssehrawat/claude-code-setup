#!/bin/bash
# install.sh — Install Claude Code global config
#
# What this installs to ~/.claude/:
#   CLAUDE.md                         — Global conventions & code quality rules
#   settings.json                     — Stop hook wiring
#   commands/plan.md                  — /plan slash command
#   commands/review-plan.md           — /review-plan slash command
#   commands/implement.md             — /implement slash command
#   commands/autopilot.md             — /autopilot slash command
#   commands/autopilot-from.md        — /autopilot-from slash command
#   agents/planner.md                 — Implementation planning expert
#   agents/engineer.md                — Implementation coding expert
#   agents/qa-expert.md               — QA & testing expert
#   agents/doc-maintainer.md          — Technical documentation expert
#   hooks/update-docs.sh              — Change detection hook (fingerprint-based dedup)
#
# Usage:
#   chmod +x install.sh && ./install.sh
#
# Safe to re-run. Backs up existing settings.json before overwriting.

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/.claude"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Claude Code — Auto Plan & Doc Maintenance Installer    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Check dependencies ────────────────────────────────────────
MISSING=""
command -v git >/dev/null 2>&1 || MISSING="$MISSING git"

if [ -n "$MISSING" ]; then
  echo "  ⚠️  Missing required dependencies:$MISSING"
  echo "  Install them first:"
  echo "    macOS:  brew install$MISSING"
  echo "    Ubuntu: sudo apt install$MISSING"
  echo ""
  read -p "  Continue anyway? (y/N) " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "  Aborted."
    exit 1
  fi
fi

# ── Create directories ────────────────────────────────────────
mkdir -p "$CLAUDE_DIR/commands"
mkdir -p "$CLAUDE_DIR/agents"
mkdir -p "$CLAUDE_DIR/hooks"

# ── Backup existing settings.json ─────────────────────────────
if [ -f "$CLAUDE_DIR/settings.json" ]; then
  BACKUP="$CLAUDE_DIR/settings.json.backup.$(date +%Y%m%d_%H%M%S)"
  cp "$CLAUDE_DIR/settings.json" "$BACKUP"
  echo "  📦 Backed up existing settings.json"
  echo "     → $BACKUP"
  echo ""
  echo "  ⚠️  This will OVERWRITE ~/.claude/settings.json"
  echo "  If you have existing hooks, merge manually from the backup."
  echo ""
  read -p "  Continue? (y/N) " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "  Aborted. Your backup is at: $BACKUP"
    exit 1
  fi
fi

# ── Copy files ────────────────────────────────────────────────
echo "  Installing files..."
echo ""

cp "$SOURCE_DIR/CLAUDE.md"                  "$CLAUDE_DIR/CLAUDE.md"
echo "  ✅ ~/.claude/CLAUDE.md"

cp "$SOURCE_DIR/settings.json"              "$CLAUDE_DIR/settings.json"
echo "  ✅ ~/.claude/settings.json"

cp "$SOURCE_DIR/commands/plan.md"           "$CLAUDE_DIR/commands/plan.md"
echo "  ✅ ~/.claude/commands/plan.md"

cp "$SOURCE_DIR/commands/review-plan.md"    "$CLAUDE_DIR/commands/review-plan.md"
echo "  ✅ ~/.claude/commands/review-plan.md"

cp "$SOURCE_DIR/commands/implement.md"     "$CLAUDE_DIR/commands/implement.md"
echo "  ✅ ~/.claude/commands/implement.md"

cp "$SOURCE_DIR/commands/autopilot.md"    "$CLAUDE_DIR/commands/autopilot.md"
echo "  ✅ ~/.claude/commands/autopilot.md"

cp "$SOURCE_DIR/commands/autopilot-from.md" "$CLAUDE_DIR/commands/autopilot-from.md"
echo "  ✅ ~/.claude/commands/autopilot-from.md"

cp "$SOURCE_DIR/agents/planner.md"          "$CLAUDE_DIR/agents/planner.md"
echo "  ✅ ~/.claude/agents/planner.md"

cp "$SOURCE_DIR/agents/engineer.md"        "$CLAUDE_DIR/agents/engineer.md"
echo "  ✅ ~/.claude/agents/engineer.md"

# Clean up old coder.md if it exists (renamed to engineer.md)
if [ -f "$CLAUDE_DIR/agents/coder.md" ]; then
  rm "$CLAUDE_DIR/agents/coder.md"
  echo "  🧹 Removed old ~/.claude/agents/coder.md (renamed to engineer.md)"
fi

cp "$SOURCE_DIR/agents/qa-expert.md"        "$CLAUDE_DIR/agents/qa-expert.md"
echo "  ✅ ~/.claude/agents/qa-expert.md"

cp "$SOURCE_DIR/agents/doc-maintainer.md"   "$CLAUDE_DIR/agents/doc-maintainer.md"
echo "  ✅ ~/.claude/agents/doc-maintainer.md"

cp "$SOURCE_DIR/hooks/update-docs.sh"       "$CLAUDE_DIR/hooks/update-docs.sh"
chmod +x "$CLAUDE_DIR/hooks/update-docs.sh"
echo "  ✅ ~/.claude/hooks/update-docs.sh"

# Clean up clear-turn-lock.sh from previous versions (replaced by fingerprint dedup)
if [ -f "$CLAUDE_DIR/hooks/clear-turn-lock.sh" ]; then
  rm "$CLAUDE_DIR/hooks/clear-turn-lock.sh"
  echo "  🧹 Removed old ~/.claude/hooks/clear-turn-lock.sh (turn-lock dedup replaced by fingerprint)"
fi

# Clean up stale turn locks from previous versions
if [ -d "$CLAUDE_DIR/hooks/.turn-locks" ]; then
  rm -rf "$CLAUDE_DIR/hooks/.turn-locks"
  echo "  🧹 Removed old ~/.claude/hooks/.turn-locks/ (turn-lock dedup replaced by fingerprint)"
fi

# Clean up stale state from previous timer-based versions
if [ -d "$CLAUDE_DIR/hooks/.session-state" ]; then
  rm -rf "$CLAUDE_DIR/hooks/.session-state"
  echo "  🧹 Removed old ~/.claude/hooks/.session-state/ (timer-based dedup replaced by fingerprint)"
fi

# ── Done ──────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Installation complete! Here's what you can do now:"
echo ""
echo "  ── OPTION 1: Manual (step by step) ──────────────────"
echo ""
echo "     /plan <description>          Create an implementation plan"
echo "     /review-plan latest          Review the most recent plan"
echo "     /implement <description>     Implement via the engineer agent"
echo "     (tests & docs auto-run after implementation via Stop hook)"
echo ""
echo "  ── OPTION 2: Autopilot (fully automated) ───────────"
echo ""
echo "     /autopilot <description>     Full chain: Plan → Implement → Test → Docs"
echo "     /autopilot-from <stage> ...  Resume from any stage:"
echo "       /autopilot-from plan ...         Start from planning (same as /autopilot)"
echo "       /autopilot-from implement PLAN-003  Skip planning, use existing plan"
echo "       /autopilot-from test PLAN-003       Skip planning + coding"
echo "       /autopilot-from docs                Only update documentation"
echo ""
echo "  🤖 AGENTS"
echo "     planner                      Principal architect"
echo "     engineer                        Distinguished principal engineer"
echo "     qa-expert                    Principal QA engineer"
echo "     doc-maintainer               Staff technical writer"
echo ""
echo "  📁 Plans saved to: <project>/docs/plans/PLAN-NNN-slug.md"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
