---
id: PLAN-003
date: 2026-05-02
status: implemented
type: feature
mode: lightweight
summary: Bake the "skip qa-expert when change set is markdown-only" rule into the agent + autopilot commands so it propagates via install.sh, replacing the per-machine memory.
---

## Task

Move the "skip qa-expert on markdown-only changes" rule from per-machine memory into the durable Claude Code setup files. The orchestrator commands pre-check the change set before invoking qa-expert; the agent itself also self-guards as a safety net. Once mirrored to `~/.claude/` and re-installed via `install.sh`, the behavior applies on any machine.

## Approach

Three file edits, plus a memory cleanup:

1. **`.claude/agents/qa-expert.md`** — insert a "Scope guard" instruction near the top (before the persona's testing methodology). The agent runs the markdown-only check first; if every changed file ends in `.md`, it emits a one-line skip note and exits cleanly. Otherwise it proceeds with its normal job.

2. **`.claude/commands/autopilot.md` Step 3 (Test)** — add a pre-check that runs the same bash idiom before delegating to qa-expert. If markdown-only, skip Step 3 entirely, proceed directly to Step 4 (Document), and record `Tests: skipped (markdown-only)` in the Step 5 summary template.

3. **`.claude/commands/autopilot-from.md` Step 3 (Test)** — same pre-check as autopilot.md.

Use this exact POSIX bash idiom in all three files for consistency:

```bash
non_md=$(git diff --name-only HEAD; git ls-files --others --exclude-standard)
if printf '%s\n' "$non_md" | grep -v '\.md$' | grep -q .; then
  echo "MD_ONLY=0"   # has non-markdown changes — run qa-expert
else
  echo "MD_ONLY=1"   # markdown-only — skip
fi
```

Mirror all three updated files to `C:\Users\saura\.claude\`.

After the rule is in the durable files, delete the now-redundant per-machine memory: `C:\Users\saura\.claude\projects\C--Users-saura-OneDrive-Documents-cursor-projects-claude-code-setup\memory\feedback_qa_markdown_only.md` and its entry in `MEMORY.md`.

## Affected Components

- `.claude/agents/qa-expert.md` — Scope guard section added
- `.claude/commands/autopilot.md` — Step 3 pre-check, Step 5 summary line
- `.claude/commands/autopilot-from.md` — Step 3 pre-check
- `~/.claude/agents/qa-expert.md`, `~/.claude/commands/autopilot.md`, `~/.claude/commands/autopilot-from.md` — mirrors
- `~/.claude/projects/.../memory/feedback_qa_markdown_only.md` — deleted
- `~/.claude/projects/.../memory/MEMORY.md` — entry removed
