#!/bin/sh
# check-docs-fresh.sh — CI gate: fail the run if source changed but docs did not.
#
# A verification net, not a doc author: it never writes documentation, it only
# catches PRs where source files changed and no doc surface (README.md,
# CLAUDE.md, docs/**, .env.example) changed alongside them. Blocking by design
# (PLAN-004 D16): deterministic, cheap to fix, and cheaply escapable via the
# [skip-docs] commit-message / PR-body token.
#
# Ships in claude-code-setup at .claude/templates/ci/; vendored into generated
# projects at .github/scripts/check-docs-fresh.sh next to classify-changes.sh.
#
# Usage: check-docs-fresh.sh [base-ref]   (default: origin/$GITHUB_BASE_REF or origin/main)
# Exits: 0 = pass, 1 = stale docs, 2 = classifier library missing.

BASE_REF="${1:-origin/${GITHUB_BASE_REF:-main}}"
# Without a merge base against the target branch, the PR's own change set is
# not computable: a direct two-endpoint diff attributes the BASE branch's
# commits to the PR and can fail a PR that changed no source at all. A gate
# that cannot evaluate must pass with a warning, never block wrongly (a
# shallow clone / unfetched base ref is a checkout misconfiguration — the
# templates use fetch-depth: 0 precisely so this branch never runs in CI).
merge_base=$(git merge-base "$BASE_REF" HEAD 2>/dev/null) || merge_base=""
if [ -z "$merge_base" ]; then
  echo "docs-freshness: pass (WARNING — no merge base with $BASE_REF: shallow clone or unfetched base ref; gate cannot evaluate this PR. Use fetch-depth: 0 in the checkout step.)"
  exit 0
fi
# WHY core.quotepath=false: git C-quotes non-ASCII paths by default, and the
# trailing quote defeats the classifier's $-anchored extension match.
changed=$(git -c core.quotepath=false diff --name-only "$merge_base" HEAD)

# Source boundary comes from the shared library (single source of truth,
# PLAN-004 D17–D19). WHY sourced, not inlined: the gate must enforce exactly
# the change class that triggers doc-maintainer locally — one definition.
# WHY repo-relative first (D20): a CI runner has NO ~/.claude install, so the
# authoritative copy is the VENDORED sibling committed next to this script.
# CLASSIFY_LIB overrides both for testing; $HOME/.claude/lib is local-dev only.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB="${CLASSIFY_LIB:-$SCRIPT_DIR/classify-changes.sh}"
[ -f "$LIB" ] || LIB="$HOME/.claude/lib/classify-changes.sh"
if [ ! -f "$LIB" ]; then
  # WHY exit 2, not 0: a CI gate must never silently pass on misconfiguration.
  echo "docs-freshness: ERROR — classify-changes.sh not found (looked in $SCRIPT_DIR and \$HOME/.claude/lib)"
  exit 2
fi
. "$LIB"

doc_pattern='^(README\.md|CLAUDE\.md|\.claude/CLAUDE\.md|docs/|\.env\.example)'
changed_src=$(printf '%s\n' "$changed" | source_files_from_stdin)
changed_docs=$(printf '%s\n' "$changed" | grep -E "$doc_pattern")

# Escape hatch: [skip-docs] token in any commit message in the PR range, or in
# the PR body when the workflow passes it via the PR_BODY env var (D15 — the
# templates set PR_BODY from github.event.pull_request.body; unset means only
# commit messages are checked, e.g. when running locally).
# Fixed-string + case-insensitive so [Skip-Docs] matches without regex surprises.
if { git log "$merge_base"..HEAD --format=%B 2>/dev/null; printf '%s\n' "${PR_BODY:-}"; } | grep -qiF '[skip-docs]'; then
  echo "docs-freshness: skipped via [skip-docs] token"
  exit 0
fi

# No source change (markdown-only, config-only, docs-only) → trivially satisfied.
if [ -z "$changed_src" ]; then
  echo "docs-freshness: pass (no source files changed)"
  exit 0
fi
if [ -n "$changed_docs" ]; then
  echo "docs-freshness: pass (docs updated alongside source)"
  exit 0
fi

echo "docs-freshness: FAIL — source changed but no doc surface was updated."
echo "Changed source files:"
printf '%s\n' "$changed_src" | sed 's/^/  /'
echo "Fix by updating one of README.md / CLAUDE.md / docs/** / .env.example"
echo "(e.g. run /autopilot-from docs), or add [skip-docs] to a commit message"
echo "or the PR body if this change genuinely needs no docs."
exit 1
