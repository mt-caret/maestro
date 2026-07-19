---
# Example WORKFLOW.md for maestro. Copy to WORKFLOW.md and edit for your repo.
# Every value below is optional except tracker.kind and (for linear) the provider auth.

tracker:
  kind: linear
  provider:
    # A Linear personal API key. Prefer a $VAR reference over a literal so the token
    # never sits in a repo-readable file; it is resolved host-side and scrubbed from the
    # coding-agent's environment.
    api_key: $LINEAR_API_KEY
    project_slug: "your-project-slug"
    # Optional assignee filter: a Linear user id, or "me" (resolved via the viewer query).
    # assignee: me
  required_labels: []
  active_states: [Todo, In Progress]
  terminal_states: [Done, Cancelled, Canceled, Duplicate, Closed]

polling:
  interval_ms: 30000

workspace:
  # Relative paths resolve against this file's directory; ~ and $VAR are expanded.
  root: ~/maestro-workspaces

hooks:
  # Runs once when a workspace directory is first created. Failure aborts creation.
  after_create: |
    git clone --depth 1 https://github.com/your-org/your-repo .

agent:
  max_concurrent_agents: 10
  max_turns: 20
  max_retry_backoff_ms: 300000

codex:
  command: codex app-server
  # "never" auto-approves command and file-change requests for the session (high-trust).
  # Omit for the strict default, which fails a run that needs approval.
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true

# Optional HTTP dashboard + JSON API (also enable with --port). Loopback by default.
# server:
#   port: 8080
---
You are working on {{ issue.identifier }}: {{ issue.title }}.

{% if attempt %}This is follow-up attempt {{ attempt }}; resume from the workspace state
rather than starting over.{% endif %}

State: {{ issue.state }}
{% if issue.description %}
{{ issue.description }}
{% else %}
No description was provided.
{% endif %}

Complete the work described by the issue. Use the `linear_graphql` tool to move the issue
to its next state and to post progress. Finish only when the work is done or you are
genuinely blocked.
