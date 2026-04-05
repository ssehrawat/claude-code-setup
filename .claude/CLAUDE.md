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
- `/plan` → creates implementation plan via the **planner** agent
- `/review-plan` → review and approve the plan
- `/implement` → delegates to the **engineer** agent for production-grade implementation
- After implementation, **qa-expert** and **doc-maintainer** run automatically via Stop hook

### Autopilot (fully automated)
- `/autopilot` → runs the entire chain: plan → implement → test → docs
- No human intervention needed. Plan is auto-approved. All agents run in sequence.

These agents run as subagents to preserve your main context window
