Create a detailed implementation plan for: $ARGUMENTS

This is MANUAL MODE. You are talking directly to the human. Do NOT delegate to any subagent yet.

---

## Phase 0: Bootstrap Detection

Before doing anything else, check whether the current working directory looks like an existing project. If it doesn't, the user is starting from scratch and we need to create a project directory before the planner writes anything.

Run this detection block exactly:

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

**If `NEEDS_BOOTSTRAP=0`:** Skip the rest of Phase 0 silently and proceed to Phase 1.

**If `NEEDS_BOOTSTRAP=1`:** Ask the human directly:

> "What would you like to call this project? I'll create `./<name>/` and treat it as the project root."

Wait for their reply. Then run the bootstrap execution block below, passing the user's reply as `$1`:

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

Read the `pwd` output. From this point forward, treat the new directory as the project root for ALL subsequent paths in this command — `./docs/plans/` resolves inside the new directory, the planner writes there, and so on.

If the bootstrap script exits non-zero (sanitization failed, directory already exists, git identity unset), surface the error to the user verbatim and stop. Do not proceed to Phase 1.

---

## Phase 1: Discovery (YOU do this, not a subagent)

Before writing any plan, you need to understand the problem deeply. Do this yourself in the main conversation:

### Step 1: Read the codebase

Silently read the project structure, key files, existing patterns, and tech stack. Run `find`, `grep`, read source files. Understand the current state before asking anything.

### Step 2: Ask focused questions

Ask the human questions in batches of 3-5. For EVERY question, provide your own recommendation based on what you've seen in the codebase so they can just say "yes" or redirect.

**Round 1 — Scope & Intent:**
- What specific problem are they solving? (State what you think the core issue is)
- What's the desired end state? (Describe what you'd aim for)
- Hard constraints? (Timeline, backward compat, specific tech requirements)
- What's explicitly out of scope? (Suggest boundaries)

**Round 2 — Technical Decisions** (based on Round 1 answers):
- Architecture approach — present 2-3 options with your recommended pick and WHY
- Data model changes — if applicable, propose a schema
- API design — if applicable, propose endpoints/interfaces
- Integration points — what existing systems are affected

**Round 3 — Edge Cases & Risk** (only if needed for complex tasks):
- Failure scenarios they're most worried about
- Migration concerns
- Performance / security requirements

**Rules for questioning:**
- NEVER ask something you could answer by reading the codebase
- NEVER ask open-ended questions without a recommendation. Bad: "What database?" Good: "I'd recommend PostgreSQL because X — agree?"
- NEVER ask more than 5 questions at once
- If they say "your call" or "go with your recommendation" — take full delegation
- For simple tasks, 1 round is enough. For complex tasks, 2-3 rounds. Know when you have enough.
- When you have enough context, tell them: "I have enough to write the plan. Proceeding."

---

## Phase 2: Write the plan (delegate to planner subagent)

Once you have all the context from the Q&A, delegate to the **planner** subagent with a detailed brief that includes:
1. The original request: $ARGUMENTS
2. All decisions and answers from the Q&A phase
3. Any constraints or preferences the human specified
4. Explicit instruction to write the plan under the PROJECT directory: use the project's working directory, NOT ~/.claude/

Tell the planner subagent: "Write the plan to `./docs/plans/PLAN-{NNN}-{slug}.md` relative to the current project root. Create `./docs/plans/` if it doesn't exist. Do NOT write to ~/.claude/ or any global path."

---

## Phase 3: Present for review

After the planner writes the plan, tell the human:
- The plan file path
- A brief summary of what's in it
- "Review it with `/review-plan PLAN-{NNN}` when ready, or tell me what to change."
- Do NOT begin implementation.
