---
# maestro developing maestro — dogfood workflow.
#
# Run from the repo root:  maestro --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md
# (add --port 8080 for the HTTP dashboard). File issues in the "Maestro" Linear project and
# maestro will pick them up.
#
# Operator prerequisites (the daemon's environment is inherited by the workspace hooks):
#   - export LINEAR_API_KEY=<your Linear key>   (never commit the literal key)
#   - opam on PATH, and the system depexts already installed: autoconf, rsync, libgmp-dev
#   - git identity configured (user.name/user.email) and `gh` authenticated with push access
#     to github.com/mt-caret/maestro, so the agent can push branches and open PRs.

tracker:
  kind: linear
  provider:
    api_key: $LINEAR_API_KEY
    project_slug: "6a3e214c502f" # Maestro project (team MTA)
  # Todo / In Progress are dispatchable. "In Review" is deliberately excluded: moving an
  # issue there parks it for human review (maestro stops working it), matching Symphony's
  # Human-Review handoff pattern.
  active_states: [Todo, In Progress]
  terminal_states: [Done, Canceled, Duplicate]

workspace:
  # Outside the source tree — each per-issue workspace is its own clone + switch.
  root: ~/maestro-workspaces

hooks:
  # The switch build (OxCaml compiler + the full Jane Street dependency set) is slow, so the
  # hook timeout is an hour. after_create runs once per new workspace; failure aborts it.
  timeout_ms: 3600000
  after_create: |
    set -eux
    export OPAMYES=1 OPAMSOLVERTIMEOUT=600
    git clone --recurse-submodules https://github.com/mt-caret/maestro.git .
    # A fresh directory-local switch on the OxCaml compiler, pinned by the committed lock.
    opam switch create . 5.2.0+ox \
      --repos ox=git+https://github.com/oxcaml/opam-repository.git,default \
      --no-install --assume-depexts
    opam install . --locked --deps-only --with-test --assume-depexts
  # Refresh remote refs before every attempt so the agent's rebase onto origin/main picks
  # up branches merged while this issue was in flight. Non-fatal: a transient network blip
  # must not abort the attempt (the agent fetches again itself).
  before_run: |
    git fetch --prune origin || true

agent:
  # Builds are heavy; keep concurrency modest.
  max_concurrent_agents: 2
  max_turns: 20
  max_retry_backoff_ms: 300000

codex:
  command: codex app-server
  approval_policy: never
  # Cold start warmup exceeds the 5s default (see README operational notes).
  read_timeout_ms: 30000
  # A build+test cycle inside one turn can be long; a silent build must not trip the stall
  # detector, so both are generous.
  turn_timeout_ms: 1800000
  stall_timeout_ms: 1800000
  # git/opam need network, and the OS sandbox (landlock/seccomp) is unavailable in many
  # dev/CI environments; use full access. Tighten these if your host supports the sandbox.
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---
You are an autonomous engineer working on **maestro**, an OxCaml implementation of the
Symphony coding-agent orchestration spec. You have been assigned {{ issue.identifier }}:
"{{ issue.title }}", currently in the "{{ issue.state }}" state.

{% if issue.description %}Issue details:
{{ issue.description }}
{% else %}No description was provided; infer the scope from the title and the codebase.{% endif %}

## Policy

Todo means the issue is available. Move it to In Progress when real work starts. In Review is the
human handoff state and stops agent dispatch. Done is terminal.

Read `AGENTS.md` and `PLAN.md` before editing. Keep the change limited to the assigned issue and
all blocking review feedback. Do not modify `vendor/symphony` or `maestro.opam.locked` unless the
issue is about the spec or dependencies. Use the injected `linear_graphql` tool for all Linear
access.

This is an unattended session. Resolve problems independently. If missing access, an ambiguous
conflict, or a failing dependency truly blocks progress, record the exact blocker in the workpad,
move the issue to In Review, and stop. File a separate Maestro issue for unrelated problems.

Work is done when the branch is current with `origin/main`, the requested change and all review
feedback are complete, formatting and tests pass, and the separate `AGENTS.md` style review is
recorded. Hand off through one complete pull request and move the issue to In Review.

## Procedures

Load the matching canonical procedure when its trigger occurs:

- At the start of every pass, follow `docs/procedures/starting-a-pass.md`.
- When recording or reconciling progress, follow `docs/procedures/maintaining-the-workpad.md`.
- On a rework pass, follow `docs/procedures/addressing-review-feedback.md`.
- When authoring or reviewing source with CR comments, follow
  `docs/procedures/cr-conversations.md`.
- When work is ready, follow `docs/procedures/handing-off-a-pr.md`.

These files contain the operational commands and are the sole source of procedure. Do not infer a
different process from this policy summary.
