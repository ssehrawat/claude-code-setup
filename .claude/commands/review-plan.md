Review the plan: $ARGUMENTS

If $ARGUMENTS is a plan ID (like PLAN-003), read that specific plan from `./docs/plans/`.
If $ARGUMENTS is "latest", find the most recently created plan in `./docs/plans/`.
If $ARGUMENTS is "all", list all plans in `./docs/plans/` with their ID, status, type, date, and summary.

For a specific plan review:
1. Read the plan file completely
2. Analyze: feasibility, completeness, edge cases, risks, missing steps
3. Check if it conflicts with any existing non-superseded plans
4. Provide a candid assessment — don't sugarcoat problems
5. Ask the human what they want to do:
   - **Approve** → update plan status to `approved` and STOP. Do nothing else.
   - **Request changes** → keep as `draft`, note their feedback, and STOP.
   - **Reject** → update status to `rejected` and STOP.

## CRITICAL RULES

- NEVER start implementation after approving. Your ONLY job is to review and update the plan status.
- NEVER delegate to the engineer agent or any other agent.
- NEVER write any source code.
- After updating the status, tell the human their next step:
  "Plan approved. To implement, run: `/implement PLAN-{NNN}` or `/autopilot-from implement PLAN-{NNN}`"
- This command is REVIEW ONLY. Implementation is a separate, explicit step that the human must trigger.
