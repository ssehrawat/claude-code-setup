#!/bin/sh
# classify-changes.sh — single source of truth for "is a changed file source code?"
#
# Sourced by: update-docs.sh (Stop hook), autopilot.md Step 3 guard, qa-expert
# scope guard, and check-docs-fresh.sh (CI gate). WHY one file: the repo used to
# carry two contradictory framings — an extension allowlist in the Stop hook and
# a `grep -v '\.md$'` blocklist in autopilot/qa-expert — which silently disagreed
# on .sql/.yaml/config diffs (PLAN-004 D17). Drift is only eliminable by
# construction: one definition, many consumers.
#
# Install location: ~/.claude/lib/classify-changes.sh (copied by install.sh);
# ALSO vendored into generated projects at .github/scripts/classify-changes.sh
# (D20) so the CI gate can source a repo-relative sibling on a runner with no
# Claude install.
#
# Exports: SOURCE_EXT_PATTERN, collect_changed_files, source_files_from_stdin,
#          is_source_change, is_markdown_only

# WHY this exact set: mirrors the Stop hook's historical SOURCE_EXT_PATTERN plus
# .sql (D19 — schema migrations change the data contract, so they warrant test
# and doc attention). .yaml/Dockerfile/.tf/lockfiles stay OUT deliberately:
# high-volume, often machine-generated, and rarely in need of a test/doc pass.
SOURCE_EXT_PATTERN='\.(ts|tsx|js|jsx|mjs|cjs|py|rs|go|java|rb|cpp|c|h|hpp|cs|swift|kt|scala|ex|exs|clj|zig|sh|lua|php|dart|sql)$'

# Prints the current working-tree change set (uncommitted + untracked), one
# path per line, deduplicated, blank lines stripped. Empty output = clean tree.
# WHY core.quotepath=false: git C-quotes non-ASCII paths by default
# ("m\303\263dulo.py"), and the trailing quote defeats the $-anchored
# extension match — a non-ASCII source file would classify as not-source.
collect_changed_files() {
  { git -c core.quotepath=false diff --name-only HEAD 2>/dev/null
    git -c core.quotepath=false ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | grep -v '^[[:space:]]*$'
}

# Filters a newline-separated path list on stdin down to source files.
# WHY stdin-only (no [ -t 0 ] sniffing): guessing the input mode risks a read
# that hangs on EOF when stdin is neither tty nor pipe (the common subagent /
# CI case). Callers ALWAYS pipe into this; nothing here auto-collects.
source_files_from_stdin() {
  grep -E "$SOURCE_EXT_PATTERN"
}

# Prints the source subset of the current change set. Empty output (and exit
# status 1, from grep) = no source files changed.
is_source_change() {
  collect_changed_files | source_files_from_stdin
}

# Emits MD_ONLY=1 (return 0) when the change set contains NO source files,
# MD_ONLY=0 (return 1) otherwise. WHY the inverse of is_source_change rather
# than `grep -v '\.md$'` (D18): the allowlist gives .sql/.yaml/Dockerfile ONE
# answer everywhere, instead of the blocklist's "everything non-.md is code"
# which swept in lockfiles, YAML, and data fixtures as if they were code.
is_markdown_only() {
  if [ -n "$(is_source_change)" ]; then
    echo "MD_ONLY=0"
    return 1
  fi
  echo "MD_ONLY=1"
  return 0
}
