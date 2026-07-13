AUTOMODE — Resume the autopilot pipeline from a specific stage for: $ARGUMENTS

## Flag Parsing (run first)

`$ARGUMENTS` may contain delivery flags mixed into the stage keyword and task description. Strip them FIRST, before parsing the stage. Run this block with the raw `$ARGUMENTS` string as `$1`:

```bash
# Inputs: the raw $ARGUMENTS string. Recognized flags may appear anywhere in it.
# WHY strip before stage/task derivation: flags must not be mistaken for the
# stage keyword, and must not leak into the Step 0 auto-derived project name.
RAW_ARGS="$1"
DELIVER=0
DEPLOY=0
STRICT_SECURITY=0
TASK=""
# WHY set -f: the unquoted $RAW_ARGS word-split is intentional, but without
# noglob a task containing * or ? would expand to cwd filenames and corrupt
# the stage/task text (and the Step 0 auto-derived project name).
set -f
for word in $RAW_ARGS; do
  case "$word" in
    --deliver)         DELIVER=1 ;;
    --deploy)          DEPLOY=1; DELIVER=1 ;;  # --deploy implies --deliver
    --strict-security) STRICT_SECURITY=1 ;;
    *)                 TASK="$TASK $word" ;;
  esac
done
set +f
TASK=${TASK# }
echo "DELIVER=$DELIVER"
echo "DEPLOY=$DEPLOY"
echo "STRICT_SECURITY=$STRICT_SECURITY"
echo "TASK=$TASK"
```

`DELIVER=1` activates Step 4.5 (and Step 4.6 when something is pushed). `STRICT_SECURITY=1` upgrades Step 3.6 dependency advisories from advisory to delivery-blocking. `DEPLOY=1` currently only implies `--deliver`; the deploy stage itself is a documented design sketch — project-provided `scripts/deploy.sh` after a human merge, `scripts/errors.sh` feeding the next bugfix plan; no daemon, no scheduler, no provider SDKs, no auto-merge (see "Deploy & Monitor" in the `/autopilot` command and the README) — not an implementation. Without a flag, this pipeline never touches a remote — the upfront flag IS the confirmation, so the run stays hands-free either way.

Parse the FIRST word of `TASK` (the flag-stripped remainder) to determine the starting stage. The rest is the task description or plan reference.

**Stage keywords** (case-insensitive):
- `plan` → Start from Step 1 (Plan → Implement → Review → Test → Verify → Security → Docs)
- `implement` → Start from Step 2 (Implement → Review → Test → Verify → Security → Docs). Requires a plan ID like PLAN-001.
- `test` → Start from Step 3 (Test → Verify → Security → Docs). Assumes code is already written and reviewed.
- `docs` → Start from Step 4 (Docs only). Assumes code and tests are done. When `--deliver`/`--deploy` was passed, the Step 3.6a secret scan still runs before Step 4.5 (see the Deliver precondition) — the always-blocking guarantee is unconditional.

**Stage-skipping vs. flag-gating:** only Review (Step 2.5) is stage-skipped — a `test` or `docs` start has nothing new to review. Deliver (Step 4.5) and CI Heal (Step 4.6) are flag-gated, NOT stage-gated: a run resumed at `test` or `docs` still delivers and heals CI when `--deliver`/`--deploy` was passed, because a resumed run must be able to ship.

**Examples:**
- `/autopilot-from plan add user authentication` → full pipeline
- `/autopilot-from implement PLAN-003` → skip planning, implement from existing plan
- `/autopilot-from test PLAN-003` → skip planning and coding, run tests and docs
- `/autopilot-from test PLAN-003 --deliver` → tests + docs, then commit, push, and open a PR
- `/autopilot-from docs` → only update documentation for recent changes

---

## Telemetry (helper used by the gates below)

Each gate appends one JSONL line to `$HOME/.claude/telemetry/sdlc.jsonl`. Wherever a step says "emit telemetry", run this block with `$1` = stage, `$2` = outcome, and optionally `$3` = an extra JSON fragment. A step that never executes emits nothing; steps told to record an explicit skip emit that skip outcome.

```bash
# Inputs: $1 = stage (plan|review|test|verify|security|deliver|ci-heal),
#         $2 = outcome (a short structural keyword, e.g. success, approved,
#              blockers-remaining, pass, skipped-markdown-only),
#         $3 = optional extra JSON fragment of already-formed pairs, e.g.
#              "plan_id":"PLAN-007","iterations":1  (no surrounding braces/comma).
# PRIVACY (hard rule): record only structural facts — timestamps, stage names,
# outcomes, counts, plan IDs, the project basename. NEVER diffs, code, task
# descriptions, file paths, or error text.
emit_metric() {
  TELEM_DIR="$HOME/.claude/telemetry"
  # WHY every failure path ends in `|| :`: telemetry is an observability
  # side-channel; an unwritable $HOME (read-only mount, quota) must never
  # fail the pipeline over a metrics line.
  mkdir -p "$TELEM_DIR" 2>/dev/null || :
  # WHY tr: a quote, backslash, or control char in a directory name must not
  # corrupt the JSONL — one malformed line breaks every future read of the file.
  # WHY 2>/dev/null on tr: GNU tr warns about the trailing backslash escape on
  # some execution layers; the warning is stderr noise, never wrong output.
  proj=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | tr -d '\000-\037"\\' 2>/dev/null)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # WHY 2>/dev/null BEFORE >>: redirections process left to right; if the append
  # target is unwritable, the shell's diagnostic must already be silenced.
  printf '{"ts":"%s","project":"%s","stage":"%s","outcome":"%s"%s}\n' \
    "$ts" "$proj" "$1" "$2" "${3:+,$3}" 2>/dev/null >> "$TELEM_DIR/sdlc.jsonl" || :
}
emit_metric "$1" "$2" "$3"
```

Cycle time is derived at read-time — the `plan` line's `ts` to the same run's last line — nothing is computed here.

---

## Step 0: Bootstrap Detection (only when starting stage is `plan`)

If the starting stage is `plan`, run bootstrap detection BEFORE creating the sentinel — same logic as `/autopilot` Step 0. For starting stages `implement`, `test`, `docs`, SKIP this section entirely and create the sentinel as today (the block below this section).

When starting stage is `plan`:

```bash
# Detect "non-project" cwd.
# Trigger conditions (ALL must be true):
#   - no recognized manifest in cwd
#   - no .git directory
#   - fewer than 3 non-hidden top-level entries

NEEDS_BOOTSTRAP=0
if [ ! -f package.json ] && [ ! -f pyproject.toml ] && [ ! -f go.mod ] && [ ! -f Cargo.toml ] && [ ! -d .git ]; then
  # Count non-hidden top-level entries (files + dirs, not dotfiles).
  entry_count=$(ls -1 2>/dev/null | wc -l | tr -d ' ')
  if [ "${entry_count:-0}" -lt 3 ]; then
    NEEDS_BOOTSTRAP=1
  fi
fi
echo "NEEDS_BOOTSTRAP=$NEEDS_BOOTSTRAP"
```

**If `NEEDS_BOOTSTRAP=0`:** Skip to sentinel creation below.

**If `NEEDS_BOOTSTRAP=1`:** Auto-derive the project name from the task description portion of `TASK` (the flag-stripped remainder from Flag Parsing, everything after the `plan` keyword), passed as `$1`:

```bash
# Inputs: the raw $ARGUMENTS string passed to /autopilot.
DESCRIPTION="$1"
NAME=$(printf '%s' "$DESCRIPTION" \
  | cut -d' ' -f1-4 \
  | tr '[:upper:]' '[:lower:]' \
  | tr ' _' '--' \
  | sed -E 's/[^a-z0-9-]//g; s/-+/-/g; s/^-+//; s/-+$//')
if [ -z "$NAME" ]; then
  NAME="new-project"
fi
echo "AUTO_NAME=$NAME"
```

Read `AUTO_NAME` and feed it as `$1` to the bootstrap execution block:

```bash
# Sanitize the proposed name. Pipeline:
#   lowercase -> spaces/underscores to hyphens -> strip everything outside
#   [a-z0-9-] -> collapse runs of hyphens -> trim leading/trailing hyphens.
PROPOSED_NAME="$1"  # passed in by Claude after prompt or auto-derivation
SANITIZED=$(printf '%s' "$PROPOSED_NAME" \
  | tr '[:upper:]' '[:lower:]' \
  | tr ' _' '--' \
  | sed -E 's/[^a-z0-9-]//g; s/-+/-/g; s/^-+//; s/-+$//')

if [ -z "$SANITIZED" ]; then
  echo "ERROR: project name produced empty string after sanitization"
  exit 1
fi

if [ -e "$SANITIZED" ]; then
  echo "ERROR: ./$SANITIZED already exists"
  exit 1
fi

mkdir "$SANITIZED"
cd "$SANITIZED"
git init -q -b main 2>/dev/null || git init -q  # -b main on git >=2.28; fallback for older
# If git defaulted to master, rename to main for consistency
current=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")
if [ "$current" = "master" ]; then
  git branch -M main
fi

cat > .gitignore <<'EOF'
node_modules/
dist/
build/
__pycache__/
*.pyc
.env
.env.local
.DS_Store
.claude/.autopilot-active
.claude/.autopilot-finished
.claude/settings.local.json
EOF

# Verify git identity is configured before attempting the initial commit.
# Without this guard, `git commit` on a fresh machine fails with
# "Please tell me who you are" — which is opaque inside an automated pipeline.
if ! git config --get user.email >/dev/null 2>&1 || ! git config --get user.name >/dev/null 2>&1; then
  echo "ERROR: git identity not configured."
  echo "Run: git config --global user.email \"you@example.com\" && git config --global user.name \"Your Name\""
  echo "Then retry the command. The directory ./$SANITIZED has been created — delete it with: cd .. && rm -rf $SANITIZED"
  exit 1
fi

git add .gitignore && git commit -q -m "Initial commit"
echo "BOOTSTRAPPED=$SANITIZED"
pwd
```

Read `pwd`. The new directory is the project root for all subsequent steps. If bootstrap failed, surface the error and stop (the sentinel was never created — nothing to clean up).

---

**IMPORTANT — Sentinel file:** Now (in the possibly-new cwd) create `.claude/.autopilot-active` to prevent the Stop hook from double-triggering. At the end of the run (Step 5), the cleanup replaces it with a `.claude/.autopilot-finished` marker that the hook consumes on its next fire to save the run's fingerprint — this covers single-turn runs where the hook never fires while the sentinel exists. Note: stale sentinels older than 2 hours are auto-cleaned by the Stop hook, so a crash won't permanently block agent triggers.

```bash
mkdir -p .claude && touch .claude/.autopilot-active
```

Execute ALL steps from the starting stage through the end. Do NOT stop between steps. Do NOT ask for confirmation.

---

## Step 1: Plan with self-review (skip if starting after this stage)

Delegate to the **planner** subagent. The "AUTOMODE" keyword above tells it to operate in auto mode:
- Read the codebase, make best-judgment decisions
- Write the plan to `./docs/plans/` (relative to project root, NOT ~/.claude/), document assumptions, self-review, fix issues
- Set status to `approved`

Read the plan back. You need it for Step 2. Emit telemetry: the Telemetry block with `plan` `success` and extra `"plan_id":"PLAN-{NNN}"`.

### Step 1.5: Plan Validation (skip if starting after plan stage)

After the planner finishes, YOU (the main agent) also review the plan:
- Does it address the original request?
- Are steps concrete enough for the engineer?
- Any gaps or contradictions?
- Fix issues in the plan before proceeding.

## Step 1.75: Branch Creation (only when starting stage is `plan` or `implement`)

**Skip this step entirely when starting stage is `test` or `docs`.** Those stages assume code is already written on the user's chosen branch and must not auto-checkout anything.

When starting stage is `plan` or `implement`, run the branch-creation block below with the resolved plan file path passed as `$1`. For starting stage `implement`, the plan path is derived from the PLAN-NNN argument (glob `./docs/plans/PLAN-NNN-*.md`). For starting stage `plan`, the plan path is the file the planner just wrote in Step 1.

```bash
# Inputs: the plan file path, e.g. ./docs/plans/PLAN-001-add-auth.md
PLAN_FILE="$1"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "BRANCH_ACTION=skip-not-in-repo"
  exit 0
fi

current_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$current_branch" != "main" ] && [ "$current_branch" != "master" ]; then
  echo "BRANCH_ACTION=skip-already-on-feature:$current_branch"
  exit 0
fi

# Parse plan frontmatter for id and type.
# Frontmatter is between two lines of exactly '---'. The tr pipeline strips
# any surrounding single or double quotes so `type: "feature"` and
# `type: feature` both parse identically; lowercasing on type lets
# `type: Bugfix` map correctly.
plan_id=$(awk '/^---$/{f++; next} f==1 && /^id:/ {print $2; exit}' "$PLAN_FILE" | tr -d '"' | tr -d "'")
plan_type=$(awk '/^---$/{f++; next} f==1 && /^type:/ {print $2; exit}' "$PLAN_FILE" | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]')

if [ -z "$plan_id" ] || [ -z "$plan_type" ]; then
  echo "ERROR: could not parse id/type from $PLAN_FILE frontmatter"
  exit 1
fi

# Derive slug from filename: PLAN-001-add-auth.md -> add-auth
plan_basename=$(basename "$PLAN_FILE" .md)
slug=$(printf '%s' "$plan_basename" | sed -E "s/^${plan_id}-//")
# WHY: no case-insensitive flag — plan IDs are always uppercase ("PLAN-001") and
# filenames match. The GNU sed -I flag is unsupported on BSD sed (macOS), so
# omitting it keeps this portable across Git Bash on Windows and macOS/Linux.

case "$plan_type" in
  feature|design) prefix="feature" ;;
  bugfix)        prefix="fix" ;;
  refactoring)   prefix="refactor" ;;
  *)             prefix="feature" ;;
esac

target_branch="${prefix}/${plan_id}-${slug}"

if git rev-parse --verify "$target_branch" >/dev/null 2>&1; then
  echo "ERROR: branch $target_branch already exists"
  echo "Resolution: delete the old branch (git branch -D $target_branch) or supersede the plan with a new ID."
  exit 2
fi

git checkout -b "$target_branch"
echo "BRANCH_ACTION=created:$target_branch"
```

Read `BRANCH_ACTION`:
- `skip-not-in-repo` or `skip-already-on-feature:*` → continue silently to Step 2.
- `created:*` → continue to Step 2 and mention in the final summary.
- exit 2 (branch exists) → STOP the pipeline. **Before exiting, remove the autopilot sentinel** so subsequent runs aren't blocked:

```bash
rm -f .claude/.autopilot-active
```

Then surface the error message verbatim and stop.

## Step 2: Implement (skip if starting after this stage)

Delegate to the **engineer** subagent:
- If a plan ID was specified (e.g., PLAN-003), read that plan from `/docs/plans/`
- If coming from Step 1, use the plan just created
- Read the existing codebase to understand patterns and conventions
- Implement everything with production-grade quality
- Update the plan status to `implemented`

## Step 2.5: Review (skip when starting stage is `test` or `docs`)

**Skip this step entirely when the starting stage is `test` or `docs`** — those resumes carry nothing new to review. This is the ONLY step that is stage-skipped; Deliver (Step 4.5) remains flag-gated and still runs on a `test`/`docs` resume when `--deliver`/`--deploy` was passed.

When starting stage is `plan` or `implement`, delegate to the **reviewer** subagent to adversarially critique the Step 2 diff before tests run:
- It reviews the working-tree diff (`git diff HEAD` plus untracked files) against `.claude/CLAUDE.md` standards and the plan's `## Acceptance Criteria` (if present)
- Its final output line is machine-readable: `REVIEW_VERDICT=approve BLOCKERS=0` or `REVIEW_VERDICT=changes-requested BLOCKERS=<n>`

Parse that final line and apply the bounded fix loop:

1. `REVIEW_VERDICT=approve` (or `BLOCKERS=0`) → record `review: approved` and continue to Step 3.
2. Otherwise, delegate to the **engineer** subagent with the reviewer's **Blockers** list as the fix brief — fix ONLY the listed blockers, no scope creep — then delegate to the reviewer again and re-parse its final line.
3. Hard cap: at most **2** fix/re-review iterations after the initial review. If blockers remain after the cap, record `review: blockers-remaining` and continue to Step 3 anyway — a hands-free pipeline must terminate. This outcome feeds the Step 5 summary and, when `--deliver` was passed, makes Step 4.5 open the PR as a **draft** with the remaining blockers listed in the body.

WHY the loop lives in this command and not in the reviewer agent: agents are stateless single-shot subagents; orchestration and loop caps belong in the command layer, exactly as the branch-creation retry budget lives in the calling command rather than in the engineer.

Emit telemetry: the Telemetry block with `review`, the recorded outcome (`approved`, `approved-after-fixes`, or `blockers-remaining`), and extra `"iterations":<0-2>,"blockers":<n>`.

## Step 3: Test (skip if starting after this stage)

Before delegating to qa-expert, run:

```bash
# "Markdown-only" = the change set contains no source files, judged by the
# shared classifier's allowlist (single source of truth — PLAN-004 D17/D18).
if [ -f "$HOME/.claude/lib/classify-changes.sh" ]; then
  . "$HOME/.claude/lib/classify-changes.sh"
  is_markdown_only || :  # MD_ONLY=0 returns 1 by design; not a command failure
else
  # Transitional fallback for installs predating ~/.claude/lib: the historical
  # inline blocklist check. Re-run install.sh to pick up the shared library.
  non_md=$(git diff --name-only HEAD; git ls-files --others --exclude-standard)
  if printf '%s\n' "$non_md" | grep -v '\.md$' | grep -q .; then
    echo "MD_ONLY=0"
  else
    echo "MD_ONLY=1"
  fi
fi
```

If `MD_ONLY=1`, skip Step 3 entirely — do NOT delegate to qa-expert — and proceed directly to Step 4 (Document). Record this in the Step 5 summary as `Tests: skipped (markdown-only)`.

If `MD_ONLY=0`, delegate to qa-expert as normal (the existing instructions below).

Delegate to the **qa-expert** subagent:
- Review all recently changed code (use `git diff` to identify)
- Write comprehensive test cases covering normal paths, edge cases, and error conditions
- Run the test suite to verify everything passes
- If tests fail, fix the code or tests until green
- Check eval coverage if `evals/` exists

Emit telemetry: the Telemetry block with `test` and the outcome — `pass`, `fail`, or `skipped-markdown-only` (when Step 3 was bypassed).

## Step 3.5: Verify (real-run, advisory)

Distinct from Step 3's unit tests: this step starts the actual artifact once and confirms it behaves. It is ADVISORY in autopilot — record `verify: pass|fail|not-applicable` for the Step 5 summary and ALWAYS continue to Step 3.6, whatever the outcome. Environment variance (ports, env vars, external services) makes hard-blocking too brittle for a hands-free run; the blocking variant is the manual `/verify` command. A `fail` outcome downgrades a `--deliver` PR to a draft in Step 4.5c.

Detect the run surface from the manifest, the plan, and the README — first match wins:

1. **HTTP server** — a start script or entry point that serves HTTP (e.g. `npm start` on an Express app, `uvicorn`/`flask run`). Use the server block below with the start command and a health or root URL.
2. **CLI** — the project ships a command-line entry point. Use the CLI block below with `--help` (or a documented subcommand); exit 0 = pass.
3. **Library** — no run surface of its own. Write the README usage example to a scratch file under `${TMPDIR:-/tmp}`, run it via the CLI block, then delete the scratch file.
4. **Nothing detectable** — record `verify: not-applicable` and continue. Do not invent a probe.

HTTP-server surface:

```bash
# Inputs: $1 = start command (e.g. "npm start"),
#         $2 = URL to probe (e.g. "http://127.0.0.1:3000/health").
START_CMD="$1"
PROBE_URL="$2"
VERIFY_TIMEOUT=30

command -v curl >/dev/null 2>&1 || { echo "VERIFY=not-applicable (no curl)"; exit 0; }

SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; }
# WHY trap EXIT too: the started process must die in ALL paths — success,
# probe failure, or an unexpected error mid-block. Never leak a server.
trap cleanup EXIT INT TERM

sh -c "$START_CMD" >/dev/null 2>&1 &
SERVER_PID=$!

elapsed=0
while [ "$elapsed" -lt "$VERIFY_TIMEOUT" ]; do
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$PROBE_URL" 2>/dev/null)
  case "$http_code" in
    2??) echo "VERIFY=pass"; exit 0 ;;
  esac
  # The server died before answering — no point waiting out the clock.
  kill -0 "$SERVER_PID" 2>/dev/null || { SERVER_PID=""; break; }
  sleep 2
  elapsed=$((elapsed + 2))
done
echo "VERIFY=fail"
exit 0
```

CLI / library surface:

```bash
# Inputs: $1 = the invocation to probe (e.g. "node dist/cli.js --help",
#         "python -m mytool --help", "sh /tmp/readme-example.sh").
CLI_CMD="$1"
VERIFY_TIMEOUT=30

sh -c "$CLI_CMD" >/dev/null 2>&1 &
CLI_PID=$!
# WHY trap: if this block is interrupted mid-wait, the probe must not outlive it.
trap 'kill "$CLI_PID" 2>/dev/null' EXIT INT TERM

# WHY a poll loop instead of `timeout`: coreutils timeout does not exist on
# stock macOS; kill -0 polling is POSIX-portable across Git Bash/macOS/Linux.
elapsed=0
while kill -0 "$CLI_PID" 2>/dev/null && [ "$elapsed" -lt "$VERIFY_TIMEOUT" ]; do
  sleep 1
  elapsed=$((elapsed + 1))
done

if kill -0 "$CLI_PID" 2>/dev/null; then
  # Still running after the budget — a CLI probe should exit quickly.
  kill "$CLI_PID" 2>/dev/null
  echo "VERIFY=fail (timeout after ${VERIFY_TIMEOUT}s)"
  exit 0
fi

if wait "$CLI_PID"; then
  echo "VERIFY=pass"
else
  echo "VERIFY=fail (exit $?)"
fi
exit 0
```

Record the `VERIFY=` line for Step 5 and the Step 4.5c draft decision, emit telemetry — the Telemetry block with `verify` and the recorded outcome (`pass`, `fail`, or `not-applicable`) — then continue.

## Step 3.6: Security

Three checks, strictly in this order. Only the secret scan can block. Record a single outcome for Step 5: `security: pass|advisories|BLOCKED-secret`.

### Step 3.6a: Secret scan (ALWAYS BLOCKING)

```bash
# Scans everything this run could deliver — the tracked diff's added lines plus
# untracked files — for known credential shapes. WHY always blocking even though
# the rest of this step is advisory: a pushed secret is unrecoverable (it must
# be rotated); the asymmetry of harm justifies the one unconditional hard block
# in a hands-free pipeline.
SECRET_PATTERN='AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[bp]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AIza[0-9A-Za-z_-]{35}|ya29\.[0-9A-Za-z_-]+'

tracked_hits=$(git diff HEAD 2>/dev/null | grep -E '^\+' | grep -E -c "$SECRET_PATTERN")
# WHY core.quotepath=false: git C-quotes non-ASCII filenames by default, and
# the quoted form fails [ -f ] — a secret in such a file would be silently missed.
untracked_hits=$(git -c core.quotepath=false ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r path; do
  [ -f "$path" ] && grep -E -q "$SECRET_PATTERN" "$path" 2>/dev/null && printf '%s\n' "$path"
done)

if [ "${tracked_hits:-0}" -gt 0 ] || [ -n "$untracked_hits" ]; then
  echo "SECURITY=BLOCKED-secret"
  [ "${tracked_hits:-0}" -gt 0 ] && echo "  $tracked_hits added line(s) in the tracked diff match a credential pattern"
  if [ -n "$untracked_hits" ]; then
    echo "  untracked files with matches:"
    printf '%s\n' "$untracked_hits" | sed 's/^/    /'
  fi
else
  echo "SECRET_SCAN=clean"
fi
```

On `SECURITY=BLOCKED-secret`: surface it LOUDLY (name the matching locations), record `security: BLOCKED-secret`, and mark delivery blocked — Steps 4.5 and 4.6 MUST be skipped even when `--deliver`/`--deploy` was passed. The pipeline still continues to Step 4 and terminates normally; nothing is committed or pushed until a human removes the credential.

### Step 3.6b: Dependency audit (advisory unless `--strict-security`)

```bash
# Advisory by default: CVE feeds are noisy and the fix is often a transitive
# bump the author cannot make. --strict-security upgrades findings to
# delivery-blocking for callers who want the hard gate.
if [ -f package.json ] && command -v npm >/dev/null 2>&1; then
  if audit_out=$(npm audit --omit=dev 2>&1); then
    echo "DEPS=clean"
  else
    echo "DEPS=advisories"
    printf '%s\n' "$audit_out" | tail -5
  fi
elif { [ -f pyproject.toml ] || [ -f requirements.txt ]; } && command -v pip-audit >/dev/null 2>&1; then
  if audit_out=$(pip-audit 2>&1); then
    echo "DEPS=clean"
  else
    echo "DEPS=advisories"
    printf '%s\n' "$audit_out" | tail -5
  fi
else
  echo "DEPS=skipped"
fi
```

`DEPS=advisories` is recorded and appended to the PR body (Step 4.5a), never blocking — UNLESS Flag Parsing set `STRICT_SECURITY=1`, in which case treat it like a blocked delivery: record `security: advisories (blocking via --strict-security)` and skip Steps 4.5/4.6.

### Step 3.6c: Security review skill (advisory)

If the built-in security-review skill is available in this session, run it over the diff for logic-level vulnerabilities (injection, authz gaps, unsafe eval). Its findings are advisory: record them for the Step 5 summary and the PR body. Never block on them.

Outcome for Step 5: `BLOCKED-secret` if 3.6a hit; else `advisories` if 3.6b or 3.6c found anything; else `pass`. Emit telemetry: the Telemetry block with `security` and that outcome.

## Step 4: Document

Delegate to the **doc-maintainer** subagent:
- Review all recent changes
- Create or update ALL applicable documentation following the agent's own policy:
  - **Always create if missing:** CLAUDE.md, README.md, docs/architecture.md, docs/api.md (if project has endpoints)
  - **Create if applicable:** docs/workflows.md, docs/frontend.md, docs/backend.md, .env.example
  - **Update if changed:** any existing doc affected by the code changes
- Do NOT skip doc creation for "first-time" projects — this is exactly when those essential docs should be written

## Step 4.5: Deliver (only when `--deliver`/`--deploy` was passed)

Runs ONLY if Flag Parsing set `DELIVER=1`. **Flag-gated, NOT stage-gated:** this step runs regardless of the starting stage — a run resumed at `test` or `docs` still delivers when the flag is present. If `DELIVER=0`, skip this entire step — nothing touches the remote — and record in the Step 5 summary: `Delivery: skipped (no --deliver flag). Deliver manually with: /autopilot-from docs --deliver`. Emit telemetry: the Telemetry block with `deliver` `skipped-no-flag`.

**Precondition — the always-blocking secret scan:** if Step 3.6 did not run this session (a `docs` start skips it positionally), run the Step 3.6a block NOW, before composing anything. `SECURITY=BLOCKED-secret` blocks delivery here exactly as it does there.

Also skip this step (and Step 4.6) when Step 3.6 recorded `security: BLOCKED-secret` — a detected credential blocks delivery unconditionally, flag or no flag — or when `--strict-security` upgraded dependency advisories to blocking. Record the blocking outcome in the Step 5 summary and emit telemetry: `deliver` with `BLOCKED-secret` or `BLOCKED-strict-security` (tokens match the `SECURITY=` sentinel spelling so read-time consumers can correlate them).

### Step 4.5a: Compose the commit message and PR body

Before running any git command, write two files under `${TMPDIR:-/tmp}` (outside the repo, so `git add -A` can never stage them):

1. **Commit message** → `${TMPDIR:-/tmp}/autopilot-commit-msg.txt`. Subject is a Conventional Commit derived from the plan frontmatter: map `type:` `feature`/`design` → `feat`, `bugfix` → `fix`, `refactoring` → `refactor`, anything else → `chore`. Format: `{cc-type}: {slug with hyphens as spaces} ({PLAN-ID})`, e.g. `feat: add auth (PLAN-007)`. Body: the plan's `summary:` line. If no plan is associated with this run (e.g. a bare `docs` resume), derive the subject from the task description with type `chore`. **NO AI-attribution trailer** — do NOT use the Bash tool's HEREDOC commit example, which appends `Co-Authored-By: Claude …`; that line must not appear in any form.

2. **PR body** → `${TMPDIR:-/tmp}/autopilot-pr-body.md`. Synthesize from the plan file (omit sections that have no source):
   - **Goals** — from `## Goals & Non-Goals` (or `## Task` for lightweight plans)
   - **Test summary** — from the qa-expert Step 3 report, or the `skipped (markdown-only)` note
   - **Verification** — the Step 3.5 `verify:` outcome; omit the section if it recorded `not-applicable` or Step 3.5 did not run
   - **Security** — dependency advisories and security-review findings from Step 3.6, if any; omit when clean
   - **Rollback** — from `## Rollback Strategy`, if the plan has one
   - **Review blockers** — only if Step 2.5 recorded `review: blockers-remaining`: list the remaining blockers verbatim
   - No AI-attribution anywhere in the body.

### Step 4.5b: Commit and guarded push

Run with the commit message file path as `$1`:

```bash
# Inputs: $1 = path to the composed commit message file.
COMMIT_MSG_FILE="$1"

# Preconditions — degrade to a recorded skip, never a crash.
command -v gh >/dev/null 2>&1 || { echo "DELIVER=skip-no-gh"; exit 0; }
gh auth status >/dev/null 2>&1 || { echo "DELIVER=skip-no-auth"; exit 0; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "DELIVER=skip-not-in-repo"; exit 0; }
git remote get-url origin >/dev/null 2>&1 || { echo "DELIVER=skip-no-remote"; exit 0; }

branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
  echo "DELIVER=skip-on-default-branch"; exit 0
fi

# Stage everything the pipeline produced on this branch.
git add -A
# The autopilot sentinel/finished marker (and local settings, if present) are runtime
# state, never content — keep them out of the commit in repos whose .gitignore predates them.
git reset -q -- .claude/.autopilot-active .claude/.autopilot-finished .claude/settings.local.json 2>/dev/null || true

# WHY test the index instead of inferring from commit's exit code: `git commit`
# also fails on an unreadable message file or a failing pre-commit hook — reporting
# those as "nothing-to-commit" would swallow a real error and leave staged work behind.
if git diff --cached --quiet; then
  echo "DELIVER=nothing-to-commit"
  # Still push if the branch has unpushed commits from an earlier step (e.g. a resume),
  # but never on a clean, fully-pushed branch.
  ahead=$(git rev-list --count "@{upstream}..HEAD" 2>/dev/null || echo 0)
  if [ "${ahead:-0}" -gt 0 ]; then
    git push -u origin "$branch" || { echo "DELIVER=push-failed"; exit 1; }
    echo "DELIVER=pushed:$branch"
  fi
else
  # WHY guard the push: only push when this run actually created a commit.
  git commit -q -F "$COMMIT_MSG_FILE" || { echo "DELIVER=commit-failed"; exit 1; }
  git push -u origin "$branch" || { echo "DELIVER=push-failed"; exit 1; }
  echo "DELIVER=pushed:$branch"
fi
```

Read the `DELIVER=` output:
- Any `skip-*` → record it verbatim in the Step 5 summary and skip the rest of Step 4.5.
- `commit-failed` (exit 1) → surface git's error (message file unreadable, pre-commit hook failure, etc.), record `DELIVER=commit-failed` in the summary, and skip Step 4.5c. Staged work is left intact for the human. Do NOT retry.
- `push-failed` (exit 1) → surface git's error, record `DELIVER=push-failed` in the summary, and skip Step 4.5c. Do NOT retry.
- `pushed:*` → proceed to Step 4.5c.
- `nothing-to-commit` with no `pushed:` line → still proceed to Step 4.5c: an earlier run may have pushed without opening the PR, and the block there handles both "no upstream" and "PR already exists".

### Step 4.5c: Open the PR

PR title = the commit subject from Step 4.5a. Mode: `draft` if and only if Step 2.5 recorded `review: blockers-remaining` OR Step 3.5 recorded `verify: fail`; otherwise `ready` (a run that skipped Review/Verify is `ready`). Run with those as arguments:

```bash
# Inputs: $1 = PR title, $2 = path to the composed PR body file, $3 = "draft" or "ready".
PR_TITLE="$1"
PR_BODY_FILE="$2"
PR_MODE="$3"

# The branch must exist on the remote before a PR can reference it.
git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 || { echo "DELIVER=skip-pr-no-upstream"; exit 0; }

# Reuse an existing PR rather than erroring on a resumed run.
if gh pr view >/dev/null 2>&1; then
  echo "DELIVER=pr-already-exists"
  gh pr view --json url --jq .url
  exit 0
fi

if [ "$PR_MODE" = "draft" ]; then
  gh pr create --draft --title "$PR_TITLE" --body-file "$PR_BODY_FILE"
else
  gh pr create --title "$PR_TITLE" --body-file "$PR_BODY_FILE"
fi
echo "DELIVER=pr-created:$PR_MODE"
```

Record the final `DELIVER=` line and the PR URL (printed by `gh pr create`/`gh pr view`) for the Step 5 summary, and emit telemetry: the Telemetry block with `deliver` and the final `DELIVER=` outcome keyword (e.g. `pr-created:ready`, `pr-already-exists`, `skip-no-gh`, `commit-failed`; for `pushed:<branch>` emit just `pushed` — branch names are not structural facts). Then clean up the composed files:

```bash
rm -f "${TMPDIR:-/tmp}/autopilot-commit-msg.txt" "${TMPDIR:-/tmp}/autopilot-pr-body.md"
```

## Step 4.6: CI Heal (only after Step 4.5 actually pushed)

Runs ONLY when Step 4.5 pushed this run's work (`DELIVER=pushed:*`, or a PR exists on a branch with an upstream after a resume). Like Deliver it is flag-gated, NOT stage-gated. If Step 4.5 was skipped or nothing was pushed, skip this step, record `CI: skipped (nothing pushed)`, and emit telemetry: the Telemetry block with `ci-heal` `skipped`.

The heal loop is hard-capped at **3** attempts. Reviewer and verify are intentionally NOT re-run inside the loop — re-running expensive adversarial gates inside a bounded fix loop risks a runaway — but the always-blocking secret scan IS re-run on every heal commit, because "no secret ever reaches the remote" must hold even for code this loop produces.

For each attempt (1, 2, 3):

**1. Poll the CI run** tied to the current branch (bounded — never an infinite wait):

```bash
# Prints exactly one CI_STATE= line: green | red:<run-id> | pending-timeout | unavailable.
command -v gh >/dev/null 2>&1 || { echo "CI_STATE=unavailable"; exit 0; }
gh auth status >/dev/null 2>&1 || { echo "CI_STATE=unavailable"; exit 0; }
branch=$(git rev-parse --abbrev-ref HEAD)

# WHY bounded polling: a workflow that never reports must not hang a hands-free
# pipeline. Worst case ~5 minutes, then the caller records CI=unavailable.
MAX_CHECKS=20
POLL_SLEEP=15
checks=0
while [ "$checks" -lt "$MAX_CHECKS" ]; do
  run_info=$(gh run list --branch "$branch" --limit 1 \
    --json databaseId,status,conclusion \
    --jq '.[0] | "\(.databaseId) \(.status) \(.conclusion)"' 2>/dev/null)
  if [ -z "$run_info" ]; then
    # The run may not be listed yet right after a push — allow a short grace
    # window, then conclude there is no workflow / no reachable CI.
    checks=$((checks + 1))
    [ "$checks" -ge 4 ] && { echo "CI_STATE=unavailable"; exit 0; }
    sleep "$POLL_SLEEP"
    continue
  fi
  run_id=${run_info%% *}
  rest=${run_info#* }
  run_status=${rest%% *}
  conclusion=${rest#* }
  if [ "$run_status" = "completed" ]; then
    if [ "$conclusion" = "success" ]; then
      echo "CI_STATE=green"
    else
      echo "CI_STATE=red:$run_id"
    fi
    exit 0
  fi
  checks=$((checks + 1))
  sleep "$POLL_SLEEP"
done
echo "CI_STATE=pending-timeout"
```

- `CI_STATE=green` → record `CI=green`. Step 4.6 is done.
- `CI_STATE=unavailable` or `CI_STATE=pending-timeout` → record `CI=unavailable` and stop — do not spin on a broken or slow provider.
- `CI_STATE=red:<run-id>` → continue to 2.

**2. Pull the failing logs** (run with the run id as `$1`):

```bash
# Inputs: $1 = the failing run id from CI_STATE=red:<run-id>.
if gh run view "$1" --log-failed > "${TMPDIR:-/tmp}/autopilot-ci-failure.log" 2>&1; then
  echo "CI_LOG=${TMPDIR:-/tmp}/autopilot-ci-failure.log"
else
  echo "CI_LOG=unavailable"
fi
```

If it prints `CI_LOG=unavailable`, record `CI=unavailable` and stop.

**3. Delegate the engineer** subagent with the failing log content as the fix brief: fix ONLY what the log shows failing — no scope creep, no refactors.

**4. Commit, re-scan, push** the heal fix (run with the attempt number as `$1`):

```bash
# Inputs: $1 = heal attempt number (1-3).
ATTEMPT="$1"

git add -A
# Runtime state, never content (same exclusions as Step 4.5b).
git reset -q -- .claude/.autopilot-active .claude/.autopilot-finished .claude/settings.local.json 2>/dev/null || true

if git diff --cached --quiet; then
  echo "CI-HEAL=nothing-to-commit"
  exit 0
fi

# Plain Conventional Commit; NO AI-attribution trailer.
git commit -q -m "fix: address CI failure (heal attempt $ATTEMPT)" || { echo "CI-HEAL=commit-failed"; exit 1; }

# ALWAYS re-run the unconditional secret scan on the heal diff BEFORE the push.
# WHY: heal commits never passed reviewer/verify; the ONE guarantee that must
# still hold for code this loop produces is "no secret reaches the remote."
SECRET_PATTERN='AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[bp]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AIza[0-9A-Za-z_-]{35}|ya29\.[0-9A-Za-z_-]+'
if git show HEAD 2>/dev/null | grep -E '^\+' | grep -E -q "$SECRET_PATTERN"; then
  # Undo the commit but keep the work staged for a human to inspect. Never push.
  git reset -q --soft HEAD~1
  echo "CI-HEAL=ABORTED-secret-detected"
  exit 1
fi

git push || { echo "CI-HEAL=push-failed"; exit 1; }
echo "CI-HEAL=pushed:attempt-$ATTEMPT"
```

- `CI-HEAL=nothing-to-commit` → the engineer produced no change; record it and stop (re-dispatching on the same log would loop).
- `CI-HEAL=ABORTED-secret-detected` → surface LOUDLY, record it, and stop. The heal commit was undone and never pushed.
- `CI-HEAL=commit-failed` / `CI-HEAL=push-failed` → surface git's error, record, stop. Do NOT retry.
- `CI-HEAL=pushed:attempt-N` → loop back to 1 for the next poll.

If all 3 attempts are used and CI is still not green, record `CI=red-after-3-attempts`. Every outcome feeds the Step 5 summary — a human resolves anything that is not green.

Emit telemetry: the Telemetry block with `ci-heal`, the terminal outcome (`green`, `red-after-3-attempts`, `unavailable`, `ABORTED-secret-detected`, `nothing-to-commit`, `commit-failed`, or `push-failed` — each token exactly as its recorded `CI=`/`CI-HEAL=` sentinel spells it), and extra `"attempts":<0-3>`.

## Step 5: Summary & Cleanup

Provide a summary first, THEN remove the sentinel:

```
## Autopilot Summary (from {starting_stage})

### Plan (if ran)
- ID: PLAN-{NNN}
- File: /docs/plans/PLAN-{NNN}-{slug}.md
- Self-review: {issues caught and fixed, or "clean"}

### Implementation (if ran)
- Files created: {list}
- Files modified: {list}

### Review (if ran)
- Verdict: {approved | approved-after-fixes | blockers-remaining ({n} blockers)}
- Fix/re-review iterations used: {0–2}
- {or: `Skipped: starting stage was test/docs — nothing new to review`}

### Tests (if ran)
- Tests written: {count}
- Test files: {list}
- {one of the following lines, depending on whether Step 3 ran:}
  - `All passing: {yes/no}` (when qa-expert ran)
  - `Skipped: markdown-only change set, no automated tests applicable` (when Step 3 was bypassed)

### Verification (if ran)
- {verify: pass | fail (reason) | not-applicable}

### Security (if ran)
- {security: pass | advisories (summary) | BLOCKED-secret (locations) | advisories (blocking via --strict-security)}

### Documentation Updated (if ran)
- {list of docs updated}

### Delivery
- {one of the following, depending on flags and outcome:}
  - `Skipped (no --deliver flag). Deliver manually with: /autopilot-from docs --deliver`
  - `Blocked: {security: BLOCKED-secret | advisories via --strict-security}` — nothing committed or pushed
  - `{final DELIVER=... outcome}` plus the PR URL and mode (draft/ready) when a PR was opened

### CI
- {one of: `green` | `red-after-3-attempts` | `unavailable` | `CI-HEAL=...` terminal outcome | `skipped (nothing pushed)`}

### Issues / Warnings
- {anything that needs human attention}
```

Now hand off to the Stop hook and remove the sentinel (must be the very last action):
```bash
# WHY the finished marker: a single-turn autopilot run creates and removes the
# sentinel inside one turn, so the Stop hook's sentinel bypass never fires and
# no fingerprint is saved — the next Stop would re-trigger qa/doc agents on work
# this run already did. This command cannot save the fingerprint itself (the
# fingerprint file is keyed by session_id, which only the hook receives), so the
# marker tells the hook's next fire to save it and skip. The hook consumes the
# marker on first sight.
touch .claude/.autopilot-finished
rm -f .claude/.autopilot-active
```
