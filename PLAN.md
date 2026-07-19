# maestro — an OxCaml implementation of the Symphony spec

`maestro` implements the [Symphony service specification](vendor/symphony/SPEC.md) (Draft v1,
language-agnostic) in OCaml on the OxCaml toolchain, with an interactive terminal UI built on
`bonsai_term`. The upstream repo (spec + reference Elixir implementation) is vendored as a git
submodule at `vendor/symphony` and is the authority this plan cites (`SPEC §n` = SPEC.md section,
`ref:` = reference implementation behavior).

## 1. Scope decisions (settled 2026-07-19)

| Decision | Choice |
|---|---|
| Tracker adapters | `linear` (full GraphQL adapter + `linear_graphql` agent tool) and `memory` (deterministic test adapter) |
| Optional extensions | HTTP JSON API (SPEC §13.7) via `cohttp-async`; env-gated live e2e harness (SPEC §17.8). **No SSH workers in v1** (SPEC Appendix A deferred) |
| Status surface | Interactive `bonsai_term` dashboard: reference layout + issue selection, detail pane, manual refresh, quit |
| Name | opam package / executable / dune project `maestro` |
| Toolchain | Directory switch `_opam/` on `5.2.0+ox` (repos `ox` + `default`); pinned transitively by `bonsai_term`'s `= v0.18~preview.*` constraints |
| Reproducibility | `opam lock ./maestro.opam` → committed `maestro.opam.locked`; restore flow documented in README (the `ox` repo must be named at `switch create` time — lock files do not record repositories) |

Hard constraint from discussion: **if `cohttp-async` (or `yaml`) fails to build under the OxCaml
compiler, stop and confer** — do not silently substitute a hand-rolled replacement.

## 2. What Symphony is (compressed)

A single-process daemon that: loads a repo-owned `WORKFLOW.md` (YAML front matter → typed config,
Markdown body → strict prompt template) with hot-reload and last-known-good fallback (SPEC §5, §6.2);
polls an issue tracker, sorts candidates (priority 1–4 asc, then oldest `created_at`, then
identifier; SPEC §8.2), and dispatches under global + per-state concurrency limits; creates
sanitized per-issue workspaces with lifecycle hooks (SPEC §9); drives a Codex app-server subprocess
over newline-delimited JSON-RPC through multi-turn sessions (SPEC §10); reconciles every tick
(terminal → kill + clean workspace, unroutable → kill only, stalled → kill + retry; SPEC §8.5);
retries with 1 s continuation delay after clean exits and `min(10s·2^(n−1), cap)` backoff after
failures (SPEC §8.4); and exposes structured logs, a snapshot API, an optional HTTP API, and a
status surface (SPEC §13).

## 3. Repository layout

```
dune-project            (lang dune 3.x, name maestro)
maestro.opam            (deps; lock file alongside)
PLAN.md                 (this file)
README.md               (setup, restore-from-lock, trust posture, Linear adapter profile)
vendor/symphony/        (submodule: spec + reference)
bin/                    (main.ml — executable wrapper, no .mli needed beyond wrapper rule)
lib/
  template/             strict mini-Liquid engine
  workflow/             WORKFLOW.md loader, config schema, workflow store (watch/reload)
  tracker/              Issue model, adapter interface, memory adapter
  linear/               Linear GraphQL client, normalization, linear_graphql tool
  workspace/            keys, path safety, hooks
  codex/                app-server protocol client
  orchestrator/         scheduling state machine
  observability/        log setup, event humanizer, snapshot presenter (JSON)
  http/                 cohttp-async server (api/v1 + dashboard page)
  tui/                  bonsai_term app
  maestro/              wiring: startup sequence, CLI command
test/                   per-library expect tests + fixtures (fake codex scripts, workflows)
```

Dune library names `maestro_template`, `maestro_workflow`, … Every non-test `.ml` gets an `.mli`
except library-name wrapper modules. All files `open! Core` then `open! Async` where Async is used.

## 4. Concurrency architecture

Async throughout (forced by `bonsai_term`; matches house style). The orchestrator is a **single
eager event loop**: one `Pipe.Reader.t` of events consumed by an explicit `Pipe.iter` folding an
immutable `State.t` (single-authority mutation, SPEC §7.4). Timers, workers, HTTP handlers, and the
TUI all hold the writer end. Events:

```
Tick | Poll_now of refresh_reply Ivar.t
| Worker_runtime_info of { issue_id; workspace_path }
| Codex_update of { issue_id; update : Codex.Update.t }
| Worker_exited of { issue_id; outcome }
| Retry_due of { issue_id; token : Retry_token.t }
| Snapshot_request of Snapshot.t Ivar.t
```

Workers are background Deferreds (`Monitor.try_with`), not processes. Each running entry keeps a
cancellation ivar and a handle to the codex `Process.t`; termination = fill ivar + kill subprocess
(SIGKILL floor), and every wait on the child is bounded with `Clock_ns.with_timeout`. Spans/clocks
are `Time_ns` / `Clock_ns` everywhere; wall-clock timestamps (`started_at`, event times) are
`Time_ns.t` converted at presentation boundaries.

## 5. Component designs

### 5.1 `template` — strict prompt rendering (SPEC §5.4, §12)

No OCaml Liquid engine exists. SPEC requires only *strict* rendering ("Liquid-compatible semantics
are sufficient"); the reference workflows use `{{ path.to.var }}` and `{% if %}/{% else %}/{% endif %}`
only. Implement a small engine over a JSON-ish value tree (`Jsonaf.t`): interpolation, `if/else`
(truthiness: absent/null/false are false; everything else true, Liquid-style), `for x in list`.
**Any** `|` filter is an unknown-filter error; unknown variable paths are render errors — the two
MUSTs hold trivially. Errors: `Template_parse_error` / `Template_render_error` via `Or_error` tags.
Inputs: `issue` (all normalized fields, nested lists preserved) and `attempt` (always bound; null on
first run — strict mode must not trip on it; ref behavior). Lists render as concatenation (Liquid
behavior, pinned by reference tests). Timestamps render as RFC 3339 strings.

### 5.2 `workflow` — loader, config, store (SPEC §5, §6)

*Loader* (ref: `workflow.ex`): line-split on any line break; front matter iff first line is exactly
`---`, until next exact `---` (unterminated ⇒ all-front-matter, empty prompt — accepted); no leading
`---` ⇒ whole file is prompt, empty config. Whitespace-only front matter ⇒ empty map. YAML via the
`yaml` opam package; decode-to-non-map ⇒ `workflow_front_matter_not_a_map`. Prompt = remaining lines
joined + trimmed. Errors: `missing_workflow_file`, `workflow_parse_error`,
`workflow_front_matter_not_a_map`.

*Config schema* (ref: `config/schema.ex`): typed records per section with these defaults —
`polling.interval_ms` 30000 (>0); `workspace.root` `<tmp>/symphony_workspaces`; `agent`:
max_concurrent_agents 10, max_turns 20, max_retry_backoff_ms 300000, max_concurrent_agents_by_state
{} (keys trim+lowercase); `codex`: command "codex app-server" (non-blank required), approval_policy
= string **or** JSON map, default `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`,
thread_sandbox "workspace-write", turn_sandbox_policy null (passthrough map when set),
turn_timeout_ms 3600000, read_timeout_ms 5000, stall_timeout_ms 300000 (any integer accepted; ≤0
disables stall detection per SPEC §5.3.6 — looser than the ref's ≥0 validation, §7); `hooks.*` scripts null, timeout_ms 60000; `observability`: dashboard_enabled true,
refresh_ms 1000; `server`: port null (off), host "127.0.0.1"; `tracker`: kind (required),
provider {}, required_labels [] (trim+lowercase+dedup at parse), active/terminal states — defaults
`["Todo","In Progress"]` / `["Closed","Cancelled","Canceled","Duplicate","Done"]` injected for
kinds `linear` and `memory` only. Legacy top-level `tracker.{endpoint,api_key,project_slug,assignee}`
merge into `provider` with provider winning. Unknown top-level keys ignored (SPEC §5.3).

*$VAR resolution* (ref-exact): a value is an env reference iff the whole string is `$NAME`,
`NAME ~ ^[A-Za-z_][A-Za-z0-9_]*$`. Secrets: `api_key` falls back to env `LINEAR_API_KEY`, `assignee`
to `LINEAR_ASSIGNEE`; env set-to-empty defeats the fallback (⇒ missing); resolution at parse time,
centralized in this library (no ad-hoc env reads elsewhere). Paths: only `workspace.root` — after
`$VAR`/`~` expansion, a relative root resolves against **the directory containing the selected
WORKFLOW.md** and the effective root is normalized to an absolute path before any containment check
or workspace creation (SPEC §5.3.3 MUST; the reference's cwd-relative `Path.expand` contradicts the
spec — divergence, §7). `codex.command` gets no resolution (shell expands).
`secret_environment_names` = `["LINEAR_API_KEY"] ∪ {$VARs referenced by provider.api_key}` for
linear; `[]` otherwise — consumed by the codex launcher for child-env scrubbing.

*Store* (ref: `workflow_store.ex`): reload check = stamp `(mtime, size, content-hash)`, polled every
1 s **and** re-checked synchronously on every config read (SPEC §6.2 "re-validate defensively").
Parse+validate must succeed atomically to swap; failures keep last-known-good and log; startup is
strict (invalid WORKFLOW.md refuses to boot). Validation preflight (SPEC §6.3): loadable file,
supported `tracker.kind`, adapter accepts provider config, non-empty `codex.command`.

### 5.3 `workspace` — keys, safety, hooks (SPEC §9)

Key: replace chars outside `[A-Za-z0-9._-]` with `_`; iff sanitization changed the identifier,
append `--` + first 16 lowercase-hex chars of SHA-256 of the *original* identifier (64 bits, SPEC
§4.2). SHA-256 via the `sha` package (chosen over `digestif`, whose pure-OCaml fallback fails to
typecheck under OxCaml's mode system; `sha` 1.15.4 builds cleanly); expect tests pin known digests. Containment: canonicalize (segment-wise symlink resolution tolerating nonexistent
suffixes, via Async `Unix.lstat`/`readlink`), then distinguish `workspace_equals_root` /
containment-ok / `workspace_symlink_escape` / `workspace_outside_root`, comparing with trailing-`/`
prefixes. Create/reuse: existing dir reused as-is; non-directory debris replaced; `created_now`
gates `after_create`. Hooks: `Process.create ~prog:"sh" ~args:["-lc"; script]` cwd=workspace, no
injected env; stdout and stderr collected separately (Async exposes two readers — there is no
merge option) and combined into one transcript for logs and error payloads; timeout via
`Clock_ns.with_timeout` then SIGKILL (improves on ref, which only abandons the wait). Failure semantics: `after_create`/`before_run` fatal to
creation/attempt; `after_run`/`before_remove` logged + ignored. Startup terminal sweep and
terminal-transition cleanup call `remove` (validates containment, runs `before_remove`, `rm -rf`).

### 5.4 `tracker` + `linear` (SPEC §11)

`Issue.t`: exactly SPEC §4.1.1 (id, native_ref, identifier, title, description, priority, state,
branch_name, url, assignee_id, labels, blocked_by, dispatchable, created_at, updated_at).
`Issue.routable issue ~required_labels` = dispatchable && every label present (trim+lowercase both
sides). Adapter = a record of functions built from effective tracker settings:
`{ fetch_issues_by_states; fetch_issues_by_ids; secret_environment_names; agent_tool_specs;
execute_agent_tool; validate_config }` (registry maps kind → builder; unsupported kind ⇒
`unsupported_tracker_kind`). `execute_agent_tool` takes `~context:(issue : Issue.t)` — the SPEC
§10.5 hook shape — threaded from the codex client's `item/tool/call` handler with the running
entry's current issue snapshot (so adapters see `native_ref` without teaching the orchestrator
provider semantics). Tool bindings are snapshotted per codex session so mid-session reloads cannot
swap tools (SPEC §10.5).

*Memory adapter*: issues injected by tests (setter on a registry); state match trim+lowercase; id
match exact; preserves configured order.

*Linear adapter* (ref-exact; profile documented in README per SPEC §11.2):
- Transport: cohttp-async POST to `provider.endpoint` (default `https://api.linear.app/graphql`),
  header `Authorization: <raw key>` (no `Bearer`), 30 s connect timeout (ref) **plus a 120 s
  overall per-request deadline** (divergence, §7 — every external wait gets an explicit bound),
  `request_fun` injection seam for tests. TLS requires `async_ssl` (conduit-async treats it as
  optional and silently selects a no-TLS dummy backend without it) — it is a hard dependency,
  verified by a real HTTPS smoke request at milestone 4.
- Poll query: filter `project.slugId eq` + `state.name in`, page size 50, cursor pagination
  (`hasNextPage` + missing cursor ⇒ `linear_missing_end_cursor`). By-ids: batches of 50,
  project-scoped, results re-sorted to request order. Empty inputs short-circuit to `Ok []` with no
  request (SPEC §11.1).
- Malformed-record asymmetry (SPEC §11.1): poll path drops + warns; by-ids path fails the fetch.
  Valid iff id/identifier/title/state.name non-blank.
- Normalization: labels trim+lowercase+dedup, blanks dropped; priority integers only; RFC 3339
  timestamps else null; `blocked_by` from inverse `blocks` relations; `native_ref` = null.
- `dispatchable` = assignee-filter match (unset ⇒ everyone; `"me"` ⇒ viewer-id query per fetch;
  else exact `assignee_id` match) && not (state=="todo" && any blocker non-terminal; blocker with
  missing state counts as blocking).
- `linear_graphql` tool: input = raw query string or `{query, variables?}`; response envelope
  `{"success": bool, "output": <pretty JSON string>, "contentItems":[{"type":"inputText","text":…}]}`;
  GraphQL `errors` ⇒ success=false with body preserved; specific error messages per ref for
  missing query/args/variables/auth/status/transport; unknown tool name ⇒ failure listing
  `supportedTools`. Executes host-side with the bound settings snapshot — the child never sees the
  token.

### 5.5 `codex` — app-server client (SPEC §10)

Wire protocol (ref-exact): newline-delimited JSON objects, no `jsonrpc` field; fixed client request
ids `initialize`=1, `thread/start`=2, `turn/start`=3 (3 reused per turn); everything else we send is
a response `{id, result}`. Launch: `bash -lc "unset <secrets> && exec <codex.command>"` (unset after
profile load), cwd = workspace (validated: canonical containment, equals-root and symlink-escape
rejected), child env = current env minus secret names, line-buffered reads with a 10 MB cap.

Handshake: `initialize` (clientInfo name `maestro`, `capabilities.experimentalApi=true`) → await id
1 (per-response `read_timeout_ms`) → `initialized` notification → `thread/start`
`{approvalPolicy, sandbox, cwd, dynamicTools}` → `thread.id`. Turn: `turn/start` `{threadId, input:
[{type:text,text}], cwd, title:"<identifier>: <title>", approvalPolicy, sandboxPolicy}` → `turn.id`;
`session_id = "<thread_id>-<turn_id>"`.

The child's **stderr gets its own reader**, consumed as diagnostics (logged, warning iff error-ish)
and never fed to the JSON-RPC line parser — SPEC §10.3 requires the separation and §17.5 tests it;
the reference merges stderr into stdout, a spec violation we do not copy (§7).

Turn loop: dispatch on `method` — `turn/completed` ⇒ ok; `turn/failed`/`turn/cancelled` ⇒ error;
approvals: `item/commandExecution/requestApproval` + `item/fileChange/requestApproval` (decision
`acceptForSession`) and legacy `execCommandApproval`/`applyPatchApproval` (decision
`approved_for_session`) — auto-answered iff `approval_policy` is the literal string `"never"`, else
the turn hard-fails with `approval_required`; `item/tool/requestUserInput` always answered
(approve-ish option label when auto-approving, else the canned non-interactive string; question
missing an id ⇒ `turn_input_required`); `item/tool/call` executes the bound adapter tool and
replies regardless of policy; `mcpServer/elicitation/request` and the `turn/*` needs-input
heuristics ⇒ `turn_input_required`. Non-JSON lines logged (warning iff error-ish regex), `{`-prefixed
ones also emit `malformed`. Timeouts: `read_timeout_ms` per awaited response; `turn_timeout_ms` as a
**wall-clock total per turn** (SPEC §10.6; deviates from ref's per-message inactivity reset — see
§7). Default turn sandbox policy when unset: `workspaceWrite` rooted at the canonical workspace,
`networkAccess:false` (ref-exact shape); explicit maps pass through verbatim.

Events emitted upstream (SPEC §10.4 + ref): session_started, startup_failed, turn_completed/
failed/cancelled, turn_input_required, approval_required, approval_auto_approved,
tool_input_auto_answered, tool_call_completed/failed, unsupported_tool_call, notification,
other_message, malformed, turn_ended_with_error — each with timestamp, os-pid, optional usage map.

Worker turn loop (ref: `agent_runner.ex`): one session per run; turn 1 = rendered workflow prompt;
turns ≥2 = the fixed continuation-guidance prompt (never resend the task; SPEC §7.1); after each
successful turn re-fetch the issue — continue iff still active + routable and `turn < max_turns`;
refresh failure fails the run; `after_run` hook always runs; any error fails the attempt for the
orchestrator to retry.

### 5.6 `orchestrator` (SPEC §7, §8, §16)

State (immutable record): `poll_interval_ms`, `max_concurrent_agents` (both refreshed from config
every tick), `running : Running_entry.t String.Map.t`, `claimed : String.Set.t`,
`blocked : Blocked_entry.t String.Map.t`, `retry : Retry_entry.t String.Map.t`,
`completed : String.Set.t` (write-only bookkeeping), `codex_totals`, `rate_limits`, poll bookkeeping
(due-at, checking flag, tick token). Running entries carry session metadata, token counters +
per-component high-water marks, turn_count, retry_attempt, started_at, workspace_path, cancel ivar.

Tick: reconcile running (stall detection first: elapsed since `last_codex_timestamp`|`started_at` >
`stall_timeout_ms` ⇒ kill + retry, or block if the entry looks input-blocked) and blocked issues;
preflight-validate; fetch candidates by active states (skip when zero slots free — deliberate
divergence from ref, see §7); sort; dispatch while slots remain, revalidating each issue by id fetch
just before spawn. Eligibility: candidate fields non-blank, state ∈ active ∖ terminal, routable, not
running/claimed/blocked, global + per-state slots free (per-state counts by live normalized
`running[..].issue.state`).

Retries: continuation (normal exit, not input-blocked) ⇒ attempt 1, 1000 ms; failures ⇒
`min(10_000 · 2^min(attempt−1,10), max_retry_backoff_ms)`. Retry firing (token-guarded): re-fetch by
id — **fetch error ⇒ requeue attempt+1 with error "retry poll failed: …", claim retained** (the
backoff chain survives tracker outages; SPEC §16.6); missing ⇒ release claim; terminal ⇒ clean
workspace + release; active + routable ⇒ dispatch if slots else requeue attempt+1 with "no
available orchestrator slots"; else release. Claims are held through backoff; after a *successful*
refresh, every skip path in dispatch-from-retry releases the claim (fixing the ref's claim-leak
quirk, §7).

Tracker-error tolerance (SPEC §11.4, §8.5): candidate-fetch failure ⇒ log and skip dispatch for
this tick only; a failed by-ids reconciliation refresh ⇒ keep **all** running and blocked entries
untouched and retry next tick (never conflate a fetch *error* with an *empty/partial result* — only
ids missing from a successful refresh are terminated); startup terminal-sweep fetch failure ⇒
warn and continue startup. Worker exit while input-blocked (last event turn_input_required /
approval_required / MCP elicitation) ⇒ move to `blocked` (claim retained) instead of retrying;
blocked issues are reconciled each tick (terminal ⇒ cleanup + release; unroutable/other ⇒ release;
active ⇒ refresh in place). Restart clears blocked (in-memory by design, SPEC §14.3).

Token accounting (ref + `docs/token_accounting.md`): accept only absolute-total payloads, searched
in order `params.msg.payload.info.total_token_usage`, `params.msg.info.total_token_usage`,
`params.tokenUsage.total`, `tokenUsage.total`, falling back to `turn/completed` usage only; delta =
`max(0, new − watermark)` per component, watermarks monotonic; deltas accumulate into per-entry and
global totals; `seconds_running` added at session end; `last_token_usage`-style deltas ignored.
Rate limits: latest matching payload (has `limit_id`/`limit_name` + primary/secondary/credits)
stored verbatim, depth-first search.

Snapshot (SPEC §13.3): running rows (incl. turn_count, tokens, last event/message, runtime seconds),
retrying rows (due_in_ms), blocked rows, codex_totals (live aggregate = ended + active elapsed),
rate_limits, polling status. Served via `Snapshot_request` events; consumers (TUI, HTTP) never touch
state directly. `Poll_now` implements coalesced refresh (SPEC §13.7.2 `/refresh` semantics).

### 5.7 `observability`

Logging: ppx_log over Async `Log.Global`; sink = rotating log file (`log/maestro.log`,
10 MB × 5, overridable via `--logs-root`); console output removed when the TUI owns the terminal.
Required context: `issue_id` + `issue_identifier` on issue logs, `session_id` on session logs
(SPEC §13.1). Humanizer: port the reference's event→one-line summary mapping (turn/item/delta/
approval/token/rate-limit event classes, 140-char cap, ANSI stripped) — shared by TUI and HTTP
presenter so wording matches. Presenter: snapshot → the SPEC §13.7.2 JSON shapes (jsonaf).

### 5.8 `http` (SPEC §13.7)

cohttp-async server, loopback bind by default, enabled iff CLI `--port` (wins) or `server.port`;
port 0 = ephemeral (actual port shown in TUI/logs). Endpoints: `GET /api/v1/state` (200 always;
snapshot errors embedded), `GET /api/v1/<issue_identifier>` (404 `issue_not_found` when unknown),
`POST /api/v1/refresh` (202 `{queued, coalesced, requested_at, operations}`), 405 on wrong methods,
error envelope `{"error":{code,message}}`. Dashboard page at `/`: single self-contained HTML file
(inline CSS/JS polling `/api/v1/state`) — no external assets.

### 5.9 `tui` — bonsai_term interactive dashboard

In-process app on the orchestrator snapshot: pulls on a `refresh_ms` clock plus an update bus
(orchestrator pokes after each state change; bus is fan-out-safe, one pipe per subscriber).
Layout: header (agents n/max, token totals, throughput, runtime, rate limits, project URL,
dashboard URL when HTTP is up, next-poll countdown); left pane lists Running / Backoff / Blocked
with selection (↑↓/j k); right pane shows the selected issue (state, session, tokens, workspace,
recent humanized events); keys: `⏎` focus detail, `r` ⇒ `Poll_now`, `q` quit cleanly. Disabled when
not a tty or `observability.dashboard_enabled=false` (then logs keep the console). Snapshot tests
via `bonsai_term_test` with dynamic fields (ages, countdowns) driven by a fixed time source.

### 5.10 `maestro` + `bin` — CLI and lifecycle (SPEC §17.7)

`Command.async_or_error`. Flags: mandatory acknowledgement
`--i-understand-that-this-will-be-running-without-the-usual-guardrails` (banner + exit 1 without),
`--logs-root`, `--port`, optional positional workflow path (default `./WORKFLOW.md`; nonexistent ⇒
clean error). Startup order: load+validate workflow (strict) → configure logging → start
orchestrator (startup terminal-workspace sweep, then immediate tick) → start HTTP (if enabled) →
start TUI (if tty+enabled). Shutdown: TUI quit or signal ⇒ stop dispatch, kill workers (bounded
waits), exit 0 on clean stop, nonzero on startup failure.

## 6. Trust & safety posture (documented per SPEC §1, §10.5, §15)

Same posture as the reference, stated in README: intended for **trusted environments**; approval
and sandbox policies are passed through to Codex verbatim; client-side auto-approval only when
`approval_policy: "never"`; user-input-required turns never stall — they end the run and park the
issue as `blocked` until an operator intervenes; workspace containment + sanitized keys enforced
before launch; tracker credentials resolved host-side, scrubbed from the child environment
(spawn-env removal + `unset` post-profile), never required in the child; hooks are trusted config
with mandatory timeouts.

## 7. Deliberate divergences

| Point | Reference | maestro | Why |
|---|---|---|---|
| Turn timeout semantics | inactivity reset per message | wall-clock total per turn | SPEC §10.6 says "total turn stream timeout"; stall detection separately covers inactivity |
| Fetch when zero slots | full candidate fetch, then slot check | skip fetch | avoids a pointless provider roundtrip per tick |
| Retry-path claim leak | dispatch-skip after retry can strand the claim | every skip path releases or requeues explicitly | correctness; SPEC §7.1 Released state |
| Invalid per-state limit entries | config validation error | ignored (logged) | SPEC §5.3.5 says invalid entries are ignored |
| Hook timeout | abandons the wait | SIGKILL the hook process | bounded cleanup, no orphan processes |
| Relative `workspace.root` base | cwd-relative `Path.expand` | resolved against the WORKFLOW.md directory, normalized absolute | SPEC §5.3.3 MUST; the reference contradicts it |
| Codex child stderr | merged into stdout | separate diagnostic reader, never parsed as protocol | SPEC §10.3 requires separation; §17.5 core test bullet |
| `stall_timeout_ms < 0` | config validation error | accepted; any ≤ 0 disables stall detection | SPEC §5.3.6 defines ≤ 0 as "disabled" |
| Liquid filters | standard Solid filter set renders | all filters rejected (v1) | our engine implements none; strict-mode MUSTs hold either way. Compatibility caveat: a WORKFLOW.md using standard filters works on the reference but not here — documented in README |
| Linear request deadline | 30 s connect timeout only | connect 30 s + 120 s overall deadline | unbounded external waits are not acceptable |
| SSH workers, sparkline, LiveView | present | absent (v1) | scope decision |

Everything else follows the reference where SPEC says implementation-defined, including the exact
config defaults, approval decision strings, workspace-key hash format, dashboard wording, and the
Linear adapter's error vocabulary (mapped to SPEC §11.4 categories in the README profile).

## 8. Testing strategy (SPEC §17)

- `ppx_expect` throughout; values pretty-printed whole (no boolean collapses); unstable fields
  scrubbed at the boundary. `dune build && dune runtest` green before any milestone closes.
- §17.1 workflow/config: parsing, precedence, defaults, `$VAR`, `~` expansion, relative
  `workspace.root` resolving against the WORKFLOW.md directory, reload/last-known-good, strict
  template failures.
- §17.2 workspace: deterministic keys, collision fixtures (`team/a-1` vs `team_a-1`), hook matrix,
  symlink-escape/containment, non-directory debris.
- §17.3 adapter: memory + Linear (pagination order, empty-input short-circuit, malformed-record
  asymmetry, label/priority/timestamp normalization, dispatchable derivation incl. `"me"`,
  by-id reorder) against an injected transport.
- §17.4 orchestrator: sort order, eligibility, per-state slots, continuation vs failure backoff,
  cap, stall, reconciliation transitions (terminal/unroutable/missing), tracker-failure tolerance
  (candidate-fetch failure skips the tick; refresh failure keeps workers and blocked entries;
  retry-fire fetch error requeues attempt+1; startup-sweep failure continues), blocked lifecycle,
  slot exhaustion requeue, token high-water accounting, snapshot shape.
- §17.5 codex client: scripted fake app-server shell scripts (as the reference does) asserting
  everything we *send* (initialize, dynamicTools, approval decisions, requestUserInput answers,
  sandbox passthrough, unset-secrets survival of `bash -l` profiles) and everything we *do* on
  server behavior (timeouts, port exit, tool calls incl. the issue context reaching the adapter,
  input heuristics, stderr noise never disturbing the protocol stream).
- §17.6 observability: humanizer table, presenter JSON, log-sink failure tolerance.
- §17.7 CLI: ack flag, path precedence, error strings, exit codes.
- §17.8 live e2e (extension): env-gated (`MAESTRO_RUN_LIVE_E2E=1` + `LINEAR_API_KEY` + codex CLI);
  creates a real Linear project/issue, runs a real agent, asserts artifact + comment + state
  transition; loudly reported as skipped otherwise.
- TUI: `bonsai_term_test` snapshot tests with a fixed time source.

## 9. Milestones

Each milestone ends with a clean `dune build` + `dune runtest` + `dune fmt` and a commit.

0. **Scaffold**: dune-project, opam file, deps installed into the switch (gate: `cohttp-async`,
   `async_ssl`, `yaml`, `bonsai_term` all build — stop and confer on failure), `opam lock`,
   `.gitignore`, submodule + PLAN.md committed.
1. **template**: engine + strict-mode tests.
2. **workflow**: loader, schema, `$VAR`, store with reload/last-known-good.
3. **workspace**: keys, path safety, hooks.
4. **tracker**: Issue, adapter interface, memory adapter; **linear**: client, normalization, tool;
   one real HTTPS request against api.linear.app (expect 400/401 unauthenticated) to prove the TLS
   backend is live.
5. **codex**: protocol client + fake-server harness.
6. **orchestrator**: state machine + full conformance suite.
7. **observability**: logging, humanizer, presenter.
8. **http**: API + dashboard page.
9. **tui**: interactive dashboard + snapshot tests.
10. **wiring**: CLI, startup/shutdown, startup cleanup sweep; end-to-end memory-adapter run with a
    fake codex script.
11. **hardening**: live e2e harness, README (setup/restore, adapter profile, trust posture),
    SPEC §18.1 checklist audit, final `opam lock`.

## 10. Risks

- **Third-party packages under the OxCaml fork**: resolved at milestone 0 — `yaml` 3.2.0,
  `cohttp-async` 6.2.1 + `async_ssl`, and `sha` 1.15.4 all build; `digestif` does not (mode-system
  type errors in its pure-OCaml sources) and was replaced by `sha`. Remaining exposure is future
  upgrades, pinned away by the lock file.
- **bonsai_term preview API**: `v0.18~preview` moves; docs are thin. Mitigation: pin via lock file,
  lean on `bonsai_term_examples`/`bonsai_term_components`, keep the TUI behind the snapshot
  presenter so churn stays local.
- **Codex protocol drift**: we implement the protocol version the reference targets; SPEC §10 says
  the targeted Codex version controls. The fake-server suite pins our behavior; a future codex
  upgrade is a deliberate follow-up.
- **OxCaml compiler build friction**: already hit missing `autoconf`/`rsync` depexts; documented in
  README setup notes.
