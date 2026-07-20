# maestro

An [OxCaml](https://oxcaml.org) implementation of the
[Symphony](https://github.com/openai/symphony) service specification: a long-running daemon
that reads work from an issue tracker, creates an isolated per-issue workspace, and runs a
Codex coding-agent session for that issue inside the workspace, with bounded concurrency,
retries, reconciliation, structured logs, an HTTP observability API, and an interactive
terminal dashboard.

The spec and its reference Elixir implementation are vendored as a git submodule under
[`vendor/symphony`](vendor/symphony); this project is written against
[`SPEC.md`](vendor/symphony/SPEC.md). Design notes and the conformance mapping live in
[`PLAN.md`](PLAN.md).

> **Trust posture.** maestro targets **trusted environments**. It passes the approval and
> sandbox policy from `WORKFLOW.md` through to Codex verbatim; client-side auto-approval
> happens only when `codex.approval_policy` is the literal string `"never"`.
> User-input-required turns never stall — they end the run and park the issue as *blocked*
> until an operator intervenes. Workspace containment and sanitized keys are enforced
> before every launch, and tracker credentials are resolved host-side and scrubbed from the
> coding-agent's environment. It is a preview, not a supported product; run it only where
> you would run an unsupervised coding agent.

## Building

maestro requires the OxCaml toolchain (`bonsai_term`, which pins the compiler). Everything
is captured in [`maestro.opam.locked`](maestro.opam.locked).

```bash
# 1. System packages (Debian/Ubuntu names): the OxCaml compiler + zarith + TLS need these.
sudo apt-get install -y autoconf rsync libgmp-dev

# 2. A directory-local switch on the OxCaml compiler, with the ox + default repositories.
#    (Lock files record versions, not repositories, so name the repo here.)
opam switch create . 5.2.0+ox \
  --repos ox=git+https://github.com/oxcaml/opam-repository.git,default \
  --no-install

# 3. Install the exact locked dependency set.
opam install . --locked --deps-only --with-test

# 4. Build and test.
dune build
dune runtest
```

## Running

```bash
maestro --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  [--logs-root DIR] [--port PORT] [path-to-WORKFLOW.md]
```

- The positional path defaults to `./WORKFLOW.md`; a missing file is a clean startup error.
- The acknowledgement flag is mandatory (see the trust posture above).
- `--logs-root DIR` writes a rotating log to `DIR/log/maestro.log` (default `./log`). On an
  interactive terminal the dashboard owns the screen and logs go to the file; headless runs
  log to stderr.
- `--port PORT` (or `server.port` in the workflow) enables the HTTP dashboard and JSON API,
  bound to loopback. `--port 0` picks an ephemeral port.

Copy [`WORKFLOW.example.md`](WORKFLOW.example.md) to `WORKFLOW.md` and edit it for your
repository. `WORKFLOW.md` is watched: edits are re-applied without a restart, and an
invalid edit keeps the last known-good configuration.

### Interactive dashboard

On a tty maestro renders a live dashboard: header stats (agents, tokens, runtime, next
poll), a Running / Backoff queue / Blocked list, and a detail pane for the selected agent.
Keys: `↑`/`↓` (or `k`/`j`) select, `r` refresh, `q`/`Esc`/`Ctrl-C` quit.

### HTTP API

When enabled, under `/api/v1`:

- `GET /api/v1/state` — running sessions, retry queue, blocked issues, aggregate token and
  runtime totals, latest rate limits.
- `GET /api/v1/<issue_identifier>` — per-issue runtime detail (`404 issue_not_found` if
  unknown).
- `POST /api/v1/refresh` — queue an immediate poll + reconcile cycle.
- `GET /` — a self-contained HTML dashboard that polls the JSON API.

## Codex sandbox and timeouts (operational notes)

Verified end-to-end against real Linear + a real `codex` binary. Two things to configure:

- **Startup timeout.** Real `codex app-server` cold start (model/auth warmup) can exceed
  the 5 s `codex.read_timeout_ms` default and trip a first-attempt `response_timeout`;
  maestro retries with backoff, but set `read_timeout_ms: 30000` to avoid the wasted
  attempt.
- **Sandbox.** `codex.turn_sandbox_policy` is passed to codex verbatim. An explicit
  `workspaceWrite` policy must list `writableRoots` (codex does not add the workspace to an
  explicit policy) — or omit `turn_sandbox_policy` entirely to use maestro's default, which
  roots `writableRoots` at the per-issue workspace. In containers or CI where codex's OS
  sandbox (landlock/seccomp) is unavailable, file writes fail even inside `writableRoots`;
  there, use `thread_sandbox: danger-full-access` and
  `turn_sandbox_policy: { type: dangerFullAccess }`, as the reference implementation does
  for its Docker workers.

The `linear_graphql` tool runs host-side with maestro's credential, so tracker writes
(state transitions, comments) work regardless of the codex sandbox.

## Tracker adapters

### `memory`

An in-memory adapter for tests and local experiments; serves a fixed issue list, no auth.

### `linear` — adapter profile

- **`tracker.kind`**: `linear`.
- **`tracker.provider`** keys: `endpoint` (default `https://api.linear.app/graphql`),
  `api_key` (required; a Linear personal API key, sent as the raw `Authorization` header —
  no `Bearer` prefix), `project_slug` (required; scopes scheduler reads), `assignee`
  (optional; a Linear user id or `me`). Legacy top-level `tracker.endpoint`/`api_key`/
  `project_slug`/`assignee` are accepted as aliases; provider keys win. `$VAR` references
  are resolved host-side; `api_key` falls back to `$LINEAR_API_KEY`, `assignee` to
  `$LINEAR_ASSIGNEE`. An env var set to the empty string counts as missing.
- **Secret env names removed from the agent's environment**: `LINEAR_API_KEY` plus any
  `$VAR` referenced by `api_key`.
- **Scope & pagination**: filters by project slug + requested states; page size 50, cursor
  pagination; id-refresh batches of 50 re-sorted to request order; empty inputs make no
  request.
- **Normalization**: labels trimmed/lowercased/deduped; integer priorities only; RFC 3339
  timestamps else null; `blocked_by` from inverse `blocks` relations; `native_ref` is null
  (`issue.id` is the Linear id).
- **`dispatchable`**: assignee filter matches (unset ⇒ everyone; `"me"` ⇒ a viewer query
  per fetch) **and** the issue is not a `Todo` with a non-terminal blocker.
- **Malformed records**: dropped (and logged) on candidate polls; a malformed *requested*
  record fails an id-refresh.
- **Provider-native tool**: `linear_graphql` — a raw GraphQL query/mutation executed
  host-side with the configured credential, advertised to the Codex session. Full mutation
  capability by design; scope guards and idempotency are the workflow's responsibility. The
  child never sees the token, only tool results.
- **Error categories**: config/auth (`missing_linear_api_token`, `missing_linear_project_slug`,
  `invalid_linear_endpoint`, `invalid_linear_assignee`, `missing_linear_viewer_identity`),
  transport (`linear_api_request`), non-success (`linear_api_status`; 429 is rate limiting),
  payload (`linear_graphql_errors`, `linear_unknown_payload`), pagination
  (`linear_missing_end_cursor`).

## Development

`dune build && dune runtest` before reporting work done; `dune fmt` for formatting. Each
library under `lib/` has an `.mli`; tests live under `test/`. The layering — template,
workflow/config, workspace, tracker/linear, codex, orchestrator, observability, http, tui,
and the `maestro` wiring — mirrors the SPEC's abstraction levels.

See [`AGENTS.md`](AGENTS.md) for the coding and documentation style used in this repository and
the review checklist for changes.

### Live integration test (opt-in)

`test/live_e2e/` runs a real Linear + real Codex smoke test, gated on
`MAESTRO_RUN_LIVE_E2E=1`. It needs `LINEAR_API_KEY`, a `codex` CLI on `PATH`, and
`MAESTRO_LIVE_PROJECT_SLUG`; without them it reports skipped. See its README for details.

## License

Apache-2.0, matching upstream Symphony.
