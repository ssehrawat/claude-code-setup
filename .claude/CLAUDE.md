# Global Development Conventions

## Code Quality Standards — Non-Negotiable

- Write production-grade code. Every file you produce should be deployable as-is.
- No placeholder comments like `// TODO: implement this` or `// add logic here`. If you write it, finish it.
- No lazy variable names: `data`, `result`, `temp`, `stuff`, `thing`, `val`, `item` are banned unless scoped to 3 lines or less.
- No unnecessary abstractions. Don't create a factory-pattern wrapper around a single function. Earn your abstractions.
- No filler comments that restate the code. `// increment counter` above `counter++` is noise. Comment the WHY, never the WHAT.
- No apologetic or hedging language in code comments. No `// this might not be the best way` or `// hopefully this works`. Be decisive.
- Error handling is mandatory. Never swallow errors. Never use empty catch blocks. Log, rethrow, or handle — pick one.
- Functions do one thing. If you need the word "and" to describe what a function does, split it.
- No magic numbers or strings. Extract constants with descriptive names.
- Type everything. No `any` in TypeScript. No untyped dicts in Python where a dataclass/TypedDict fits.
- Prefer explicit over implicit. Prefer composition over inheritance. Prefer flat over nested.
- Test edge cases, not just the happy path. Empty inputs, nulls, boundaries, concurrent access, malformed data.

## Commit Message Standard

- Never include a `Co-Authored-By: Claude` (or any AI-attribution) trailer in commit messages or PR bodies. Plain commit messages, no attribution footer.
- This overrides the Bash tool's default HEREDOC commit example, which appends `Co-Authored-By: Claude …`. Strip that line; do not substitute another attribution.
- When delegating commit or PR work to subagents (engineer, qa-expert, doc-maintainer, or any Agent invocation), explicitly tell them to omit the attribution trailer.
- Applies to: `git commit -m`, `git commit` via HEREDOC, `gh pr create --body`, amend operations, and any commit produced by hooks or scripts.

## Code Documentation Standard

- Every new file MUST start with a module docstring explaining purpose and key exports
- Non-obvious decisions MUST include a `// WHY:` comment explaining the reasoning
- All public functions/classes MUST have docstrings describing intent, not just parameters
- Never write comments that restate what the code does — only explain WHY

## Plan Management

- ALL design plans and refactoring plans MUST be saved to `./docs/plans/` in the PROJECT directory (never in ~/.claude/)
- Create `./docs/plans/` if it doesn't exist before writing any plan
- Naming convention: `PLAN-{NNN}-{short-slug}.md` (e.g., `PLAN-001-initial-architecture.md`)
- Always check `./docs/plans/` for the next available ID before creating a new plan
- Each plan file MUST include YAML frontmatter with: id, date, status, type, summary
- Valid statuses: `draft` → `approved` → `in-progress` → `implemented` | `superseded`
- When superseding a plan, update the old plan's status and add `superseded_by` field
- NEVER start implementation without a plan. Plan first, review, then implement.

## Documentation Maintenance

After making significant code changes, the following MUST be checked and updated or created:

1. **Test cases**: Corresponding tests must exist and cover new/changed behavior
2. **Evals**: If `evals/` exists, new functionality needs eval coverage
3. **CLAUDE.md**: Project overview, commands, structure, conventions
4. **README.md**: Setup, usage, API surface, features
5. **docs/architecture.md**: Component overview, data flow, entry points
6. **docs/api.md**: Endpoints, methods, request/response shapes, auth, errors
7. **docs/workflows.md**: Dev, test, build, deploy workflows (if multiple exist)
8. **docs/frontend.md**: Component structure, state, routing, styling (if frontend exists)
9. **docs/backend.md**: Service architecture, middleware, DB patterns, auth (if backend exists)
10. **.env.example**: All environment variables with descriptions

## Agent Delegation

Two modes of operation:

### Manual (step by step)
- `/build-plan` → creates implementation plan via the **planner** agent
- `/review-plan` → review and approve the plan
- `/implement` → delegates to the **engineer** agent for production-grade implementation
- `/review` → adversarial diff review via the **reviewer** agent (report only, never fixes)
- `/verify` → real-run check: start the app / invoke the CLI / run the README example; failure is blocking in manual mode
- After implementation, **qa-expert** and **doc-maintainer** run automatically via Stop hook

### Autopilot (fully automated)
- `/autopilot` → runs the entire chain: plan → implement → review → test → verify → security → docs
- The **reviewer** gates between implement and test: blockers dispatch an engineer fix pass then a re-review, capped at 2 iterations; surviving blockers are recorded, never silently dropped
- Verify (Step 3.5) is advisory in autopilot: outcome recorded, never blocks; a `fail` downgrades a delivered PR to a draft
- Security (Step 3.6): the secret scan is ALWAYS blocking (a hit stops delivery unconditionally); dependency audits are advisory unless `--strict-security` upgrades them to blocking
- `--deliver` (or `--deploy`, which implies it) adds a delivery stage: commit (Conventional Commit, no AI-attribution trailer), push, open a PR (draft if blockers remain or verify failed). OFF by default — without the flag nothing touches a remote
- After a push, CI heal (Step 4.6) reads failing CI logs and dispatches engineer fixes, capped at 3 attempts; the secret scan re-runs on every heal commit before its push
- No human intervention needed. Plan is auto-approved. All agents run in sequence.

### Change classification (single source of truth)
- `~/.claude/lib/classify-changes.sh` defines what counts as a source-code change for the Stop hook, autopilot's markdown-only guard, qa-expert's scope guard, and the CI docs-freshness gate
- The boundary is a curated allowlist: code extensions plus `.sql` (migrations change the data contract); `.yaml`/`Dockerfile`/lockfiles are not source
- "Markdown-only" means "no source files in the change set" — the inverse of the allowlist, not `grep -v '\.md$'`
- When the library is missing (installs predating `~/.claude/lib/`), the Stop hook falls back to an inline replica of the same allowlist (`.sql` included); the autopilot/qa-expert guards fall back to a transitional `.md`-blocklist check — re-run `install.sh` to converge them

### CI scaffolding
- New projects scaffolded by the engineer get `.github/workflows/ci.yml` (from `~/.claude/templates/ci/`, matched to the stack) plus a vendored docs-freshness gate at `.github/scripts/` (`check-docs-fresh.sh` + `classify-changes.sh`)
- The gate fails a PR when source changed but no doc surface (README.md / CLAUDE.md / docs/** / .env.example) changed; escape with a `[skip-docs]` token in a commit message or the PR body (passed to the gate via the `PR_BODY` env var)
- No merge base with the target branch (shallow clone) → the gate passes with a warning naming `fetch-depth: 0`; it never blocks a PR whose change set it cannot compute

These agents run as subagents to preserve your main context window
