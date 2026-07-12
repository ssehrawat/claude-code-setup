---
id: PLAN-004
date: 2026-07-12
status: in-progress
type: feature
mode: auto
summary: Close the agentic SDLC outer loop (review → deliver → CI-heal → verify → secure → deploy → monitor) across three independently shippable phases.
---

> **Progress:** Phase 1 (P1-1 … P1-8) implemented on 2026-07-12; Phases 2–3 pending.

## Context & Motivation

`claude-code-setup` implements an inner-loop agentic SDLC: `plan → implement → test → docs`. It is delivered as markdown-driven slash commands in `.claude/commands/` and subagents in `.claude/agents/`, wired together by `.claude/hooks/update-docs.sh` (a Stop hook) and installed to `~/.claude/` by `install.sh`.

The current pipeline **terminates at "code written on a local feature branch."** Concretely:

- `/autopilot` (`.claude/commands/autopilot.md`) runs Step 0 (bootstrap) → Step 1 (planner) → Step 1.5 (validation) → Step 1.75 (branch) → Step 2 (engineer) → Step 3 (qa-expert) → Step 4 (doc-maintainer) → Step 5 (summary + sentinel cleanup). It never commits, never opens a PR, never verifies the app actually runs, never checks security, and never deploys.
- The engineer agent (`.claude/agents/engineer.md`, lines 199–201) is explicitly forbidden from committing or pushing: *"Do not auto-commit or auto-push your work; the user commits when ready."*
- There is **no code review gate**. The engineer writes code; qa-expert writes tests; doc-maintainer writes docs. Nobody adversarially critiques the diff against `.claude/CLAUDE.md` standards before it becomes a candidate for merge.
- `/implement` (`.claude/commands/implement.md`) has **no Phase 0 bootstrap** (unlike `build-plan.md` Phase 0 and `autopilot.md` Step 0). Running `/implement` in an empty directory implements in place, with no repo and no branch — the Step 2.5 branch block simply reports `BRANCH_ACTION=skip-not-in-repo` and the engineer writes loose files.
- All four agents inherit the session model. There is no per-agent model tiering, so a mechanical doc update burns the same tier as adversarial planning.
- There is no telemetry: cycle time, gate outcomes, and retry counts are invisible.

A *truly* agentic SDLC closes the outer loop. This plan designs that loop as three sequenced, independently valuable phases, ordered highest-ROI-first. Each phase ships on its own and leaves the system in a working state.

### Recurring tension to resolve up front

Two house rules collide in the outer loop and this plan resolves the collision explicitly (see Assumptions & Decisions D1):

1. Autopilot's contract (`autopilot.md` line 3): *"Do NOT stop between steps. Do NOT ask for confirmation. Complete the entire chain autonomously."*
2. The safety norm that **outward-facing actions** (pushing to a remote, opening a PR, deploying to an environment) should require confirmation because they are hard to reverse and visible to others.

The resolution recurs in Phase 1 (PR creation) and Phase 2 (deploy) and is stated once, canonically, in D1.

## Goals & Non-Goals

### Goals

1. **G1 — Review gate:** Add an adversarial `reviewer` agent that critiques the engineer's diff against `.claude/CLAUDE.md` standards, emits structured findings (`blocker` / `should-fix` / `nit`), and can block the pipeline on blockers. Wired into `/autopilot` after implement and before docs, and available in the manual flow.
2. **G2 — Opt-in delivery:** Add an opt-in delivery stage to autopilot that commits (Conventional Commit, no AI-attribution trailer), pushes, and opens a PR via `gh`, gated behind an explicit flag and OFF by default.
3. **G3 — `/implement` bootstrap consistency:** Make `/implement` behave predictably in a non-project cwd (refuse-and-redirect), reusing the exact detection block from `build-plan.md` Phase 0.
4. **G4 — CI scaffold + self-heal:** Provide a language-agnostic CI workflow template the engineer/doc agents can drop into generated projects, plus a bounded CI self-heal loop that reads failing logs and dispatches the engineer, with a hard retry cap.
5. **G5 — Real-run verification gate:** Add a verification stage that actually starts the app / invokes the CLI / hits the endpoint (distinct from unit tests), slotted after tests.
6. **G6 — Security + dependency gate:** Add a security-review + dependency/secret audit pass as an advisory-by-default gate before merge.
7. **G7 — Intake step:** Add a lightweight requirements/spec intake for ambiguous asks that both planner and qa-expert anchor to.
8. **G8 — Deploy/monitor sketch:** Provide a well-scoped design sketch (not full implementation) for post-merge deploy + a "read error tracker → file the next plan" feedback loop.
9. **G9 — Model tiering:** Add per-agent `model:` frontmatter overrides.
10. **G10 — Telemetry:** Record cycle time, gate pass/fail, and retry counts to a local JSONL.

### Non-Goals

- **NG1:** No new runtime dependencies beyond `git`, `gh`, and `node` (already assumed by `install.sh`). No Python, no jq, no yq.
- **NG2:** Not building a hosted service, dashboard, or database. Telemetry is append-only JSONL, nothing more.
- **NG3:** Phase 3's deploy/monitor loop is a **design sketch with clear non-goals**, not a shipped implementation. No cloud-provider-specific deploy scripts.
- **NG4:** Not changing the fingerprint dedup philosophy of the Stop hook. New gates reuse or mirror its loop-safety approach; they do not replace it.
- **NG5:** No auto-merge. Even with delivery enabled, a human merges the PR. The loop stops at "green PR awaiting merge" in Phases 1–2; Phase 3 sketches beyond-merge only.
- **NG6:** No rewrite of existing agents' personas or the four inner-loop steps. Additive changes only.

## Assumptions & Decisions

Every judgment call made without human input (auto mode). These are **decisions, not open questions.**

- **D1 — Autopilot vs. outward-facing-action safety (canonical resolution).**
  Outward-facing actions (push, PR, deploy) are **OFF by default** and **only** activated by an explicit, typed flag in the invocation. Rationale: the autopilot "never stop / never ask" contract governs the *inner loop* (plan → docs), which produces only local, fully-reversible artifacts (files on a feature branch). Pushing/opening a PR/deploying are irreversible-ish and externally visible, so instead of a *runtime prompt* (which would violate "never ask"), we require an *upfront opt-in flag*. The flag **is** the confirmation, captured before the hands-free run begins. If the flag is present, autopilot proceeds through delivery without pausing (contract honored). If absent, autopilot stops at the same place it does today (local branch) and prints the exact command to deliver manually. This reconciles both rules without a mid-run prompt. The flag is `--deliver` for Phase 1 (PR) and `--deploy` for Phase 3 (deploy). `--deploy` implies `--deliver`. **Mid-pipeline start (`/autopilot-from test|docs`):** Deliver (4.5) and CI-heal (4.6) are gated by the *flag*, not by the start stage — so a resumed run started at `test` or `docs` STILL delivers/heals if `--deliver`/`--deploy` is present (a resumed run must be able to ship). The only step skipped for a `test`/`docs` start is Review (2.5), because it must precede docs and there is nothing new to review on a resume; Deliver and CI-heal are unaffected.
- **D2 — Delivery default is OFF.** `/autopilot <task>` with no flag never touches a remote. This is the safe default per D1.
- **D3 — Reviewer runs and can block, but "block" in autopilot means "dispatch a fix, then re-review; cap the loop."** A `blocker` finding does not silently halt the hands-free run — it triggers one engineer remediation pass, then one re-review. The reviewer↔engineer loop is capped at **2 iterations** (initial review + up to 2 fix/re-review cycles). If blockers remain after the cap, autopilot proceeds to docs but records `review: blockers-remaining` in the summary and telemetry, and (if `--deliver`) opens the PR as a **draft** with the blockers listed in the body. Rationale: a hands-free pipeline must terminate; an unbounded review loop violates loop-safety (mirrors the Stop hook's philosophy). A human sees the blockers on the draft PR.
- **D4 — CI self-heal retry cap is 3.** After a push, if CI is red, the heal loop runs at most **3** fix→push→re-check iterations. Chosen because most CI failures are shallow (lint, a broken import, a flaky-but-deterministic test) and resolve in 1–2 passes; 3 gives margin without risking a runaway that burns tokens and CI minutes. On exhaustion, stop and record `ci: red-after-3-attempts`. **Gate posture inside the heal loop:** each heal fix commit re-runs the always-blocking secret scan (D6) BEFORE pushing — a secret hit aborts the loop and is never pushed. The full reviewer (D3) and real-run verify (D5) are intentionally NOT re-run per heal iteration (cost + loop-safety: re-running expensive adversarial gates inside a bounded fix loop risks a runaway), but the secret scan is, because its guarantee is unconditional and irreversible-harm-avoiding.
- **D5 — Verification is best-effort and advisory in autopilot, blocking in manual `/verify`.** Real-run verification depends on the project being startable in the sandbox (ports, env, external services). In autopilot it runs, records the outcome, and does not hard-block delivery (a green PR can still be reviewed by a human). A dedicated `/verify` manual command treats failure as blocking. Rationale: environment variance makes hard-blocking on real-run too brittle for hands-free mode.
- **D6 — Security gate is advisory by default, blocking with `--strict-security`.** Dependency/secret audits produce false positives; hard-blocking every run on a transitive advisory would make autopilot unusable. Secrets detection (committed credentials) is the one exception: a positive secret hit is **always blocking**, even in advisory mode, because pushing a secret is unrecoverable. Rationale: asymmetry of harm — a leaked secret is catastrophic and irreversible; a CVE advisory is informational.
- **D7 — Intake is a phase inside `build-plan`/`autopilot`, not a new command.** For ambiguous asks the planner produces an `## Acceptance Criteria`, `## Out of Scope`, and `## Success Metrics` block inside the plan frontmatter/body, which qa-expert and reviewer anchor to. Rationale: a separate `/intake` command adds a step users will skip; folding it into the plan guarantees it is always produced and versioned with the plan. A heuristic decides when the ask is "ambiguous enough" to warrant explicit intake (see Phase 3 design).
- **D8 — Model IDs.** Available tiers: Opus 4.8 = `claude-opus-4-8`, Sonnet 4.6 = `claude-sonnet-4-6`, Haiku 4.5 = `claude-haiku-4-5-20251001`, Fable 5 = `claude-fable-5`. Assignments (D9) use these exact IDs.
- **D9 — Model assignments.** planner → `claude-opus-4-8` (deep reasoning, architecture). reviewer → `claude-opus-4-8` (adversarial critique needs top tier). engineer → `claude-sonnet-4-6` (strong coding at lower cost; session can override to Opus for hard tasks). qa-expert → `claude-sonnet-4-6`. doc-maintainer → `claude-haiku-4-5-20251001` (mechanical, high-volume, cost-sensitive). WHY not Fable 5 anywhere: Fable 5 is a creative-writing–oriented tier; SDLC agents need code/reasoning strength, so it is documented as available but unassigned.
- **D10 — Telemetry location.** Append to `~/.claude/telemetry/sdlc.jsonl` (global, survives across projects) with a `project` field derived from `git rev-parse --show-toplevel` basename. WHY global not per-project: keeps generated project trees clean (NG2/NG6) and lets a user see cross-project cycle-time trends. Privacy: record only structural facts (timestamps, stage names, pass/fail, counts, plan IDs, project basename) — never diffs, code, or task descriptions.
- **D11 — `/implement` in non-project cwd → refuse-and-redirect (not bootstrap).** WHY: `/implement` presupposes a plan to implement. A truly empty dir has no plan and no project. Bootstrapping silently would produce a repo whose first commit is engineer output with no plan and no branch policy — inconsistent with every other entry point. Refusing and pointing the user to `/build-plan` or `/autopilot` is the consistent, least-surprising behavior.
- **D12 — CI template stacks.** Ship one generic `ci.yml` plus two stack-specific overlays (Node and Python) since those dominate the generated-project population. The engineer picks the overlay matching the detected manifest (`package.json` → node, `pyproject.toml` → python); if neither, it drops the generic lint+build placeholder with a documented TODO for the human to fill runtime commands. This TODO lives in the generated project's CI file (a scaffold placeholder for the end user), NOT in this repo's source — it does not violate the no-placeholder code rule, which governs implementation code in this repo.

- **D13 — Stale-docs gate is a CI-time verification check, not a doc author.** The gate never writes documentation; doc authoring stays where it is today (pre-PR, autopilot Step 4, via `doc-maintainer`). The gate is an *enforcement net* that fails a PR/CI run when source changed but no doc surface changed, catching cases where `doc-maintainer` was skipped or missed a surface. It is implemented as a standalone POSIX script `.claude/templates/ci/check-docs-fresh.sh` invoked by a job/step in all three Phase 2 CI templates (`ci.generic.yml`, `ci.node.yml`, `ci.python.yml`). WHY a shared script rather than inlined YAML in each template: one source of truth, locally testable, no triplicated logic to drift.
- **D14 — Detection heuristic: source-changed-AND-no-doc-changed → fail.** Compute changed files as `git diff --name-only <merge-base> HEAD` against the base branch. If any changed file matches the source-extension set AND none matches the doc-surface set, fail. The source-extension set **mirrors the Stop hook (`update-docs.sh`)** so the gate enforces exactly the change class that would have triggered `doc-maintainer` locally (single-sourced semantics). The doc surfaces are `README.md`, `CLAUDE.md`, `docs/**`, `.env.example` (mirroring the CLAUDE.md Documentation Maintenance list). Kept deliberately simple and low-false-positive: a pure file-list function, no content analysis. Requires `fetch-depth: 0` on the CI checkout for the merge base; falls back to the base ref directly if `git merge-base` is unavailable.
- **D15 — Escape hatch is a commit-message / PR-body token `[skip-docs]`, not a PR label.** The gate passes if `[skip-docs]` (case-insensitive, fixed-string) appears in any commit message in the PR range or the PR body. WHY a token over a label: the standalone script runs identically across CI providers and locally, and a token is readable via plain `git log` everywhere, whereas a label requires provider-specific API calls (a GitHub-only `gh`/`GITHUB_TOKEN` round-trip) that the portable script deliberately avoids (NG1). The gate always prints how to use the token when it fails, so it never becomes a gate people learn to force-merge past blindly.
- **D16 — Stale-docs gate is BLOCKING (required check), on the doc-surface heuristic only.** Contrast with the security dependency gate (D6), which is advisory by default. Docs-freshness can afford to block where general security can't because it is (a) *deterministic* (a pure function of the diff file list, no CVE-feed/transitive-advisory noise), (b) *cheap to fix* (a one-line doc edit), and (c) *cheaply escapable* (the `[skip-docs]` token). The accepted residual is the false positive on a legitimate internal refactor that needs no docs — the `[skip-docs]` token, not advisory mode, is the release valve for that case. This is the inverse rationale to the security secret-scan block (D6): that blocks because harm is irreversible; this blocks because prevention is cheap and the escape is trivial.

- **D17 — Single source of truth for "what counts as a source-code change" (shared library).** The concept "is this changed file source code (needs test/doc attention) vs. a doc/text/config file" is today expressed in **two contradictory framings** across the repo, and the stale-docs gate (D13/D14) would have added a third copy of one of them. The two existing framings are: (a) an **allowlist** in `update-docs.sh` (`SOURCE_EXT_PATTERN`, line 46, ~26 explicit code extensions, used at lines 115/154/181) — a file is source only if it matches; and (b) a **blocklist** in `autopilot.md` (lines 223–224) and `qa-expert.md` (lines 18–19), both `grep -v '\.md$'` — a file is source if it is anything except `.md`. These already **disagree today**: a diff of only `migrations/x.sql` + `config/y.yaml` is "not source" under the allowlist (Stop hook stays silent, no qa/docs) yet "is source" under the blocklist (autopilot runs qa-expert, marks `MD_ONLY=0`). The failure mode is **silent** — nobody crashes; someone adds `.vue`/`.kt` support to one copy, forgets the others, and the safety net grows a hole. **Decision:** extract ONE POSIX shell library, `.claude/lib/classify-changes.sh`, that defines `SOURCE_EXT_PATTERN` exactly once and owns the git-diff collection + classification helpers, and rewire all consumers (Stop hook, autopilot, qa-expert) plus the new CI gate to it. This lands as the **first** Phase 2 implementation step so the stale-docs gate consumes the shared definition on day one rather than adding a fourth copy that a later refactor removes. WHY a shared lib over three synchronized copies: three copies stay in sync only by good intentions; one file makes drift impossible by construction.

- **D18 — Unify on the allowlist, not the blocklist (`is_markdown_only` = inverse of `is_source_change`).** The library resolves the D17 A-vs-B disagreement in favor of the **curated allowlist**. "Markdown-only" (the qa/autopilot skip condition) is redefined as "**the change set contains no source files**" — i.e. the logical inverse of `is_source_change` against `SOURCE_EXT_PATTERN` — **not** as `grep -v '\.md$'`. WHY the allowlist wins: it makes the `.sql` / `.yaml` / `Dockerfile` / `.tf` question have exactly **one** answer everywhere (Stop hook, autopilot skip, qa-expert skip, CI gate), instead of the blocklist's "everything non-`.md` is code" which sweeps in lockfiles, YAML, generated assets, and data fixtures as if they were code. **Behavior change to call out:** a diff consisting only of e.g. `config/app.yaml` was previously treated by autopilot/qa-expert as `MD_ONLY=0` (qa-expert would run); under the unified allowlist it becomes "no source files → skip qa-expert." This is intentional and now consistent with what the Stop hook already did for the same diff. Risks & Mitigations (Phase 2) records this as a deliberate behavior change. **Cross-reference to PLAN-003 (NOT a supersession):** the notion of "markdown-only" as a skip condition was originally introduced by PLAN-003. D18 redefines only the *implementation* of that notion — "no source files in the change set" (allowlist inverse) rather than `grep -v '\.md$'` (blocklist) — while fully preserving PLAN-003's *intent* (skip the test/doc pass when the change carries no code). Because the intent is preserved, this is a deliberate cross-reference, not a supersession: PLAN-003 keeps its status and gains no `superseded_by` field.

- **D19 — Boundary call: `.sql` is source; `.yaml`/`Dockerfile`/config are not (for now).** With the framings unified (D18), the previously-accidental question "are non-code-extension files source?" must be answered on purpose. **Decision:** keep the curated allowlist as the boundary — do NOT auto-treat every non-`.md` file as source — but **add `.sql` to `SOURCE_EXT_PATTERN`** in the shared library, because schema migrations genuinely warrant test and doc attention (a new migration changes the data contract). Leave `.yaml`/`.yml`, `Dockerfile`, `.tf`, and lockfiles **out** for now: they are high-volume, frequently machine-generated, and a config tweak rarely needs a code test or a doc-maintainer pass; treating them as source would make the Stop hook and the docs gate noisy. Revisit per-project if a project is config-heavy. This makes the boundary an intentional decision recorded here, not behavior inherited from whichever copy happened to run.

- **D20 — The CI docs-freshness gate runs against a VENDORED, repo-relative copy of the classifier, decoupled from `~/.claude/lib` (accepted CI-isolation tradeoff).** The stale-docs gate ships into *generated projects* and runs on a GitHub Actions runner that has **no Claude Code install** — `$HOME/.claude/lib/classify-changes.sh` does not exist there, so a `$HOME`-only source would hard-fail every real CI run. **Decision:** the engineer scaffold step (2.1 / P2-7) **vendors both `check-docs-fresh.sh` and `classify-changes.sh` into the generated repo under `.github/scripts/`** (a committed, in-repo location present on the runner), and `check-docs-fresh.sh` resolves its library **repo-relative to its own location** (`SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); LIB="$SCRIPT_DIR/classify-changes.sh"`), honoring a `CLASSIFY_LIB` env override and falling back to `$HOME/.claude/lib` **only** for local dev. On the runner the vendored sibling is authoritative. **Accepted tradeoff:** the vendored copy is a deliberate *snapshot* — a downstream project pins its own gate logic and does **not** track the dev machine's `~/.claude/lib` edits. **Why this does NOT reintroduce the D17 drift problem *within this repo*:** D17's single-source-of-truth guarantee is about THIS repo's consumers (Stop hook, autopilot, qa-expert, the in-repo template gate), which still resolve to exactly one file. The vendored copy lives in a *different* repo and is a shipped scaffold artifact — like the CI YAML templates or any generated `package.json`, it is a snapshot by design, not a fourth in-repo copy. **Refresh path:** re-scaffolding (or a future `--update-scaffold` pass) re-copies the current `check-docs-fresh.sh` + `classify-changes.sh` into the generated repo's `.github/scripts/`, refreshing the pinned snapshot; a generated project can also re-run the scaffold to pull the latest gate logic. The residual (a vendored copy can lag the source lib) is called out in Self-Review Notes #13.

## Alternatives Considered

- **A1 — Runtime confirmation prompt for PR/deploy (rejected).** Prompt "OK to open PR?" mid-run. Rejected: directly violates autopilot's "never ask" contract and would hang a hands-free run indefinitely if no human is watching. The upfront flag (D1) captures consent without a mid-run pause.
- **A2 — Reviewer as a Stop-hook trigger like qa-expert/doc-maintainer (rejected as the primary wiring; kept as manual fallback).** The Stop hook fires on *source-file* changes and runs qa + docs in parallel. Making reviewer a third parallel Stop-hook agent would run it *concurrently* with qa/docs, but review must gate *before* docs and *before* delivery, and must be able to loop with the engineer. Ordering matters, so reviewer is wired as an explicit autopilot step (D3) and offered manually via a `/review` command. (We still add a manual entry point via the Stop-hook-adjacent path for the non-autopilot inner loop — see Phase 1 design.)
- **A3 — Auto-merge on green (rejected, NG5).** Merging is a governance decision. The loop stops at a green (or draft) PR. A human merges.
- **A4 — Unbounded CI self-heal until green (rejected).** Violates loop-safety. Capped at 3 (D4).
- **A5 — Separate `/intake` command (rejected, D7).** Folded into planning to guarantee it runs.
- **A6 — jq/yq for JSON/YAML (rejected, NG1).** Frontmatter is already parsed with `awk` (see `autopilot.md` lines 165–166); JSON telemetry is emitted with `printf` and consumed (if ever) with `node -e`. No new dependency.
- **A7 — Per-project telemetry file (rejected, D10).** Pollutes generated repos and loses cross-project view.

## Technical Design

The design is additive. Existing step numbers are preserved; new steps are inserted with decimal numbering (mirroring how `1.5`, `1.75`, `2.5` already coexist) so downstream renumbering is avoided.

### Portability constraints (apply to every bash block in this plan)

- POSIX `sh`-compatible; must run under Git Bash on Windows, and bash on macOS/Linux.
- No GNU-only flags (`sed -I`, `grep -P` avoided; `awk` used for structured parsing, matching the existing `autopilot.md` frontmatter parser and `update-docs.sh` JSON escaper).
- No `jq`/`yq`. JSON produced with `printf`; if consumed, `node -e`.
- `gh` calls guarded by `command -v gh` and `gh auth status`; absence degrades gracefully to "delivery skipped: gh not available/authenticated," recorded in the summary — never a hard crash.

---

### Phase 1 — Close the review + delivery gap (highest ROI)

#### 1.1 `reviewer` agent (`.claude/agents/reviewer.md`)

New agent file, same house style as the other four agents. Frontmatter:

```yaml
---
name: reviewer
description: Adversarial diff reviewer. Critiques the engineer's changes against .claude/CLAUDE.md standards before docs/delivery. Emits structured findings (blocker/should-fix/nit) and can gate the pipeline.
tools: Read, Grep, Glob, Bash
model: claude-opus-4-8
---
```

WHY `tools` excludes `Write`/`Edit`: a reviewer that can edit is no longer a reviewer — it becomes a second engineer and loses adversarial independence. It reads the diff, reads `.claude/CLAUDE.md`, and emits findings; the *engineer* applies fixes. This mirrors real code review separation of duties.

Behavior:

1. Markdown-only scope guard identical in spirit to `qa-expert.md` lines 15–24 (if the change set is markdown-only, the review criteria shift to prose/command-correctness rather than code smells; it does not exit, because command/agent markdown IS the product in this repo — but it skips type-safety/error-handling checks that only apply to code).
2. Compute the diff: `git diff HEAD` for tracked changes plus `git ls-files --others --exclude-standard` for new files (same discovery pattern as the Stop hook, `update-docs.sh` lines 166–167).
3. Critique against `.claude/CLAUDE.md` (read at runtime, not hardcoded, so the standards stay single-sourced): correctness, error handling (no empty catch), no AI slop / filler comments, type safety (no `any`), no magic numbers, function length/nesting limits, security smells (injection, hardcoded secrets, unsafe eval), and — if a plan exists — adherence to the plan's `## Acceptance Criteria` (Phase 3 intake).
4. Emit a structured report:

```
## Review Report

### Verdict: {approve | changes-requested}

### Blockers (must fix before merge)
- [file:line] {finding}

### Should-fix (fix now unless justified)
- [file:line] {finding}

### Nits (optional)
- [file:line] {finding}
```

The machine-readable gate line the caller parses: reviewer prints, as its final line, exactly `REVIEW_VERDICT=approve` or `REVIEW_VERDICT=changes-requested` with `BLOCKERS=<n>`. The autopilot step greps this line.

#### 1.2 Wire reviewer into `/autopilot` and `/autopilot-from`

Insert **Step 2.5: Review** in `autopilot.md` (between Step 2 Implement and Step 3 Test) and the identical step in `autopilot-from.md` (skipped when starting stage is `test`/`docs`). Flow (implements D3):

```
Step 2.5: Review
  iteration = 0
  loop:
    delegate to reviewer subagent
    parse REVIEW_VERDICT / BLOCKERS from final line
    if verdict == approve OR BLOCKERS == 0: break
    iteration += 1
    if iteration > 2: record "review: blockers-remaining"; break
    delegate to engineer subagent with the reviewer's blocker list as the fix brief
  record review outcome for the Step 5 summary + telemetry
```

WHY the loop lives in the command (not the agent): the agents are stateless single-shot subagents; orchestration and loop-caps belong in the command layer, exactly as the branch-creation retry budget lives in `implement.md` Step 2.5d, not in the engineer.

#### 1.3 Manual review entry point: `/review` command (`.claude/commands/review.md`)

New command mirroring `review-plan.md`'s shape but for *code* not *plans*. Invokes the reviewer once against the working-tree diff and prints the report. Does not loop or auto-fix (manual mode = human decides). This gives the non-autopilot inner loop a review gate without forcing it through the Stop hook. Documented in `install.sh` and README alongside the existing commands.

#### 1.4 Opt-in delivery stage: **Step 4.5: Deliver** in `autopilot.md` / `autopilot-from.md`

Runs only when `--deliver` (or `--deploy`, which implies it) was present in `$ARGUMENTS`. Parsing: the command extracts flags from `$ARGUMENTS` before deriving the task description (strip recognized flags, then treat the remainder as the task — so `--deliver` does not pollute the auto-derived project name in Step 0). **Mid-pipeline start (D1):** in `autopilot-from`, Deliver runs whenever the flag is present regardless of the start stage — a run resumed at `test` or `docs` still delivers if `--deliver`/`--deploy` was passed. It is the flag, not the start stage, that gates delivery.

Delivery block (POSIX, `gh`-guarded):

```bash
# Preconditions
command -v gh >/dev/null 2>&1 || { echo "DELIVER=skip-no-gh"; exit 0; }
gh auth status >/dev/null 2>&1 || { echo "DELIVER=skip-no-auth"; exit 0; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "DELIVER=skip-not-in-repo"; exit 0; }

branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
  echo "DELIVER=skip-on-default-branch"; exit 0
fi

# Stage everything the pipeline produced on this branch.
git add -A
# Conventional Commit subject derived from plan type+id+slug; NO AI-attribution trailer.
# (Message body assembled by the command from the plan; this is the shell that commits it.)
# WHY test the index instead of inferring from commit's exit code: `git commit` also
# fails on an unreadable message file or a failing pre-commit hook — reporting those
# as "nothing-to-commit" would swallow a real error and leave staged work behind
# (amended during Phase 1 QA: DELIVER=commit-failed is a distinct terminal outcome).
if git diff --cached --quiet; then
  echo "DELIVER=nothing-to-commit"
  # Still push if the branch has unpushed commits from an earlier step (e.g. a resume),
  # but never on a clean, fully-pushed branch.
  ahead=$(git rev-list --count "@{upstream}..HEAD" 2>/dev/null || echo 0)
  [ "${ahead:-0}" -gt 0 ] && git push -u origin "$branch"
else
  # WHY guard the push: only push when this run actually created a commit.
  git commit -q -F "$COMMIT_MSG_FILE" || { echo "DELIVER=commit-failed"; exit 1; }
  git push -u origin "$branch"
fi
```

The PR body is synthesized by the command from the plan file: **Goals** (from `## Goals & Non-Goals`), **Test summary** (from the qa-expert Step 3 report / Step 3-skipped note), **Verification** (Phase 2 real-run result if present), **Rollback** (from `## Rollback Strategy`). Draft vs. ready: if Step 2.5 recorded `blockers-remaining` or Phase 2 recorded a red gate, open with `gh pr create --draft`; otherwise ready. **No AI-attribution trailer** in the commit message or the PR body (enforced per `.claude/CLAUDE.md` Commit Message Standard; the command explicitly instructs this and does not use the Bash-tool HEREDOC default).

#### 1.5 Fix `/implement` bootstrap inconsistency (D11)

Add **Step 0: Non-project guard** to `implement.md`, reusing the exact detection block from `build-plan.md` Phase 0 (lines 13–29). On `NEEDS_BOOTSTRAP=1`, `/implement` does NOT bootstrap; it prints:

```
This directory is not a project and has no plan to implement.
Start with:  /build-plan <what you want>   (manual planning)
        or:  /autopilot <what you want>    (hands-free plan → build)
```

and stops before Step 1. On `NEEDS_BOOTSTRAP=0`, proceed to the existing Step 1 unchanged. WHY reuse the identical block verbatim: three entry points must agree on what "a project" means; divergent copies rot independently. (A future refactor could extract the block to a shared snippet, but that is out of scope — NG6.)

---

### Phase 2 — CI self-heal + real verification + security gate

#### 2.1 CI workflow templates (`.claude/templates/ci/`)

New template directory copied by `install.sh` into `~/.claude/templates/ci/`. Contents:

- `ci.generic.yml` — checkout + a lint placeholder + a build placeholder + a test placeholder, with clearly-marked scaffold slots the engineer fills from the detected stack.
- `ci.node.yml` — `actions/setup-node`, `npm ci`, `npm run lint --if-present`, `npm test`, `npm run build --if-present`.
- `ci.python.yml` — `actions/setup-python`, install (`pip install -e .[dev]` / `requirements`), `ruff`/`flake8` if present, `pytest`.

The engineer agent gains a short instruction (in the Phase 2 design, added to `engineer.md`'s scaffold section, lines 182–189) to, when scaffolding a new project: (a) drop the matching CI template into the generated project's `.github/workflows/ci.yml`, and (b) **vendor both `check-docs-fresh.sh` and `classify-changes.sh` into the generated repo under `.github/scripts/`** so the docs-freshness job has a repo-relative, runner-present copy of the gate and its classifier (D20 — the runner has no `~/.claude`). The scaffold therefore drops three files: `.github/workflows/ci.yml`, `.github/scripts/check-docs-fresh.sh`, and `.github/scripts/classify-changes.sh`. WHY templates live in this repo and are installed globally: generated projects should get a working CI file without the engineer hand-writing YAML each time; a single source template keeps them consistent, and the vendored scripts make the gate self-contained on any CI runner.

#### 2.2 CI self-heal loop: **Step 4.6: CI Heal** (only after Step 4.5 Deliver actually pushed)

Runs only if delivery pushed (a PR/branch exists on the remote) — otherwise there is no CI to read. **Mid-pipeline start (D1):** like Deliver, CI-heal is gated by the `--deliver`/`--deploy` flag, not by the start stage — a run resumed at `test`/`docs` that pushed via Deliver still heals CI. Implements D4:

```bash
CI_CAP=3
attempt=0
while [ "$attempt" -lt "$CI_CAP" ]; do
  # Wait for the run tied to the current branch's head SHA to complete.
  # gh run list --branch "$branch" --limit 1 --json status,conclusion,databaseId
  # Poll with a bounded number of sleeps (no infinite wait).
  status=... conclusion=...
  [ "$conclusion" = "success" ] && { echo "CI=green"; break; }
  attempt=$((attempt+1))
  # Pull the failing logs and hand them to the engineer as a fix brief.
  gh run view "$run_id" --log-failed > "$CI_LOG"
  # delegate engineer with $CI_LOG as context
  git add -A && git commit -q -F "$FIX_MSG" || { echo "CI-HEAL=nothing-to-commit"; break; }
  # ALWAYS re-run the unconditional secret scan (D6) on the heal diff BEFORE pushing.
  # WHY: the heal loop produces code that never passed reviewer/verify; the ONE
  # guarantee that must still hold for that code is "no secret ever reaches the remote."
  if ! run_secret_scan "$merge_base..HEAD"; then
    echo "CI-HEAL=ABORTED-secret-detected"   # surfaced loudly; NEVER pushed
    break
  fi
  git push
done
[ "$attempt" -ge "$CI_CAP" ] && [ "$conclusion" != "success" ] && echo "CI=red-after-$CI_CAP-attempts"
```

Stop conditions (loop-safety, mirroring `update-docs.sh`): (a) success, (b) attempt cap reached, (c) `gh`/network failure (record `CI=unavailable`, do not spin), (d) **secret detected in a heal commit → abort before push** (recorded `CI-HEAL=ABORTED-secret-detected`, surfaced loudly). Polling for run completion is itself bounded (a fixed max number of `gh run list` checks with a short sleep between; no unbounded wait). Every outcome is recorded, never a hang.

**Secret scan re-runs in the heal loop; reviewer/verify do not.** Before each heal push, the always-blocking secret scan from 2.4/D6 re-runs on the heal diff. A secret hit aborts the loop and is surfaced loudly — the heal commit is **never pushed**. WHY only the secret scan and not the full reviewer/verify: those are expensive and, re-run inside a bounded fix loop, risk turning a shallow lint fix into a runaway (cost/loop-safety); the secret scan is cheap, deterministic, and its guarantee (no pushed credential) is *unconditional* (D6) — it must hold even for code the loop itself produces. This is the one gate whose invariant survives the heal loop's cost-driven skips.

#### 2.3 Real-run verification gate: **Step 3.5: Verify** (after Step 3 Test, before Step 4 Docs)

Leverages the built-in `/verify` and `/run` skills. Distinct from unit tests: it **starts the actual artifact** and confirms behavior. Design:

- Detect the run surface from the manifest / plan: an HTTP server (start it, curl a health/known endpoint, assert 2xx), a CLI (invoke `--help` or a documented subcommand, assert exit 0 + expected substring), or a library (import it / run the example from the README).
- Bounded: start with a timeout, capture output, tear down the process in all paths (kill the started PID in a trap — resource cleanup per engineer standards).
- Advisory in autopilot (D5): record `verify: pass|fail|not-applicable` and continue. A dedicated `/verify` manual command (thin wrapper over the skill) treats failure as blocking for interactive use.

WHY after tests and before docs: verification failures often reveal integration gaps unit tests miss; catching them before docs means docs describe a system that actually runs. It is before Deliver so a failed verify marks the PR draft (D5 → 1.4 draft logic).

#### 2.4 Security + dependency gate: **Step 3.6: Security** (after Verify, before Docs/Deliver)

Leverages the built-in `/security-review` skill plus a dependency/secret audit:

- **Secret scan (always blocking, D6):** scan the diff for committed credentials (high-entropy strings, known key prefixes like `AKIA`, `-----BEGIN * PRIVATE KEY-----`, `ghp_`, etc.) using a POSIX `grep -E` pattern set. A positive hit **blocks delivery unconditionally** and is surfaced loudly. WHY unconditional: a pushed secret is unrecoverable (must be rotated), so the asymmetry justifies the one hard block.
- **Dependency audit (advisory, D6):** `npm audit --omit=dev` (node) or `pip-audit`/`safety` if available (python), guarded by tool presence; absence → `deps: skipped`. Advisory: findings are recorded and appended to the PR body, not blocking, unless `--strict-security` was passed.
- **`/security-review` skill:** run for logic-level vulnerabilities (injection, authz gaps). Advisory by default; contributes to the review report.

Records `security: pass|advisories|BLOCKED-secret` for summary + telemetry.

#### 2.5 Shared change-classification library (`.claude/lib/classify-changes.sh`) — prerequisite for 2.6

This is the **first** Phase 2 implementation step (P2-1 below). It must land BEFORE the stale-docs gate (2.6) so the gate consumes the shared source-of-truth definition on day one rather than introducing a fourth copy of the "what is source" pattern that a later refactor removes (D17).

**The problem.** Today the repo has two contradictory framings of "is this changed file source code":

- **Allowlist** — `update-docs.sh` line 46 `SOURCE_EXT_PATTERN` (~26 explicit code extensions), consumed at lines 115, 154, 181. A file is source only if it matches.
- **Blocklist** — `autopilot.md` lines 223–224 and `qa-expert.md` lines 18–19, both `grep -v '\.md$'`. A file is source if it is anything except `.md`.

They already disagree (a `migrations/x.sql` + `config/y.yaml`-only diff is "not source" under the allowlist but "is source" under the blocklist), and the disagreement is silent. See D17/D18/D19.

**The library.** New file `.claude/lib/classify-changes.sh`, POSIX `sh` (Git-Bash/macOS/Linux portable; no bash-isms, no GNU-only flags, no `jq`/`yq`, matching the plan-wide portability constraints). It defines `SOURCE_EXT_PATTERN` **once** (the `update-docs.sh` set plus `.sql` per D19) and exposes reusable helpers:

- `collect_changed_files` — the git-diff collection logic factored out of the three current re-implementations: `git diff --name-only HEAD` + `git ls-files --others --exclude-standard`, `sort -u`, strip blank lines. (This is the exact pattern at `update-docs.sh` lines 166–167/171–176 and duplicated in `autopilot.md` line 223 and `qa-expert.md` line 18.) Prints one path per line on stdout.
- `source_files_from_stdin` — reads a newline path list on stdin **only** (always `cat`s stdin; it never auto-collects and never sniffs the input mode) and prints the subset matching `SOURCE_EXT_PATTERN`. Callers always pipe into it. Empty output ⇒ no source files. WHY an unambiguous stdin-only contract: the earlier `[ -t 0 ]` tty-sniffing dual-mode would run `cat` and block forever on EOF when stdin is neither a tty nor a pipe (the common subagent/command/CI case), so no function in this library guesses its input mode.
- `is_source_change` — the convenience wrapper that pipes `collect_changed_files` into `source_files_from_stdin`, so it never reads an ambiguous stdin itself. Prints the source subset of the current working-tree change set; empty output ⇒ no source files.
- `is_markdown_only` — computes via the same `collect_changed_files | source_files_from_stdin` path and emits `MD_ONLY=1` (return 0) when the change set contains **no** source files — defined as the inverse of `is_source_change` (**not** `grep -v '\.md$'`, per D18) — or `MD_ONLY=0` (return 1) otherwise. This is the single definition the autopilot Step 3 guard and the qa-expert scope guard both call.

```sh
#!/bin/sh
# classify-changes.sh — single source of truth for "is a changed file source code?"
# Sourced by: update-docs.sh (Stop hook), autopilot.md Step 3 guard, qa-expert scope
# guard, and check-docs-fresh.sh (CI gate). WHY one file: the allowlist-vs-blocklist
# drift (D17) is only eliminable by construction — one definition, many consumers.
#
# Install location: ~/.claude/lib/classify-changes.sh (copied by install.sh); ALSO
# vendored into generated projects at .github/scripts/classify-changes.sh (D20) so
# the CI gate can source a repo-relative sibling on a runner with no Claude install.

# WHY this exact set: mirrors update-docs.sh SOURCE_EXT_PATTERN plus .sql (D19).
SOURCE_EXT_PATTERN='\.(ts|tsx|js|jsx|mjs|cjs|py|rs|go|java|rb|cpp|c|h|hpp|cs|swift|kt|scala|ex|exs|clj|zig|sh|lua|php|dart|sql)$'

collect_changed_files() {
  { git diff --name-only HEAD 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | grep -v '^[[:space:]]*$'
}

# WHY stdin-only (no [ -t 0 ] sniffing): guessing the input mode risks a `cat` that
# hangs on EOF when stdin is neither tty nor pipe. Callers ALWAYS pipe into this.
source_files_from_stdin() {
  cat | grep -E "$SOURCE_EXT_PATTERN" 2>/dev/null
}

is_source_change() {
  collect_changed_files | source_files_from_stdin
}

is_markdown_only() {
  if [ -n "$(collect_changed_files | source_files_from_stdin)" ]; then
    echo "MD_ONLY=0"; return 1
  fi
  echo "MD_ONLY=1"; return 0
}
```

**Consumers rewired (all four use the one definition):**

1. `.claude/hooks/update-docs.sh` — source the library instead of defining its own `SOURCE_EXT_PATTERN` at line 46; replace the three `grep -E "$SOURCE_EXT_PATTERN"` spots (lines 115, 154, 181) and the diff-collection blocks with the shared helpers. **Install implication:** `install.sh` copies hooks to `~/.claude/hooks/`, so the library must be installed where the hook can source it at runtime. Decision: install to `~/.claude/lib/classify-changes.sh` and have the hook source it via an absolute path `. "$HOME/.claude/lib/classify-changes.sh"`. `install.sh` gains a step to copy `.claude/lib/` → `~/.claude/lib/`.
2. `.claude/commands/autopilot.md` — replace the inlined `grep -v '\.md$'` markdown-only block (Step 3, lines 223–224) with a call to `is_markdown_only`. **Runtime nuance:** command markdown executes from the PROJECT dir, but the installed library lives at `$HOME/.claude/lib/`, so the inlined bash sources it via `. "$HOME/.claude/lib/classify-changes.sh"` (quoted `~` does not expand — always use `$HOME` in the source line).
3. `.claude/agents/qa-expert.md` — same replacement in its scope guard (lines 18–19): `. "$HOME/.claude/lib/classify-changes.sh"` then call `is_markdown_only`.
4. `.claude/templates/ci/check-docs-fresh.sh` (2.6) — sources the same library for `SOURCE_EXT_PATTERN` / `source_files_from_stdin` rather than hardcoding its own copy (this is the copy D17 prevents from ever existing). **This is the one consumer that does NOT source `$HOME/.claude/lib` at runtime:** it runs on a CI runner with no Claude install, so it resolves the library **repo-relative** to its own location and reads the **vendored sibling** shipped into the generated repo under `.github/scripts/classify-changes.sh` (D20); `$HOME/.claude/lib` is only a local-dev fallback.

**Fail-safe on a missing library** (backward-compat for installs that predate `~/.claude/lib/`): every consumer checks the file exists before sourcing and degrades to a *conservative default* appropriate to its posture:

- **Stop hook** (`update-docs.sh`): if the lib is absent, **fail open** — prefer NOT to block Claude's stop (match the hook's existing fail-open exits at lines 122/161/204). Concretely, fall back to the inline `SOURCE_EXT_PATTERN` it defines today (kept as a guarded fallback) so an un-reinstalled environment behaves exactly as before.
- **autopilot / qa-expert guards:** if the lib is absent, fall back to the current `grep -v '\.md$'` inline block (documented as the transitional fallback) so a stale install still runs.
- **CI gate** (`check-docs-fresh.sh`): resolves the library **repo-relative** to its own location and reads the vendored sibling (`.github/scripts/classify-changes.sh`), falling back to `$HOME/.claude/lib` only for local dev. If even the vendored sibling is absent it prints a clear error and exits non-zero (a CI gate must not silently pass); because the vendor step (2.1 / P2-7) commits both files together, they are always co-present in a properly scaffolded repo (D20).

The **install-ordering risk** is explicit: existing installs will not have `~/.claude/lib/` until they re-run `install.sh`. The fail-safe fallbacks above make that window behavior-preserving rather than broken.

#### 2.6 Stale-docs CI gate (`check-docs-fresh.sh` + CI templates)

A **CI-time verification check**, not a doc-authoring step. It does not write documentation — doc authoring stays exactly where it is today (pre-PR, autopilot Step 4, via `doc-maintainer`). This gate is purely an enforcement net at CI time that fails a PR run when source files changed in the diff but no known doc surface changed alongside them, catching the case where `doc-maintainer` was skipped, disabled, or missed a surface (D13).

**Placement.** The check is a job/step in the three Phase 2 CI templates (`ci.generic.yml`, `ci.node.yml`, `ci.python.yml`) rather than duplicated inline YAML in each. All three templates call a single standalone POSIX shell script, `check-docs-fresh.sh`, so the logic is testable locally and portable across the templates without duplication (D13). The script ships in this repo (`.claude/templates/ci/check-docs-fresh.sh`) and is installed globally alongside the templates (`~/.claude/templates/ci/`). When scaffolding a generated project, the engineer step (2.1) **vendors both `check-docs-fresh.sh` and `classify-changes.sh` into the generated repo under `.github/scripts/`** (a committed, in-repo location that exists on the CI runner) and drops the workflow (`.github/workflows/ci.yml`) that invokes `.github/scripts/check-docs-fresh.sh`. WHY vendored siblings and not `$HOME/.claude` on CI: the GitHub Actions runner has no Claude Code install, so `$HOME/.claude/lib/classify-changes.sh` does not exist there — the gate resolves its library **repo-relative** to its own location (see the `SCRIPT_DIR` logic above) and the vendored sibling is authoritative on the runner (D20).

**Detection heuristic (low false-positive, D14).** POSIX/Git-Bash-portable:

```bash
#!/bin/sh
# check-docs-fresh.sh — CI gate: fail if source changed but docs did not.
# Exits 0 (pass) or 1 (stale docs). Prints an actionable message on failure.

BASE_REF="${1:-origin/${GITHUB_BASE_REF:-main}}"
# Merge base against the target branch; fall back to a simple diff if unavailable.
merge_base=$(git merge-base "$BASE_REF" HEAD 2>/dev/null) || merge_base="$BASE_REF"
changed=$(git diff --name-only "$merge_base" HEAD)

# Source boundary comes from the shared library (single source of truth, D17-D19).
# WHY sourced, not inlined: this is the copy D17 exists to prevent — the gate uses
# the SAME SOURCE_EXT_PATTERN as the Stop hook / autopilot / qa-expert guards.
# WHY repo-relative first (D20): on a CI runner there is NO ~/.claude install, so the
# authoritative copy is the VENDORED sibling committed next to this script under
# .github/scripts/. $HOME/.claude/lib is only a local-dev fallback. CLASSIFY_LIB
# overrides both for testing.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB="${CLASSIFY_LIB:-$SCRIPT_DIR/classify-changes.sh}"
[ -f "$LIB" ] || LIB="$HOME/.claude/lib/classify-changes.sh"
[ -f "$LIB" ] || { echo "docs-freshness: ERROR — classify-changes.sh not found (looked in $SCRIPT_DIR and \$HOME/.claude/lib)"; exit 2; }
. "$LIB"
doc_pattern='^(README\.md|CLAUDE\.md|\.claude/CLAUDE\.md|docs/|\.env\.example)'

changed_src=$(printf '%s\n' "$changed" | source_files_from_stdin || true)
changed_docs=$(printf '%s\n' "$changed" | grep -E "$doc_pattern" || true)

# Escape hatch: commit-message / PR-body token [skip-docs] (D15).
if git log "$merge_base"..HEAD --format=%B 2>/dev/null | grep -qiF '[skip-docs]'; then
  echo "docs-freshness: skipped via [skip-docs] token"; exit 0
fi

# Markdown-only or no-source change → trivially satisfied (mirror PLAN-003/qa-expert).
if [ -z "$changed_src" ]; then
  echo "docs-freshness: pass (no source files changed)"; exit 0
fi
if [ -n "$changed_docs" ]; then
  echo "docs-freshness: pass (docs updated alongside source)"; exit 0
fi

echo "docs-freshness: FAIL — source changed but no doc surface was updated."
echo "Changed source files:"; printf '  %s\n' $changed_src
echo "Fix by running doc-maintainer (e.g. /autopilot-from docs), updating one of"
echo "README.md / CLAUDE.md / docs/** / .env.example, or add [skip-docs] to a"
echo "commit message or the PR body if this change genuinely needs no docs."
exit 1
```

WHY the gate sources the shared library instead of hardcoding an extension list: the Stop hook, autopilot, and qa-expert now all obtain "what counts as source" from `.claude/lib/classify-changes.sh` (D17); the CI gate uses the *same* `SOURCE_EXT_PATTERN` / `source_files_from_stdin` so a change that would have triggered doc-maintainer locally is exactly the change the gate enforces at CI time — single-sourced semantics with no fourth copy to drift (D14/D17). On CI the gate sources the **vendored sibling** `.github/scripts/classify-changes.sh` (resolved repo-relative), falling back to `$HOME/.claude/lib` only for local-dev use; the exit-2 error now triggers only if *even the vendored sibling* is missing (a CI gate must never silently pass), which cannot happen for a properly scaffolded repo because the vendor step commits both files together (D20). The doc-surface list (`README.md`, `CLAUDE.md`, `docs/**`, `.env.example`) mirrors the documentation surfaces in the CLAUDE.md Documentation Maintenance list.

**Escape hatch — commit/PR-body token `[skip-docs]` (D15).** WHY a token, not a PR label: the standalone script runs identically across CI providers and locally, and a commit-message / PR-body token is visible to `git log` in every provider, whereas a PR *label* is only reachable via provider-specific API calls (a GitHub-only `gh`/`GITHUB_TOKEN` round-trip) that the portable script deliberately avoids (NG1 keeps the dependency surface to git/gh/node, and the script must work with plain `git`). The failure message always prints how to use the token, so nobody has to guess. The token is matched with `grep -iF` (fixed-string, case-insensitive) so `[skip-docs]`, `[Skip-Docs]`, etc. all match without regex surprises.

**Blocking vs. advisory (D16).** This gate is **blocking** (a required check), unlike the security dependency gate which is advisory by default (D6). The two can differ because the docs-freshness check is (a) *deterministic* — it is a pure function of the file lists in the diff, with no CVE-feed variance or transitive-advisory noise; (b) *cheap to satisfy* — the fix is either a one-line doc edit or the `[skip-docs]` token; and (c) *has a cheap, explicit release valve* — the token. A general security advisory has none of these: it is noisy, its "fix" may be a dependency bump the author can't make, and hard-blocking it would make autopilot unusable (D6). The one true-positive-blocking piece of the security gate — the secret scan (D6) — is blocking for the *opposite* reason (irreversible harm); docs-freshness blocks because the harm (drifted docs) is cheap to prevent and the escape is trivial. The residual **false-positive risk** — a pure internal refactor that legitimately needs no doc change — is accepted precisely because the `[skip-docs]` token is a one-token release valve; that token, not advisory-mode, is the pressure relief (D16).

**Markdown-only interaction.** Mirrors the existing PLAN-003 / `qa-expert` markdown-only logic: if the diff is markdown-only (or otherwise contains no source-extension files), `changed_src` is empty and the gate passes trivially — it never errors on a docs-only or config-only PR. A markdown-only PR that edits docs is doubly satisfied (no source changed *and* docs changed).

---

### Phase 3 — Intake, deploy/monitor sketch, model tiering, metrics

#### 3.1 Intake as a planning phase (D7)

Add to `planner.md` (auto and manual modes) an **intake sub-step**: before writing the plan body, if the ask is *ambiguous*, the planner emits three explicit sections into the plan — `## Acceptance Criteria` (checklist of observable outcomes), `## Out of Scope` (already partly covered by Non-Goals; intake makes it mandatory for ambiguous asks), and `## Success Metrics`. 

Ambiguity heuristic (documented in `planner.md`): treat an ask as ambiguous if it lacks a concrete acceptance signal — e.g. no explicit inputs/outputs, verbs like "improve/optimize/handle/support" without a measurable target, or scope words like "etc." / "and so on." For clearly-specified asks, intake is a no-op (avoids ceremony on trivial tasks, mirroring `build-plan.md` Phase 1 "for simple tasks, 1 round is enough").

qa-expert and reviewer read `## Acceptance Criteria` when present and treat each item as a test/verification target. This closes the loop from intent → tests → review.

#### 3.2 Deploy + monitor loop — **design sketch only** (G8, NG3)

This is deliberately under-specified. Scope of the sketch:

- **Deploy stage (behind `--deploy`, implies `--deliver`, D1):** after a PR is green and merged by a human (NG5), a `deploy` step would invoke a project-provided `scripts/deploy.sh` if it exists (convention over configuration). If absent → `deploy: no-deploy-script`. We do NOT write cloud-provider deploy logic (NG3).
- **Monitor → next-plan feedback (sketch):** a `monitor` step would read a project-provided error source (a log file path or an error-tracker CLI the project configures via `scripts/errors.sh`), and if it surfaces a recurring error signature, it would draft a new `PLAN-{NNN}` with `type: bugfix` in `./docs/plans/` describing the observed failure — feeding the *next* iteration of the loop. This is the "outer-outer" loop and is intentionally left as a documented interface (`scripts/deploy.sh`, `scripts/errors.sh` conventions) rather than an implementation.

**Explicit non-goals for 3.2:** no polling daemon, no scheduler, no provider SDKs, no auto-merge, no auto-rollback of a deploy. The sketch defines the *convention* (project-supplied scripts) and the *hand-off* (draft the next plan), nothing more.

#### 3.3 Model tiering (D8/D9)

Add a `model:` line to each agent's frontmatter:

| Agent | File | `model:` |
|-------|------|----------|
| planner | `.claude/agents/planner.md` | `claude-opus-4-8` |
| reviewer | `.claude/agents/reviewer.md` | `claude-opus-4-8` |
| engineer | `.claude/agents/engineer.md` | `claude-sonnet-4-6` |
| qa-expert | `.claude/agents/qa-expert.md` | `claude-sonnet-4-6` |
| doc-maintainer | `.claude/agents/doc-maintainer.md` | `claude-haiku-4-5-20251001` |

A `WHY:` comment near each frontmatter (in the agent body, since YAML comments are lost by some parsers) documents the tier choice. README gains a "Model tiering" table. Fable 5 (`claude-fable-5`) is listed as available-but-unassigned with the rationale from D9.

#### 3.4 Telemetry (D10)

A tiny POSIX helper block appended at each gate that emits one JSONL line to `~/.claude/telemetry/sdlc.jsonl`:

```bash
emit_metric() {
  # $1=stage $2=outcome $3=extra_json_fragment (optional, already-formed "key":val pairs)
  TELEM_DIR="$HOME/.claude/telemetry"
  mkdir -p "$TELEM_DIR" 2>/dev/null
  proj=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","project":"%s","stage":"%s","outcome":"%s"%s}\n' \
    "$ts" "$proj" "$1" "$2" "${3:+,$3}" >> "$TELEM_DIR/sdlc.jsonl"
}
```

Cycle time = derived at read-time from the `plan` start ts and `deliver`/`docs` end ts for a given plan id (recorded as an `"extra"` field). Emitted at: plan, review, test, verify, security, ci-heal, deliver. Privacy per D10 — no diffs, no code, no task text. `install.sh` documents the file; a `.gitignore` entry is NOT needed because it lives under `~/.claude/`, outside any project tree.

## Implementation Steps

Each phase is independently shippable. Complete and merge a phase before starting the next.

### Phase 1 — Review + Delivery (highest ROI)

| Step | File | Change |
|------|------|--------|
| P1-1 | `.claude/agents/reviewer.md` | Create adversarial reviewer agent (frontmatter incl. `model: claude-opus-4-8`, `tools` without Write/Edit); markdown scope-guard; diff discovery via `git diff HEAD` + `git ls-files --others --exclude-standard`; critique against `.claude/CLAUDE.md`; structured report ending in `REVIEW_VERDICT=` + `BLOCKERS=`. |
| P1-2 | `.claude/commands/autopilot.md` | Insert **Step 2.5: Review** (reviewer↔engineer loop, cap 2 per D3); wire draft-PR logic input. |
| P1-3 | `.claude/commands/autopilot-from.md` | Insert identical **Step 2.5: Review**; skip when starting stage is `test`/`docs`. |
| P1-4 | `.claude/commands/review.md` | Create `/review` manual command (single-shot reviewer over working-tree diff, no auto-fix). |
| P1-5 | `.claude/commands/autopilot.md`, `autopilot-from.md` | Add flag parsing (`--deliver`, `--deploy`) that strips flags before task/name derivation; insert **Step 4.5: Deliver** (gh-guarded commit→**guarded** push→PR; push only when a commit was created or the branch is ahead of upstream, Item 8; PR body synthesized from plan; draft if blockers/red; NO AI-attribution). In `autopilot-from`, Deliver runs whenever the flag is present **regardless of the `test`/`docs` start stage** (flag-gated, not stage-gated — D1). |
| P1-6 | `.claude/commands/implement.md` | Add **Step 0: Non-project guard** reusing `build-plan.md` Phase 0 detection block verbatim; refuse-and-redirect on `NEEDS_BOOTSTRAP=1` (D11). |
| P1-7 | `install.sh`, `settings.local.json` (installed allowlist) | Copy `reviewer.md` and `review.md`; update the file manifest comment and the post-install command summary. **Add allowlist entries for `gh *`, `git push:*`, `git commit:*`** so `--deliver` runs commit/push/PR without prompting on every call (Item 7). |
| P1-8 | `README.md`, `.claude/CLAUDE.md`, `docs/architecture.md` | Document the reviewer, `/review`, `--deliver` flag, and the D1 resolution. **`docs/architecture.md`** gains the reviewer agent + `/review` and the delivery stage (`--deliver`/`--deploy`) in the component/data-flow overview. |

### Phase 2 — CI heal + Verify + Security

| Step | File | Change | Depends |
|------|------|--------|---------|
| P2-1 | `.claude/lib/classify-changes.sh` | Create the shared change-classification library: define `SOURCE_EXT_PATTERN` once (`update-docs.sh` set + `.sql`, D19); export `collect_changed_files`, `is_source_change`, `is_markdown_only` (inverse of `is_source_change`, NOT `grep -v '\.md$'`, D18); POSIX `sh`, portable (D17). | None |
| P2-2 | `.claude/hooks/update-docs.sh` | Source the library via `. "$HOME/.claude/lib/classify-changes.sh"` (quoted `~` does not expand — use `$HOME`); remove the local `SOURCE_EXT_PATTERN` (line 46) and use shared helpers at the 3 spots (lines 115, 154, 181) + diff collection; keep the inline pattern as a guarded fail-open fallback if the lib is missing (D17). | P2-1 |
| P2-3 | `.claude/commands/autopilot.md` | Replace the inlined `grep -v '\.md$'` Step 3 guard (lines 223–224) with a call to `is_markdown_only` sourced via `. "$HOME/.claude/lib/classify-changes.sh"` (use `$HOME`, not quoted `~`; project-dir runtime nuance, D18); fall back to the inline block if the lib is missing. | P2-1 |
| P2-4 | `.claude/agents/qa-expert.md` | Replace the identical `grep -v '\.md$'` scope guard (lines 18–19) with `is_markdown_only` sourced via `. "$HOME/.claude/lib/classify-changes.sh"` (use `$HOME`, not quoted `~`); same fallback. | P2-1 |
| P2-5 | `install.sh` | Copy `.claude/lib/` → `~/.claude/lib/` (so the Stop hook, commands, and agents can source it at runtime); update file manifest comment + post-install summary. Note install-ordering: pre-existing installs lack `~/.claude/lib/` until re-run (fail-safe covers the window, D17). | P2-1 |
| P2-6 | `.claude/templates/ci/ci.generic.yml`, `ci.node.yml`, `ci.python.yml` | Create three CI templates (D12). | None |
| P2-7 | `.claude/agents/engineer.md` | Add scaffold instruction: on new-project scaffold, detect stack and drop the matching CI template into `.github/workflows/ci.yml`, AND **vendor both `check-docs-fresh.sh` and `classify-changes.sh` into the generated repo under `.github/scripts/`** (repo-relative, runner-present copies for the docs-freshness gate — D20). | P2-6, P2-12 |
| P2-8 | `.claude/commands/autopilot.md`, `autopilot-from.md` | Insert **Step 3.5: Verify** (real-run, advisory, bounded, trap-cleanup; D5). | P1 merged |
| P2-9 | `.claude/commands/verify.md` | Create `/verify` manual command (blocking real-run wrapper over `/verify`+`/run` skills). | None |
| P2-10 | `.claude/commands/autopilot.md`, `autopilot-from.md` | Insert **Step 3.6: Security** (always-blocking secret scan; advisory deps + `/security-review`; `--strict-security`; D6). | P1 merged |
| P2-11 | `.claude/commands/autopilot.md`, `autopilot-from.md` | Insert **Step 4.6: CI Heal** (cap 3, bounded polling; D4); **re-run the always-blocking secret scan on each heal diff BEFORE pushing — a hit aborts the loop and is never pushed** (Item 4/D6); terminal outcomes now include `CI-HEAL=ABORTED-secret-detected`; runs only if Deliver pushed. Flag-gated (runs on a `test`/`docs` resume if `--deliver` pushed — D1), not stage-gated. | P1-5, P2-10 |
| P2-12 | `.claude/templates/ci/check-docs-fresh.sh` | Create standalone POSIX stale-docs CI gate script that **resolves `classify-changes.sh` repo-relative to its own location** (`SCRIPT_DIR`; honors `CLASSIFY_LIB`; falls back to `$HOME/.claude/lib` for local dev only — D20) for `SOURCE_EXT_PATTERN`/`source_files_from_stdin` (no fourth copy, D17); merge-base diff, source-vs-doc-surface heuristic, `[skip-docs]` token, markdown-only pass, actionable failure message; blocking; exits non-zero only if even the vendored sibling is absent (D13–D16, D20). | P2-1 |
| P2-13 | `.claude/templates/ci/ci.generic.yml`, `ci.node.yml`, `ci.python.yml` | Add a `docs-freshness` job/step to each template that invokes `.github/scripts/check-docs-fresh.sh` (single script, no duplicated logic; the vendored repo-relative path in the generated project); checkout must use `fetch-depth: 0` so the merge base is available (D13/D14/D20). | P2-6, P2-12 |
| P2-14 | `install.sh` | Copy `templates/ci/*` to `~/.claude/templates/ci/`; copy `verify.md`; ensure `check-docs-fresh.sh` is copied with the executable bit; update manifest + summary. | P2-6, P2-9, P2-12 |
| P2-15 | `README.md`, `.claude/CLAUDE.md`, `docs/architecture.md` | Document the shared classification library + allowlist-over-blocklist unification + `.sql` boundary, CI templates + vendored gate, verify gate, security gate, `--strict-security`, retry caps, and the stale-docs gate + `[skip-docs]` escape token. **`docs/architecture.md`** gains the shared classification library, the CI templates + gates, and the verify/security steps in the component/data-flow overview. | P2-1..P2-13 |

### Phase 3 — Intake + Deploy sketch + Model tiering + Telemetry

| Step | File | Change | Depends |
|------|------|--------|---------|
| P3-1 | `.claude/agents/planner.md` | Add intake sub-step + ambiguity heuristic; emit `## Acceptance Criteria`, `## Out of Scope`, `## Success Metrics` for ambiguous asks (D7). | None |
| P3-2 | `.claude/agents/qa-expert.md`, `reviewer.md` | Read `## Acceptance Criteria` when present; treat items as test/review targets. | P3-1, P1-1 |
| P3-3 | `.claude/agents/planner.md`,`reviewer.md`,`engineer.md`,`qa-expert.md`,`doc-maintainer.md` | Add `model:` frontmatter per D9 + a WHY note in each body. | None |
| P3-4 | `.claude/commands/autopilot.md`, `autopilot-from.md` | Add `emit_metric` helper + calls at each gate (D10). | P1, P2 |
| P3-5 | `docs/` (this repo) + command bodies | Document the deploy/monitor **sketch** and the `scripts/deploy.sh` / `scripts/errors.sh` conventions and `--deploy` flag; implement NO provider logic (NG3). | None |
| P3-6 | `install.sh`, `README.md`, `.claude/CLAUDE.md`, `docs/architecture.md` | Document model tiering table, telemetry file + privacy stance, intake, deploy sketch. **`docs/architecture.md`** gains the model-tiering, telemetry, and deploy/monitor-sketch in the component/data-flow overview. | P3-1..P3-5 |

## Affected Components

**Source (commands):** `.claude/commands/autopilot.md`, `.claude/commands/autopilot-from.md`, `.claude/commands/implement.md`, `.claude/commands/review.md` (new), `.claude/commands/verify.md` (new).

**Source (agents):** `.claude/agents/reviewer.md` (new), `.claude/agents/planner.md`, `.claude/agents/engineer.md`, `.claude/agents/qa-expert.md`, `.claude/agents/doc-maintainer.md`.

**Library (new):** `.claude/lib/classify-changes.sh` — single source of truth for "is a changed file source code" (D17–D19); sourced by the Stop hook, autopilot Step 3 guard, qa-expert scope guard, and the stale-docs CI gate. Installed to `~/.claude/lib/`.

**Templates (new):** `.claude/templates/ci/ci.generic.yml`, `ci.node.yml`, `ci.python.yml`, `.claude/templates/ci/check-docs-fresh.sh` (standalone stale-docs CI gate, called by all three templates; sources `classify-changes.sh` repo-relative). **Vendored into generated projects (D20):** the engineer scaffold drops `.github/scripts/check-docs-fresh.sh` + `.github/scripts/classify-changes.sh` + `.github/workflows/ci.yml` into each generated repo so the gate runs on a CI runner with no `~/.claude`.

**Installer/config:** `install.sh` (copy new files including `.claude/lib/`, update manifest + post-install summary). `settings.local.json` / the installed permissions allowlist gains entries for `gh *`, `git push:*`, `git commit:*` so `--deliver` runs commit/push/PR without a prompt on every call (P1-7, Item 7). `.claude/settings.json` unchanged (Stop-hook wiring untouched; reviewer is command-driven, not Stop-driven — see A2).

**Hooks:** `.claude/hooks/update-docs.sh` — **modified** (P2-2): sources the shared `classify-changes.sh` instead of defining its own `SOURCE_EXT_PATTERN`; the fingerprint/dedup loop and its fail-open posture are preserved (NG4 — the change is to the source-classification source of truth, not to the dedup philosophy). Reviewer deliberately not added as a parallel Stop-hook agent.

**Also modified for the shared library (P2-3/P2-4):** `.claude/commands/autopilot.md` (Step 3 markdown-only guard → `is_markdown_only`) and `.claude/agents/qa-expert.md` (scope guard → `is_markdown_only`) — both listed above under Commands/Agents; noted here as consumers of `.claude/lib/classify-changes.sh`.

**Docs:** `README.md`, `.claude/CLAUDE.md`, `docs/architecture.md` (updated in every phase: reviewer + `/review`, delivery + `--deliver`/`--deploy`, CI templates + gates, the shared classification library, verify/security steps, model tiering, telemetry — Item 3), and this plan. Deploy/monitor sketch documented in command bodies + README.

**Runtime artifacts (outside repo):** `~/.claude/telemetry/sdlc.jsonl` (created at runtime), `~/.claude/templates/ci/*` (installed).

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Autopilot pushes/opens a PR unintentionally | Low | High | Delivery OFF by default; only the explicit `--deliver`/`--deploy` flag activates it (D1/D2). Default run is identical to today. |
| Reviewer↔engineer loop never terminates | Low | High | Hard cap of 2 iterations (D3); on exhaustion, proceed + draft PR + record `blockers-remaining`. |
| CI heal loop burns tokens/CI minutes indefinitely | Low | Med | Cap of 3 (D4); bounded run-completion polling; `gh`/network failure short-circuits to `CI=unavailable`. |
| A committed secret gets pushed | Low | Critical | Secret scan is **unconditionally blocking** (D6), runs before Deliver **and re-runs on every CI-heal fix commit before its push** (Item 4/D6) — a hit aborts the heal loop (`CI-HEAL=ABORTED-secret-detected`) and is never pushed, so the invariant holds even for code the loop itself produces. |
| CI-heal loop pushes an un-scanned secret from its own fix commits | Low | Critical | The always-blocking secret scan re-runs on each heal diff before push (Item 4); reviewer/verify are intentionally skipped in the loop for cost/loop-safety, but the secret scan's unconditional guarantee is preserved. |
| Dependency audit false positives block every run | Med | Med | Deps audit advisory by default; blocking only with `--strict-security` (D6). |
| `gh` missing / unauthenticated | Med | Low | Every `gh` call guarded by `command -v gh` + `gh auth status`; degrades to a recorded skip, never a crash. |
| Real-run verify too brittle across environments | High | Med | Advisory in autopilot (D5); only `/verify` manual command hard-blocks; process torn down via trap in all paths. |
| Bash blocks break under Git Bash on Windows | Med | High | POSIX-only, no GNU-only flags, `awk` for parsing (matches existing `autopilot.md`/`update-docs.sh`); Testing Strategy exercises all three OSes. |
| Model IDs drift / a tier is renamed | Low | Med | IDs centralized in D8 and the 3.3 table; a single edit updates all agents. Session model still works if an override is stale (agent inherits session). |
| Three copies of the bootstrap-detection block diverge | Med | Low | Copied verbatim (D11/1.5); documented as a known future extract (NG6). Testing checks byte-identity. |
| PR body accidentally includes AI-attribution trailer | Low | Med | Command explicitly instructs no trailer and avoids the Bash HEREDOC default; reviewer + a grep check in Testing Strategy catch it. |
| Stale-docs gate false-positive on a pure internal refactor that needs no docs | Med | Low | Accepted by design (D16); the `[skip-docs]` commit/PR-body token is the one-token release valve and the failure message always prints how to use it. Gate is deterministic (file-list function only), so no flaky blocks. |
| Stale-docs gate can't compute the merge base in CI (shallow clone) | Med | Med | Templates set `fetch-depth: 0` on checkout (P2-13); the script falls back to diffing against the base ref directly if `git merge-base` fails, and never hard-crashes. |
| Authors learn to blanket-add `[skip-docs]` to bypass the gate | Low | Low | The token is visible in `git log`/PR body and thus reviewable by a human at merge; the gate is an enforcement net, not a substitute for review. Cheap-fix asymmetry (D16) makes honest use the path of least resistance. |
| Shared `classify-changes.sh` missing at runtime (source of a non-existent file) | Med | Med | Every consumer checks the file exists before sourcing and fails safe by posture (D17): Stop hook + autopilot/qa-expert guards fall back to their prior inline logic (fail-open / behavior-preserving); the CI gate resolves the classifier repo-relative to the **vendored sibling** (`.github/scripts/classify-changes.sh`, D20) and exits non-zero only if even that is absent (never silently passes). No consumer crashes on a missing lib. |
| CI docs-gate hard-fails every real CI run because `$HOME/.claude` is absent on the runner | (was Med/High) | Resolved | The gate no longer sources `$HOME` on CI: the scaffold **vendors** `check-docs-fresh.sh` + `classify-changes.sh` into the generated repo under `.github/scripts/`, and the gate resolves the library **repo-relative** to its own location (D20). `$HOME/.claude/lib` is only a local-dev fallback. Testing #9(f)/(g) assert the gate runs with no `$HOME/.claude` and errors only if the vendored sibling is also missing. |
| Vendored CI classifier snapshot lags the source `classify-changes.sh` | Med | Low | Accepted CI-isolation tradeoff (D20): the vendored copy is a deliberate pinned snapshot decoupled from `~/.claude/lib`. Re-scaffolding (or a future `--update-scaffold` pass) refreshes it. This does not reintroduce D17 drift *within this repo* — THIS repo's consumers still resolve to one file; the vendored copy is a shipped scaffold artifact in a different repo. |
| Install-ordering: existing installs lack `~/.claude/lib/` until they re-run `install.sh` | High | Low | The missing-library fail-safe above makes the pre-reinstall window behavior-preserving (each consumer runs its prior inline logic). `install.sh` (P2-5) copies `.claude/lib/`; the post-install summary tells users to re-run to pick up the shared library. |
| Unifying the two framings changes behavior for `.sql`/`.yaml`/config-only diffs | Med | Low | Intentional (D18/D19). A `.sql`-only diff now triggers qa/docs everywhere (previously the allowlist skipped it in the Stop hook but the blocklist ran qa in autopilot — inconsistent). A `.yaml`/config-only diff now consistently skips qa (previously the blocklist ran it). Called out here as a deliberate, documented behavior change, not a regression; Testing Strategy #10 asserts all consumers agree on the same corpus. |

## Rollback Strategy

Every change is additive markdown/YAML plus one JSONL side-effect — fully reversible, zero data migration.

- **Per-phase git revert:** each phase is a self-contained branch/PR. Reverting the merge commit removes that phase cleanly; earlier phases keep working.
- **New files (reviewer.md, review.md, verify.md, templates):** deleting them and their `install.sh` copy lines fully removes the feature. Existing commands that reference a removed step degrade if the step block is also reverted — so revert command edits and new files together (they live in the same phase commit).
- **Delivery/CI/deploy:** OFF by default, so even un-reverted, they are dormant unless a user passes a flag. Zero blast radius on default runs.
- **Telemetry file:** `rm ~/.claude/telemetry/sdlc.jsonl`. No project data touched. `install.sh` never deletes user projects.
- **Model tiering:** removing the `model:` frontmatter lines reverts agents to inheriting the session model (current behavior).
- **No irreversible action** is taken without an explicit flag, so a bad autopilot run on the default path produces only local branch files, exactly as today.

## Testing Strategy

Markdown-driven commands/agents cannot be unit-tested in the traditional sense (per `qa-expert.md` lines 12–26, the honest verification is live invocation). The strategy is therefore layered:

1. **Static lint of embedded bash blocks.** Extract every ```bash block from changed `.md` files and run `bash -n` (syntax check) and `shellcheck` (if available) on each. Verify no GNU-only constructs (`sed -I`, `grep -P`) via a grep guard. This catches the highest-frequency failure class (broken portability) without live invocation.
2. **Cross-OS portability matrix.** Manually (or via CI on this repo) run the extracted blocks under Git Bash (Windows), bash (macOS), bash (Linux). Assert identical `NEEDS_BOOTSTRAP`, `REVIEW_VERDICT`, `DELIVER=*`, `CI=*` outputs for fixture inputs.
3. **Byte-identity check.** Assert the bootstrap-detection block in `implement.md` Step 0 is byte-identical to `build-plan.md` Phase 0 (guards against divergence — D11 risk).
4. **Flag-parsing fixtures.** Feed `$ARGUMENTS` fixtures (`"--deliver add auth"`, `"add auth"`, `"--deploy --strict-security add auth"`) and assert flags are stripped before name derivation and set the right booleans.
5. **Live smoke (the real verification).** In a throwaway repo: (a) run `/autopilot "add a hello CLI"` with no flag → assert it stops at a local branch, no remote touched, telemetry line written. (b) run with `--deliver` against a test remote → assert commit has NO AI-attribution trailer (`git log -1 --format=%B | grep -qi 'co-authored-by: claude' && fail`), PR opened, PR body has Goals/Test/Rollback. (c) Force a lint failure → assert CI-heal loops ≤3 then records `red-after-3-attempts`. (d) Commit a fake `AKIA...` string → assert Security step blocks delivery unconditionally.
6. **Reviewer gate test.** Introduce a diff with an empty catch block and an `any` type → assert reviewer emits ≥1 blocker and `REVIEW_VERDICT=changes-requested`, and the autopilot loop dispatches the engineer then re-reviews (cap respected).
7. **Telemetry schema test.** After a run, `node -e` parse each JSONL line → assert valid JSON, required keys present, no diff/code/task-text leakage (privacy per D10).
8. **`install.sh` idempotency.** Re-run installer twice → assert new files copied, no errors, manifest comment updated, backup taken.
9. **Stale-docs gate (`check-docs-fresh.sh`) fixtures.** In a throwaway repo with a base branch, exercise each branch of the heuristic (D13–D16): (a) commit a change to a `.ts`/`.py` source file with NO doc surface touched → assert exit 1 and the failure message names the changed source files and mentions `[skip-docs]`; (b) commit the same source change *plus* a `README.md`/`docs/**` edit → assert exit 0 (`pass — docs updated`); (c) commit a markdown-only / docs-only change (no source extension) → assert exit 0 (`pass — no source files changed`), never an error; (d) commit a source change with `[skip-docs]` in the commit message (and separately in a simulated PR body) → assert exit 0 (`skipped via [skip-docs]`), and verify case-insensitivity (`[Skip-Docs]`); (e) run under a shallow clone / missing merge base → assert graceful fallback to the base-ref diff, no crash; (f) **run on a runner with NO `$HOME/.claude`** (unset/point `HOME` at an empty dir) but WITH the vendored sibling present at `.github/scripts/classify-changes.sh` → assert the gate resolves the classifier repo-relative and runs correctly (this is the real-CI case, D20); (g) run with the **vendored sibling removed** *and* no `$HOME/.claude/lib` → assert exit 2 with the `classify-changes.sh not found` error naming both search locations (never a silent pass). Also `bash -n` + `shellcheck` the script (covered by #1).
10. **Shared classification library (`classify-changes.sh`) — the single-source-of-truth guarantees (D17–D19) + the explicit-stdin contract (Item 2).** In a throwaway repo: (a) **allowlist match** — pipe a `.ts`/`.py`/`.sql` path into `source_files_from_stdin` → assert each is returned as source; (b) **markdown-only via inverse** — feed a docs-only file list to `is_markdown_only` → assert `MD_ONLY=1`, and confirm the verdict is the *inverse of source-classification*, NOT `grep -v '\.md$'` (feed `config/app.yaml` alone → assert `MD_ONLY=1`, proving `.yaml` is not treated as source per D19); (c) **`.sql` boundary** — a `.sql`-only diff → `is_source_change` non-empty, `is_markdown_only` = `MD_ONLY=0` (D19 in); a `.yaml`/`Dockerfile`-only diff → `is_source_change` empty, `MD_ONLY=1` (D19 out); (d) **cross-consumer agreement** — run the SAME mixed diff (`migrations/x.sql` + `config/y.yaml`) through the Stop hook path, the autopilot Step 3 guard, the qa-expert guard, and `check-docs-fresh.sh`; assert all four produce identical source/markdown-only verdicts (this is the drift the library exists to kill — pre-refactor they disagreed, D17); (e) **missing-library fail-safe** — with the lib removed, assert the Stop hook still exits 0 (fail-open) and the autopilot/qa-expert guards still emit a verdict via their inline fallback; (f) **explicit-stdin no-hang contract (Item 2)** — invoke `source_files_from_stdin` with stdin that is neither a tty nor a pipe (e.g. `source_files_from_stdin < /dev/null` and via a redirected here-string) and assert it returns promptly (empty for empty input) and NEVER blocks; assert `is_source_change` / `is_markdown_only` (which pipe `collect_changed_files` in) also return promptly, proving no function sniffs `[ -t 0 ]`. `bash -n` + `shellcheck` the library (covered by #1).

## Success Criteria

- **SC1 (Phase 1):** `/autopilot <task>` with no flag behaves exactly as today (stops at local branch, nothing pushed) AND now runs the reviewer between implement and docs, recording a verdict. `/review` returns a structured report on demand.
- **SC2 (Phase 1):** `/autopilot --deliver <task>` commits (Conventional Commit, verified no AI-attribution trailer), pushes, and opens a PR whose body contains Goals, Test summary, and Rollback; draft iff blockers/red.
- **SC3 (Phase 1):** `/implement` in an empty non-project dir refuses and redirects to `/build-plan`/`/autopilot`; in a real project it is unchanged.
- **SC4 (Phase 2):** A newly scaffolded Node or Python project receives a working `.github/workflows/ci.yml`; a forced CI failure triggers a bounded heal loop that terminates in ≤3 attempts with a recorded outcome.
- **SC5 (Phase 2):** The verify gate starts the actual artifact and records pass/fail; a committed secret is blocked unconditionally; dependency advisories are recorded but non-blocking absent `--strict-security`.
- **SC5b (Phase 2):** The stale-docs CI gate blocks a PR that changes source files without touching any doc surface (`README.md`/`CLAUDE.md`/`docs/**`/`.env.example`), passes when docs are updated alongside source, passes trivially on markdown-only/docs-only PRs, and passes when `[skip-docs]` is present in a commit message or the PR body — with the failure message naming the changed source files and printing how to use the escape. The single `check-docs-fresh.sh` script is invoked by all three CI templates without duplicated logic. **The gate runs correctly on a CI runner with NO `$HOME/.claude` install**, because the scaffold vendors both `check-docs-fresh.sh` and `classify-changes.sh` into the generated repo under `.github/scripts/` and the gate resolves its classifier repo-relative (D20); it exits non-zero only if even the vendored sibling is missing.
- **SC5c (Phase 2):** There is exactly **one** definition of the source-code boundary *in this repo* — `.claude/lib/classify-changes.sh` — and the Stop hook, autopilot Step 3 guard, qa-expert scope guard, and the in-repo template gate all consume it. On a shared test corpus of diffs (including the mixed `.sql`+`.yaml` case), all four consumers return identical source/markdown-only verdicts; `grep -v '\.md$'` no longer appears as a source classifier in autopilot or qa-expert (only as a documented missing-library fallback). A missing library fails safe (Stop hook fail-open; CI gate hard-errors). The library exposes an explicit-stdin contract (`source_files_from_stdin` reads stdin only) with no `[ -t 0 ]` mode-sniffing, so no function can hang on `cat` (Item 2). The vendored downstream copy (D20) is a deliberate snapshot and is out of scope for THIS repo's single-source-of-truth count.
- **SC6 (Phase 3):** Ambiguous asks produce `## Acceptance Criteria`/`## Out of Scope`/`## Success Metrics` that qa-expert and reviewer consume; each agent runs on its assigned model tier; each completed run appends privacy-safe JSONL telemetry; the deploy/monitor sketch is documented with `scripts/deploy.sh`/`scripts/errors.sh` conventions and no provider logic.
- **SC7 (all):** Every embedded bash block passes `bash -n` and runs identically under Git Bash/macOS/Linux for the fixture inputs. **`docs/architecture.md` is updated in every phase** (Item 3) to reflect the reviewer agent + `/review`, the delivery stage + `--deliver`/`--deploy`, the CI templates + gates (including the vendored docs-freshness gate), the shared classification library, the verify/security steps, model tiering, and telemetry — so the architecture doc never drifts behind the very features this plan ships (doubly required for a plan that itself ships a stale-docs gate).

## Review Feedback — 2026-07-12 (changes requested, status stays draft)

Raised during `/review-plan PLAN-004`. Address these before the plan advances to `approved`.

### Must-fix (real bugs that surface on first use)

1. **CI gate sources a library absent on the CI runner.** `check-docs-fresh.sh` (2.6) is vendored into the *generated project* and runs on a GitHub Actions runner with no Claude Code install, so `$HOME/.claude/lib/classify-changes.sh` does not exist there. The current fail-safe (exit 2 on missing lib, line ~356/531) makes the gate hard-fail on *every real CI run*. Fix: the engineer scaffold step (2.1) must **vendor both `check-docs-fresh.sh` and `classify-changes.sh`** into the generated repo (e.g. `.github/scripts/`), and the gate must source the vendored copy by a **repo-relative path**, not `$HOME`. Acknowledge and address the resulting drift between `~/.claude/lib` (dev machine) and the vendored downstream copy — this is an accepted but currently-unstated tradeoff of CI isolation. → RESOLVED (new **D20**; scaffold vendors both scripts under `.github/scripts/` in §2.1 and P2-7; `check-docs-fresh.sh` now resolves the lib repo-relative via `SCRIPT_DIR` with `CLASSIFY_LIB` override and `$HOME` local-dev fallback in §2.6; §2.5 consumer #4 + fail-safe bullet updated; Affected Components/Templates; Risks rows (missing-lib + new "hard-fails on CI" + "snapshot lags" rows); Testing #9(f)/(g); SC5b/SC5c).
2. **`is_source_change` can hang on `cat`.** The `[ -t 0 ]` dual-mode (lines ~306–309) runs `cat` when stdin is neither a tty nor a pipe (common in subagent/command/CI contexts), blocking forever on EOF. Replace the tty-sniffing with an explicit contract (an argument, or two distinct functions: one that collects, one that filters stdin). → RESOLVED (§2.5 library redesigned: `collect_changed_files`, new stdin-only `source_files_from_stdin` (always `cat`s stdin, no `[ -t 0 ]`), `is_source_change` = collect→filter wrapper, `is_markdown_only` via same path; WHY comment added; §2.6 gate + Testing #9/#10 rewired to `source_files_from_stdin`; Testing #10(f) asserts no-hang; SC5c).

### Should-fix

3. **`docs/architecture.md` is never updated.** P1-8 / P2-15 / P3-6 update README + CLAUDE.md but omit `docs/architecture.md`, which this plan materially changes (reviewer, delivery, CI gates, shared library, telemetry). Add it as a doc target in each phase — doubly required for a plan that ships a stale-docs gate. → RESOLVED (added `docs/architecture.md` to P1-8, P2-15, P3-6 with per-phase content notes; added to Affected Components/Docs; extended SC7).
4. **CI-heal (4.6) bypasses every gate.** Heal-loop commits skip reviewer (2.5), verify (3.5), and the always-blocking secret scan (3.6), which can push an un-reviewed change or a secret to the remote. At minimum, re-run the secret scan on heal commits so the "unconditionally blocking" guarantee (D6) holds for code the loop itself produces. → RESOLVED (§2.2 heal loop re-runs the always-blocking secret scan on each heal diff BEFORE push; a hit aborts with `CI-HEAL=ABORTED-secret-detected`, never pushed; reviewer/verify intentionally NOT re-run, rationale stated; D4 amended; P2-11 updated; two Risks rows added/updated).
5. **Mid-pipeline start behavior unspecified.** State explicitly whether Deliver (4.5) and CI-heal (4.6) run when `/autopilot-from` starts at `test`/`docs`. → RESOLVED (D1 extended: Deliver + CI-heal are flag-gated not stage-gated — they run on a `test`/`docs` resume if `--deliver`/`--deploy` present; only Review 2.5 is skipped; echoed in §1.4, §2.2, P1-5, P2-11).

### Minor

6. Prose says source `~/.claude/lib/...`; inside quotes `~` does not expand — implementation must use `$HOME` consistently (code blocks mostly do; make it uniform). → RESOLVED (§2.5 consumers #2/#3 and steps P2-2/P2-3/P2-4 now specify the `. "$HOME/.claude/lib/classify-changes.sh"` source form and explicitly note quoted `~` does not expand; unquoted `~/.claude/` remains only in prose install-location references, which are documentation not source lines).
7. `settings.local.json` needs new allowlist entries for `gh` / `git push` / `git commit` or every `--deliver` run prompts. → RESOLVED (P1-7 adds allowlist entries for `gh *`, `git push:*`, `git commit:*`; noted in Affected Components/Installer-config).
8. `git push` (line ~196) runs unconditionally after a "nothing to commit" branch — guard it. → RESOLVED (§1.4 Deliver block now pushes only when `git commit` created a commit, or (on a resume) when the branch is ahead of upstream via `git rev-list --count @{upstream}..HEAD`; never on a clean fully-pushed branch; P1-5 notes the guarded push).
9. Add a cross-reference note to **PLAN-003**: D18 redefines the *implementation* of "markdown-only" that PLAN-003 introduced (the intent is preserved, so this is a cross-ref, not a supersession). → RESOLVED (D18 gains a "Cross-reference to PLAN-003 (NOT a supersession)" paragraph — implementation redefined, intent preserved, PLAN-003 keeps its status and gains no `superseded_by`).

## Self-Review Notes

Issues caught and fixed during self-review:

1. **Reviewer wiring ambiguity.** Initially considered adding reviewer to the Stop hook alongside qa/doc. Caught that the Stop hook runs its two agents *in parallel* on source-file changes, which cannot express "review must gate before docs and loop with the engineer." Moved reviewer to an explicit ordered autopilot step (Step 2.5) and added a separate `/review` manual command; recorded the rejected option in A2. Confirmed `.claude/settings.json` needs no change.
2. **"Block" vs. hands-free contract.** First draft had `blocker` findings halting autopilot — which would strand a hands-free run. Reconciled via D3: blockers dispatch a bounded fix loop (cap 2), then proceed with a draft PR. This preserves both "never stop" and "don't ship blockers silently."
3. **Flag pollution of project-name derivation.** Realized `--deliver` in `$ARGUMENTS` would flow into the Step 0 auto-name derivation (`autopilot.md` lines 36–47) and corrupt the generated directory name. Added explicit flag-stripping before name/task derivation (P1-5) and a fixture test (Testing Strategy #4).
4. **CI heal ordering.** Placed CI-heal (Step 4.6) *after* Deliver (Step 4.5), since there is no remote CI to read until something is pushed. Guarded it to run only when Deliver actually pushed; otherwise it is a no-op.
5. **Secret-scan asymmetry.** Made secret detection unconditionally blocking even though the rest of the security gate is advisory (D6), because a pushed secret is unrecoverable — the one place where blocking a hands-free run is justified.
6. **No-placeholder rule vs. CI scaffold TODOs.** The generic CI template contains scaffold slots for the end user to fill. Clarified (D12) that the house no-placeholder rule governs *this repo's implementation code*, not scaffold placeholders emitted into a *generated* project for a human to complete — otherwise a generic template is impossible.
7. **Telemetry privacy.** Tightened D10 to structural facts only (no diffs/code/task text) and added a privacy assertion to the Testing Strategy (#7).
8. **Verify brittleness.** Downgraded real-run verification to advisory in autopilot (D5) after recognizing environment variance (ports, env, external deps) would make hard-blocking too flaky for hands-free mode; kept it blocking only in the interactive `/verify`.
9. **Bootstrap-block divergence.** Flagged the three-copy risk of the detection block and added a byte-identity test (Testing Strategy #3) rather than pretending a copy stays in sync by good intentions.
10. **Fable 5 assignment.** Explicitly did NOT assign Fable 5 to any SDLC agent (D9) and documented why — it is a creative tier, wrong tool for code/reasoning gates — rather than tiering an agent onto it just because the ID exists.
11. **Stale-docs gate — verification not authoring.** Added the stale-docs CI gate to Phase 2 (D13–D16, script `check-docs-fresh.sh` called by all three CI templates). Kept it strictly a *verification* net at CI time — it never writes docs, leaving `doc-maintainer` (autopilot Step 4) as the sole author, so it complements rather than duplicates the inner loop. Chose the `[skip-docs]` token over a PR label specifically for portability (the standalone script reads `git log`, no provider API), and made the gate blocking-but-deterministic, contrasting the rationale explicitly with the advisory security gate (D6) and the always-blocking secret scan. **The 4th-copy concern flagged here originally is now RESOLVED:** rather than copy the source-extension set into `check-docs-fresh.sh` (a fourth definition adjacent to the D11 bootstrap-block divergence risk), Phase 2 now *extracts* the definition into a shared library `.claude/lib/classify-changes.sh` (D17) as its first step, and the gate sources it — so there is no fourth copy, and the two pre-existing contradictory framings (allowlist vs. `grep -v '\.md$'`, D17) are collapsed to one (D18). This also retires the "out of scope, NG6" deferral: the refactor is now in scope and lands before the gate. **Residual concern:** the command/agent markdown files source the library via an absolute `. "$HOME/.claude/lib/classify-changes.sh"` path, which couples them to the install layout — if a user relocates `$HOME/.claude`, the source fails and the consumers drop to their inline fallback (behavior-preserving but no longer single-sourced). Mitigated by the fail-safe (Risks) and by `install.sh` owning the path; a fully install-location-agnostic resolution (e.g. an env var like `CLASSIFY_LIB`, already honored by the CI gate) is a possible future refinement.
12. **Unifying the framings is a real behavior change, stated as such.** Recognized that collapsing allowlist vs. blocklist (D18) is not purely a refactor: `.yaml`/config-only diffs stop triggering qa-expert in autopilot, and `.sql`-only diffs start triggering qa/docs everywhere (D19). Rather than hide this, made it explicit decisions (D18/D19), a Risks row, and a cross-consumer agreement test (Testing Strategy #10) so the new behavior is intentional and verified consistent across all four consumers — the exact drift the library exists to eliminate.
13. **Revision round (2026-07-12) resolving the 9 review-feedback items.** Two real bugs were fixed: (a) the CI docs-gate would have hard-failed *every* real CI run because it sourced `$HOME/.claude/lib` on a runner with no Claude install — resolved by vendoring both `check-docs-fresh.sh` and `classify-changes.sh` into the generated repo under `.github/scripts/` and resolving the classifier repo-relative (new **D20**); (b) the classifier's `[ -t 0 ]` tty-sniffing could hang on `cat` — resolved by an explicit stdin-only contract (`source_files_from_stdin`) with no mode-guessing. Should-fix/minor items added `docs/architecture.md` as a per-phase doc target, made the always-blocking secret scan re-run inside the CI-heal loop, pinned down mid-pipeline start semantics (Deliver/CI-heal are flag-gated, not stage-gated), swept `~`→`$HOME` in library-source lines, added the `gh`/`git push`/`git commit` allowlist entries, guarded the Deliver push against a no-op commit, and cross-referenced PLAN-003 (implementation redefined, intent preserved, no supersession). **Residual concern (accepted, D20):** the vendored downstream classifier is a deliberate SNAPSHOT that can lag the source `classify-changes.sh` on the dev machine — a generated repo pins its own gate logic and does not track `~/.claude/lib` edits. The refresh path is re-scaffolding (or a future `--update-scaffold` pass) that re-copies the current scripts into `.github/scripts/`. This is intentional CI-isolation and does not reintroduce D17 drift *within this repo* (this repo's four consumers still resolve to one file), but the snapshot-staleness window is a real tradeoff a downstream maintainer should know about, and a future refinement could stamp the vendored copy with a version/source-hash so drift is detectable. Status remains **draft** — a human re-reviews; this round does not self-approve.
