Verify that the current project actually runs. Optional focus hint (a start command, URL, or subcommand): $ARGUMENTS

This is MANUAL MODE. One real-run verification pass, and failure is BLOCKING: report it and stop — unlike autopilot Step 3.5, which records the outcome and continues (advisory posture for hands-free runs; a human at the keyboard wants the hard answer).

This is NOT a test run. Unit tests already ran (or will). This starts the actual artifact and confirms it behaves.

1. Detect the run surface from the manifest, the plan, and the README — first match wins. If `$ARGUMENTS` names a command or URL, use it directly instead of detecting:
   - **HTTP server** — a start script or entry point that serves HTTP (e.g. `npm start` on an Express app, `uvicorn`/`flask run`). Use the server block below with the start command and a health or root URL.
   - **CLI** — the project ships a command-line entry point. Use the CLI block below with `--help` (or a documented subcommand); exit 0 = pass.
   - **Library** — no run surface of its own. Write the README usage example to a scratch file under `${TMPDIR:-/tmp}`, run it via the CLI block, then delete the scratch file.
   - **Nothing detectable** — report `VERIFY=not-applicable`, explain what you looked for, and stop. Do not invent a probe.

2. Run the matching block.

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

3. Report the outcome and STOP:
   - `VERIFY=pass` → "Verification passed: {what was started/invoked and what it returned}."
   - `VERIFY=fail` → **BLOCKING.** Report exactly what was run, what was expected, and what happened (exit code, HTTP status, timeout). Suggest the likely fix, but make no changes. The human decides what happens next.
   - `VERIFY=not-applicable` → say what surfaces were checked and why none applied.

## CRITICAL RULES

- This command is VERIFY ONLY. NEVER delegate to any agent. NEVER write or edit any source file.
- Failure is BLOCKING: on `VERIFY=fail`, report and stop. Do not "helpfully" fix the code, do not retry with a different probe unless the human asks.
- Every started process is killed before this command finishes — the trap in each block guarantees it; do not bypass the blocks with ad-hoc invocations.
- One pass per run. If the human fixes something, they run `/verify` again.
