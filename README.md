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

**Remote Control auto-start:** The installer patches `~/.claude/settings.json` to set `remoteControlAtStartup: true` after copying. This auto-starts the Remote Control bridge (which powers claude.ai/code and `claude remote-control`) at every Claude Code session, so you never have to toggle it per-session.

## Usage

### Option 1: Manual (Step by Step)

You control the pace. Review between steps. Best for complex features and initial project design.

```
/build-plan add user authentication
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
/build-plan add user authentication            ← interactive Q&A, you shape the plan
/review-plan PLAN-001                          ← approve
/autopilot-from implement PLAN-001             ← rest runs hands-free
```

### Smart /implement (Complexity Detection)

`/implement` without a plan reference auto-detects task complexity:

**Small tasks** (≤4 files, no new patterns, no API changes):
Creates a lightweight plan for traceability, automatically creates a feature branch from the plan's id and type, then implements immediately.

**Large tasks** (5+ files, new modules, API/schema changes):
Stops and recommends running `/build-plan` first. Shows you the scope and why it needs a plan. You can override with "proceed anyway" if you're sure.

**With a plan reference:**
```
/implement PLAN-001       ← always follows the plan directly; creates feature branch first
```

In all cases, `/implement` creates a feature branch (`<prefix>/PLAN-NNN-<slug>`) from `main`/`master` before the engineer runs. See "Git Branching" below for the full rules.

### Project Bootstrapping

When you run `/build-plan` or `/autopilot` from an empty or non-project directory, the command detects the cold-start state and creates a project for you before anything else runs.

**Detection signal (all must be true):**
- No recognized manifest in cwd (`package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`)
- No `.git/` directory
- Fewer than 3 non-hidden top-level entries

**Behavior on trigger:**
- `/build-plan` asks: "What would you like to call this project? I'll create `./<name>/` and treat it as the project root." Type a name; it gets sanitized (lowercased, non-`[a-z0-9-]` stripped, hyphen runs collapsed, leading/trailing hyphens trimmed).
- `/autopilot` and `/autopilot-from plan` derive the name automatically from the first 4 words of your task description (no Q&A). Empty input falls back to `new-project`.

The command then runs `mkdir <name> && cd <name>`, `git init` on `main`, writes a stack-agnostic `.gitignore`, and creates an initial commit. From there the rest of the pipeline operates inside the new directory — plans land in `./<name>/docs/plans/`, the engineer scaffolds files inside `./<name>/`.

**Skip conditions:** Bootstrapping does NOT run for `/implement`, `/review-plan`, `/autopilot-from implement`, `/autopilot-from test`, or `/autopilot-from docs`. Those flows assume the project already exists.

**Pre-flight requirement:** Bootstrap requires `git config --global user.email` and `user.name` to be set. If either is missing the bootstrap aborts with a clear error before creating the initial commit.

**Recovery if you don't want the new directory:** `cd ..; rm -rf <name>`. The new directory contains only the `.gitignore` and an initial commit — nothing else has been written yet.

### Git Branching

Before the engineer agent writes any files, the pipeline creates a feature branch so changes never land directly on `main`/`master`. This applies to `/implement`, `/autopilot` Step 2, `/autopilot-from implement`, and `/autopilot-from plan` (after planning).

**Branch naming:** `<prefix>/<plan-id>-<slug>` derived from the plan's frontmatter:

| Plan `type:` | Branch prefix | Example |
|---|---|---|
| `feature` | `feature/` | `feature/PLAN-001-add-auth` |
| `design` | `feature/` | `feature/PLAN-001-system-redesign` |
| `bugfix` | `fix/` | `fix/PLAN-001-fix-cors` |
| `refactoring` | `refactor/` | `refactor/PLAN-001-extract-router` |
| (anything else) | `feature/` | falls through to `feature/` |

**Behavior by mode:**

- **Manual mode (`/implement`)** — The derived name is shown as a *suggestion*; the user can press Enter to accept or type any alternative (e.g. `fix/auth-bug`, `feature/team/auth`). Custom names are sanitized (lowercased, spaces/underscores → hyphens, non-`[a-z0-9/-]` stripped, runs of `-` collapsed) and validated with `git check-ref-format --branch`. On invalid input the user is re-prompted up to 3 times, then the pipeline bails. `/` is preserved so branch prefixes work.
- **Autopilot mode (`/autopilot`, `/autopilot-from implement`, `/autopilot-from plan`)** — Auto-derives the name silently from the plan frontmatter and creates the branch with no prompt. Hands-free is non-negotiable for these flows.

**Skip conditions (in priority order, identical for both modes):**
1. Not in a git repo → skip silently.
2. Current branch is anything other than `main` or `master` → skip silently. The user already chose their branch.
3. Current branch is `main`/`master` and the target branch already exists → STOP the pipeline with an error that names the branch and gives recovery options. In manual mode the user is re-prompted (counted toward the same 3-attempt budget); in autopilot the run aborts and the `.claude/.autopilot-active` sentinel is removed so the next run isn't blocked.

**Commands that never branch:** `/build-plan`, `/review-plan`, `/autopilot-from test`, `/autopilot-from docs`.

**Recovery if engineer fails on a freshly-created branch:**
- Branch is empty (no commits) and you want to throw it out: `git checkout main && git branch -D <branch>`.
- Branch has uncommitted engineer changes you want to keep: stay on the branch and `git add -A && git commit -m "..."`.
- Branch has uncommitted engineer changes you want to discard: `git checkout -- . && git clean -fd && git checkout main && git branch -D <branch>`.

### All Commands

| Command | What It Does |
|---------|-------------|
| `/build-plan <description>` | Interactive Q&A → detailed plan in `./docs/plans/` |
| `/review-plan <id\|latest\|all>` | Review and approve plans (never implements) |
| `/implement <description or PLAN-ID>` | Smart implement with complexity detection |
| `/autopilot <description>` | Full chain: plan → implement → test → docs |
| `/autopilot-from <stage> <args>` | Resume from: `plan`, `implement`, `test`, or `docs` |

## Expert Agents

All agents inherit the model from your current session (Opus, Sonnet, etc.). No model is hardcoded.

| Agent | Persona | When It Runs |
|-------|---------|-------------|
| **planner** | Principal architect (Google/Stripe-level). In manual mode, asks focused questions with recommendations. In auto mode, makes autonomous decisions with self-review. | `/build-plan`, or Step 1 of `/autopilot` |
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

**Full plans** (via `/build-plan` or `/autopilot`):
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
├── settings.json                  ← Stop hook registration + remoteControlAtStartup: true (patched at install)
├── commands/
│   ├── build-plan.md              ← /build-plan (interactive Q&A)
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
- Use `/build-plan` for complex/initial features, `/implement` for small additions
- `/autopilot-from implement PLAN-X` is the sweet spot — plan manually, execute automatically
- All agents run as subagents to preserve your main context window
