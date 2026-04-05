Create a detailed implementation plan for: $ARGUMENTS

This is MANUAL MODE. You are talking directly to the human. Do NOT delegate to any subagent yet.

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
