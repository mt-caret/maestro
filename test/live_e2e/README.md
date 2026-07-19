# Live end-to-end test (opt-in)

This is the SPEC §17.8 *Real Integration Profile*: a smoke test against a **real Linear
project** and a **real Codex** binary. It is skipped by default and reported as skipped —
never silently passed.

## Enabling

Set all of:

- `MAESTRO_RUN_LIVE_E2E=1` — the gate.
- `LINEAR_API_KEY` — a Linear personal API key with write access to the test project.
- `MAESTRO_LIVE_PROJECT_SLUG` — the `slugId` of a **throwaway** Linear project. The test
  creates and then archives an issue there.
- A `codex` binary on `PATH` that speaks the app-server protocol, already authenticated.

```bash
MAESTRO_RUN_LIVE_E2E=1 \
LINEAR_API_KEY=lin_api_... \
MAESTRO_LIVE_PROJECT_SLUG=your-throwaway-project \
dune runtest test/live_e2e
```

## What it does

1. Creates a Linear issue in the project via the `linear_graphql` transport, in an active
   state.
2. Runs one agent (`Agent_runner`) against a real Codex, with a workflow whose prompt asks
   the agent to write a proof-of-work file into its workspace.
3. Asserts the workspace file exists.
4. Archives the test issue.

Without the gate or credentials it prints why it was skipped and passes, so it is safe to
run in CI where those are unavailable.
