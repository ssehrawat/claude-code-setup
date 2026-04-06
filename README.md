# Claude Code — Auto Plan & Doc Maintenance Setup

Global Claude Code configuration with expert AI agents that handle planning, implementation, testing, and documentation. Two modes of operation — manual (you drive each step) or autopilot (hands-free).

## Quick Install

```bash
# Git Bash on Windows, or any Unix terminal
cd ~/Downloads
tar -xzf claude-code-setup.tar.gz
cd claude-code-setup
chmod +x install.sh
./install.sh
```

Installs to `~/.claude/` → applies globally to all projects.

**Requirements:** `git` must be installed.

**Re-running:** Safe to run again on updates. Backs up existing `settings.json` and auto-cleans renamed files from previous versions.

## Usage

### Option 1: Manual (Step by Step)

You control the pace. Review between steps. Best for complex features and initial project design.

```
/plan add user authentication
```
Planner reads the codebase, asks you questions with recommendations (1-3 rounds), then writes a detailed plan.

```
/review-plan PLAN-001
```
Review the plan. Approve, request changes, or reject. **Never auto-starts implementation.**

After approval, Claude tells you:
> Plan approved. To implement, run: `/implement PLAN-001` or `/autopilot-from implement PLAN-001`

```
/implement PLAN-001
```
Engineer agent implements following the plan. After completion, Stop hook auto-triggers qa-expert + doc-maintainer.

### Option 2: Autopilot (Fully Automated)

One command, no stops. Best for well-understood features, bug fixes, and refactors.

**Full pipeline:**
```
/autopilot add rate limiting to the API endpoints
```

Runs the entire chain hands-free:
```
Step 1:   planner    → writes plan (auto-approved + self-review)
Step 1.5: validation → main agent sanity-checks the plan
Step 2:   engineer   → implements everything from the plan
Step 3:   qa-expert  → writes tests, runs them, fixes failures
Step 4:   doc-maint  → creates/updates all documentation
Step 5:   summary    → reports what was done
```

**Resume from any stage:**
```
/autopilot-from plan add rate limiting        ← same as /autopilot
/autopilot-from implement PLAN-003            ← you reviewed the plan, now run the rest
/autopilot-from test PLAN-003                 ← code is done, just test + docs
/autopilot-from docs                          ← just update documentation
```

**Recommended workflow for important features:**
```
/plan add user authentication                  ← interactive Q&A, you shape the plan
/review-plan PLAN-001                          ← approve
/autopilot-from implement PLAN-001             ← rest runs hands-free
```

### Smart /implement (Complexity Detection)

`/implement` without a plan reference auto-detects task complexity:

**Small tasks** (≤4 files, no new patterns, no API changes):
Creates a lightweight plan for traceability and implements immediately.

**Large tasks** (5+ files, new modules, API/schema changes):
Stops and recommends running `/plan` first. Shows you the scope and why it needs a plan. You can override with "proceed anyway" if you're sure.

**With a plan reference:**
```
/implement PLAN-001       ← always follows the plan directly
```

### All Commands

| Command | What It Does |
|---------|-------------|
| `/plan <description>` | Interactive Q&A → detailed plan in `./docs/plans/` |
| `/review-plan <id\|latest\|all>` | Review and approve plans (never implements) |
| `/implement <description or PLAN-ID>` | Smart implement with complexity detection |
| `/autopilot <description>` | Full chain: plan → implement → test → docs |
| `/autopilot-from <stage> <args>` | Resume from: `plan`, `implement`, `test`, or `docs` |

## Expert Agents

All agents inherit the model from your current session (Opus, Sonnet, etc.). No model is hardcoded.

| Agent | Persona | When It Runs |
|-------|---------|-------------|
| **planner** | Principal architect (Google/Stripe-level). In manual mode, asks focused questions with recommendations. In auto mode, makes autonomous decisions with self-review. | `/plan`, or Step 1 of `/autopilot` |
| **engineer** | Distinguished principal engineer (Cloudflare/Stripe/SQLite-level). Production-grade code. Zero AI slop. Every file has module docstrings, WHY comments, and intent-focused function docs. | `/implement`, or Step 2 of `/autopilot` |
| **qa-expert** | Principal QA engineer (Netflix/NASA-level). Thinks like an attacker. Tests edge cases, boundaries, error paths, concurrency — not just happy paths. | Auto via Stop hook, or Step 3 of `/autopilot` |
| **doc-maintainer** | Staff technical writer (Stripe/Vercel-level). Every sentence earns its place. Creates and maintains all project documentation. | Auto via Stop hook, or Step 4 of `/autopilot` |

## Code Quality Standards

Enforced in the global `CLAUDE.md` and the engineer agent:

- Production-grade code — every file deployable as-is
- No TODO/FIXME/HACK comments — if it needs doing, do it now
- No `any` types, no empty catches, no magic numbers, no lazy names
- 40-line function limit, 3-level nesting max
- Guard clauses before success paths
- Module docstring at the top of every file
- `// WHY:` comments on non-obvious decisions
- Intent-focused docstrings on all public functions/classes

## Documentation Auto-Created

The doc-maintainer creates and maintains these automatically:

**Always created if missing:**
- `CLAUDE.md` — project overview, commands, structure, conventions
- `README.md` — description, setup, usage, API surface
- `docs/architecture.md` — component overview, data flow, entry points
- `docs/api.md` — endpoints, methods, request/response shapes (if project has endpoints)

**Created if applicable:**
- `docs/workflows.md` — dev, test, build, deploy workflows
- `docs/frontend.md` — component structure, state, routing, styling
- `docs/backend.md` — service architecture, middleware, DB patterns
- `.env.example` — environment variables with descriptions

**Never auto-created:**
- `CONTRIBUTING.md`, `CHANGELOG.md`, `LICENSE` (governance decisions)

## Plan Management

All plans saved to `./docs/plans/` in the project directory (never `~/.claude/`).

**Full plans** (via `/plan` or `/autopilot`):
```
docs/plans/PLAN-001-url-shortener-api.md
```
Contains: context, goals, alternatives, technical design, implementation steps, risks, rollback strategy, testing strategy, success criteria.

**Lightweight plans** (auto-created by `/implement` for small tasks):
```
docs/plans/PLAN-003-delete-endpoint.md
```
Contains: task summary, approach, affected components. Quick paper trail without the overhead.

## How the Stop Hook Works

A single Stop hook (`update-docs.sh`) fires after every task. It detects source file changes via git and triggers `qa-expert` + `doc-maintainer` automatically — using **fingerprint-based dedup** to avoid redundant runs.

### Fingerprint dedup

Claude Code can fire the Stop event multiple times within a single turn (once per subagent return, once per follow-up reply, etc.). To prevent redundant agent runs, the hook computes a **fingerprint** — a hash of the sorted list of uncommitted + untracked source files. If the fingerprint matches the last-processed one, the hook skips.

No companion hook needed. No timers. No turn locks. The fingerprint is purely state-based: same files = same hash = skip.

Fingerprints are keyed by Claude Code's `session_id` so different terminals don't interfere.

### The flow

```
Claude processes your request, makes changes, finishes
  ↓
Stop hook fires → update-docs.sh runs
  ↓
stop_hook_active flag set? (Claude Code's own loop guard)
  YES → exit 0
  ↓
Autopilot sentinel (.claude/.autopilot-active) present?
  Stale (>2h)? → delete sentinel + warn, continue
  Fresh?       → save fingerprint + exit 0 (autopilot handles agents itself)
  ↓
Source files changed? (git diff HEAD + untracked)
  NO  → exit 0
  ↓
Compute fingerprint (hash of sorted source file list)
  ↓
Fingerprint matches last-processed?
  YES → exit 0 (already handled)
  ↓
Save fingerprint → return decision:block with agent instructions
  ↓
Claude reads the block reason and spawns in parallel:
  ├── qa-expert       → writes/updates tests, runs suite
  └── doc-maintainer  → updates all documentation
  ↓
Agents return → Stop fires → same fingerprint → skip ✓
  ↓
User commits → Stop fires → no uncommitted files → skip ✓
  ↓
User writes more code → Stop fires → new fingerprint → trigger ✓
```

### Three safety nets prevent loops

1. **Claude Code's built-in `stop_hook_active` flag** — if the hook already caused Claude to continue once, this flag is true on the next fire and the hook exits immediately
2. **Fingerprint file** — hash of the processed file list, keyed by session; same files = same hash = skip
3. **Autopilot sentinel** (`.claude/.autopilot-active`) — short-circuits the hook during `/autopilot` runs (saves the fingerprint so post-autopilot fires also skip). Stale sentinels older than 2 hours are auto-cleaned.

### Debug log

Every hook invocation is logged to `~/.claude/hooks/update-docs.log` with `[stop]` tags. If agents aren't running when you expect them to, check this file first — it shows every decision the hook made and why.

### "Stop hook error" messages

Claude Code's UI sometimes displays "Stop hook error" even when the hook is working correctly. This is a cosmetic issue with how `decision:block` responses are rendered — as long as the agents actually spawn after the message, the hook is working. The debug log is the source of truth.

### Files to gitignore

Add to your project's `.gitignore`:
```
.claude/.autopilot-active
```

## Files Installed

```
~/.claude/
├── CLAUDE.md                      ← code quality + doc standard rules
├── settings.json                  ← Stop hook registration
├── commands/
│   ├── plan.md                    ← /plan (interactive Q&A)
│   ├── review-plan.md             ← /review-plan (review only, never implements)
│   ├── implement.md               ← /implement (smart complexity detection)
│   ├── autopilot.md               ← /autopilot (full chain)
│   └── autopilot-from.md          ← /autopilot-from (resume from any stage)
├── agents/
│   ├── planner.md                 ← planning expert
│   ├── engineer.md                ← coding expert
│   ├── qa-expert.md               ← testing expert
│   └── doc-maintainer.md          ← documentation expert
└── hooks/
    └── update-docs.sh             ← Stop hook: detect changes + trigger agents
```

## Merging With Existing Settings

The installer backs up your existing `settings.json`. If you have existing hooks, merge the `Stop` entry manually:

```json
{
  "hooks": {
    "YourExistingHook": [ "..." ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/update-docs.sh",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

Only one hook is needed — the Stop hook handles everything with fingerprint-based dedup.

## Per-Project Overrides

Project-level settings in `<project>/.claude/settings.json`:
```json
{
  "plansDirectory": "docs/plans"
}
```

Project-level `CLAUDE.md` in the repo root is merged with the global one automatically. Use it for project-specific context (test framework, directory structure, tech stack).

## Tips

- Press `Shift+Tab` to cycle to `auto` mode before running `/autopilot` to skip permission prompts
- Use `/plan` for complex/initial features, `/implement` for small additions
- `/autopilot-from implement PLAN-X` is the sweet spot — plan manually, execute automatically
- All agents run as subagents to preserve your main context window
