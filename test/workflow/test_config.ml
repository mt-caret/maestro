open! Core
open Maestro_workflow

let getenv_of_alist env name = List.Assoc.find env name ~equal:String.equal

let parse ?(workflow_dir = "/repo") ?(env = []) contents =
  Workflow.parse_contents contents ~workflow_dir ~getenv:(getenv_of_alist env)
;;

let show_config ?workflow_dir ?env contents =
  match parse ?workflow_dir ?env contents with
  | Ok loaded ->
    let%tydi { config; prompt_template = _; front_matter = _ } = loaded in
    print_s [%sexp (config : Config.t)]
  | Error error -> print_s [%sexp (error : Error.t)]
;;

let%expect_test "minimal workflow: two keys to boot, everything else defaults" =
  show_config
    {|---
tracker:
  kind: memory
codex:
  command: codex app-server
---
Test workflow.|};
  [%expect
    {|
    ((tracker
      ((kind (memory)) (provider ()) (resolved_provider <opaque>)
       (required_labels ()) (active_states ((Todo "In Progress")))
       (terminal_states ((Closed Cancelled Canceled Duplicate Done)))
       (secret_environment_names ())))
     (polling ((interval 30s))) (workspace ((root /tmp/symphony_workspaces)))
     (hooks
      ((after_create ()) (before_run ()) (after_run ()) (before_remove ())
       (timeout 1m)))
     (agent
      ((max_concurrent_agents 10) (max_turns 20) (max_retry_backoff 5m)
       (max_concurrent_agents_by_state ())))
     (codex
      ((command "codex app-server")
       (approval_policy
        (Object
         ((reject
           (Object
            ((sandbox_approval True) (rules True) (mcp_elicitations True)))))))
       (thread_sandbox workspace-write) (turn_sandbox_policy ())
       (turn_timeout 1h) (read_timeout 5s) (stall_timeout (5m))))
     (observability ((dashboard_enabled true) (refresh 1s)))
     (server ((port ()) (host 127.0.0.1))) (warnings ()))
    |}]
;;

let%expect_test "prompt-only file: whole contents are the prompt, config all-default" =
  (match parse "Just a prompt.\nSecond line.\n" with
   | Error error -> print_s [%sexp (error : Error.t)]
   | Ok loaded ->
     let%tydi { config; prompt_template; front_matter = _ } = loaded in
     print_s
       [%message (prompt_template : string) ~kind:(config.tracker.kind : string option)]);
  [%expect
    {|
    ((prompt_template  "Just a prompt.\
                      \nSecond line.") (kind ()))
    |}]
;;

let%expect_test "front-matter structure errors" =
  (* Unterminated front matter: accepted, empty prompt. *)
  (match parse "---\ntracker:\n  kind: memory\n" with
   | Error error -> print_s [%sexp (error : Error.t)]
   | Ok loaded ->
     let%tydi { config; prompt_template; front_matter = _ } = loaded in
     print_s
       [%message (prompt_template : string) ~kind:(config.tracker.kind : string option)]);
  [%expect {| ((prompt_template "") (kind (memory))) |}];
  (* Whitespace-only front matter parses as an empty map. *)
  show_config "---\n   \n---\nprompt";
  [%expect
    {|
    ((tracker
      ((kind ()) (provider ()) (resolved_provider <opaque>) (required_labels ())
       (active_states ()) (terminal_states ()) (secret_environment_names ())))
     (polling ((interval 30s))) (workspace ((root /tmp/symphony_workspaces)))
     (hooks
      ((after_create ()) (before_run ()) (after_run ()) (before_remove ())
       (timeout 1m)))
     (agent
      ((max_concurrent_agents 10) (max_turns 20) (max_retry_backoff 5m)
       (max_concurrent_agents_by_state ())))
     (codex
      ((command "codex app-server")
       (approval_policy
        (Object
         ((reject
           (Object
            ((sandbox_approval True) (rules True) (mcp_elicitations True)))))))
       (thread_sandbox workspace-write) (turn_sandbox_policy ())
       (turn_timeout 1h) (read_timeout 5s) (stall_timeout (5m))))
     (observability ((dashboard_enabled true) (refresh 1s)))
     (server ((port ()) (host 127.0.0.1))) (warnings ()))
    |}];
  (* Non-map YAML front matter. *)
  show_config "---\n- just\n- a\n- list\n---\nprompt";
  [%expect {| workflow_front_matter_not_a_map |}];
  (* Invalid YAML. *)
  show_config "---\ntracker: [unclosed\n---\nprompt";
  [%expect
    {|
    (workflow_parse_error
     "error calling parser: did not find expected ',' or ']' character 0 position 0 returned: 0")
    |}]
;;

let%expect_test "the reference dogfood WORKFLOW.md front matter parses" =
  show_config
    ~env:[ "HOME", "/home/worker" ]
    {|---
tracker:
  kind: linear
  provider:
    project_slug: "symphony-0c79b11b75ea"
  required_labels: []
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---
Prompt body.|};
  [%expect
    {|
    ((tracker
      ((kind (linear))
       (provider
        ((project_slug (String symphony-0c79b11b75ea))
         (endpoint (String https://api.linear.app/graphql))))
       (resolved_provider <opaque>) (required_labels ())
       (active_states ((Todo "In Progress" Merging Rework)))
       (terminal_states ((Closed Cancelled Canceled Duplicate Done)))
       (secret_environment_names (LINEAR_API_KEY))))
     (polling ((interval 5s)))
     (workspace ((root /home/worker/code/symphony-workspaces)))
     (hooks
      ((after_create
        ( "git clone --depth 1 https://github.com/openai/symphony .\
         \nif command -v mise >/dev/null 2>&1; then\
         \n  cd elixir && mise trust && mise exec -- mix deps.get\
         \nfi\
         \n"))
       (before_run ()) (after_run ())
       (before_remove
        ("cd elixir && mise exec -- mix workspace.before_remove\n"))
       (timeout 1m)))
     (agent
      ((max_concurrent_agents 10) (max_turns 20) (max_retry_backoff 5m)
       (max_concurrent_agents_by_state ())))
     (codex
      ((command "codex --config shell_environment_policy.inherit=all app-server")
       (approval_policy (String never)) (thread_sandbox workspace-write)
       (turn_sandbox_policy
        ((Object ((type (String workspaceWrite)) (networkAccess True)))))
       (turn_timeout 1h) (read_timeout 5s) (stall_timeout (5m))))
     (observability ((dashboard_enabled true) (refresh 1s)))
     (server ((port ()) (host 127.0.0.1))) (warnings ()))
    |}]
;;

let secret_resolution ~env =
  match
    parse
      ~env
      {|---
tracker:
  kind: linear
  provider:
    api_key: "$MY_KEY"
    project_slug: proj
---
p|}
  with
  | Error error -> print_s [%sexp (error : Error.t)]
  | Ok loaded ->
    let%tydi { config; prompt_template = _; front_matter = _ } = loaded in
    let find name =
      List.Assoc.find config.tracker.resolved_provider name ~equal:String.equal
    in
    print_s
      [%message
        ""
          ~raw_api_key:
            (List.Assoc.find config.tracker.provider "api_key" ~equal:String.equal
             : Jsonaf.t option)
          ~resolved_api_key:(find "api_key" : Jsonaf.t option)
          ~secret_environment_names:
            (config.tracker.secret_environment_names : string list)]
;;

let%expect_test "$VAR secret resolution: set, set-to-empty defeats fallback, unset falls \
                 back"
  =
  (* Referenced variable set: its value wins; the raw provider keeps the literal $MY_KEY
     so config dumps never contain the secret. *)
  secret_resolution ~env:[ "MY_KEY", "sekret"; "LINEAR_API_KEY", "fallback" ];
  [%expect
    {|
    ((raw_api_key ((String $MY_KEY))) (resolved_api_key ((String sekret)))
     (secret_environment_names (LINEAR_API_KEY MY_KEY)))
    |}];
  (* Referenced variable set to empty: resolves to missing, defeating the fallback. *)
  secret_resolution ~env:[ "MY_KEY", ""; "LINEAR_API_KEY", "fallback" ];
  [%expect
    {|
    ((raw_api_key ((String $MY_KEY))) (resolved_api_key ())
     (secret_environment_names (LINEAR_API_KEY MY_KEY)))
    |}];
  (* Referenced variable unset: the documented LINEAR_API_KEY fallback applies. *)
  secret_resolution ~env:[ "LINEAR_API_KEY", "fallback" ];
  [%expect
    {|
    ((raw_api_key ((String $MY_KEY))) (resolved_api_key ((String fallback)))
     (secret_environment_names (LINEAR_API_KEY MY_KEY)))
    |}]
;;

let%expect_test "top-level tracker aliases merge into provider with provider winning" =
  (match
     parse
       {|---
tracker:
  kind: linear
  api_key: top-level-key
  project_slug: top-level-slug
  provider:
    project_slug: provider-wins
---
p|}
   with
   | Error error -> print_s [%sexp (error : Error.t)]
   | Ok loaded ->
     let%tydi { config; prompt_template = _; front_matter = _ } = loaded in
     print_s [%sexp (config.tracker.provider : (string * Jsonaf.t) list)]);
  [%expect
    {|
    ((project_slug (String provider-wins)) (api_key (String top-level-key))
     (endpoint (String https://api.linear.app/graphql)))
    |}]
;;

let%expect_test "required_labels are trimmed, lowercased, deduplicated; blanks are kept" =
  (match
     parse
       {|---
tracker:
  kind: memory
  required_labels: [" Bug ", "FEATURE", "bug", " "]
---
p|}
   with
   | Error error -> print_s [%sexp (error : Error.t)]
   | Ok loaded ->
     let%tydi { config; prompt_template = _; front_matter = _ } = loaded in
     print_s [%sexp (config.tracker.required_labels : string list)]);
  [%expect {| (bug feature "") |}]
;;

let%expect_test "per-state limits: keys normalized, invalid entries ignored with warnings"
  =
  (match
     parse
       {|---
tracker:
  kind: memory
agent:
  max_concurrent_agents_by_state:
    " Todo ": 3
    "In Progress": 2
    "": 5
    Rework: 0
    Merging: not-a-number
---
p|}
   with
   | Error error -> print_s [%sexp (error : Error.t)]
   | Ok loaded ->
     let%tydi { config; prompt_template = _; front_matter = _ } = loaded in
     print_s
       [%message
         ""
           ~limits:(config.agent.max_concurrent_agents_by_state : int String.Map.t)
           ~warnings:(config.warnings : Error.t list)]);
  [%expect
    {|
    ((limits (("in progress" 2) (todo 3)))
     (warnings
      (("ignoring invalid agent.max_concurrent_agents_by_state entry" (state "")
        "blank state name")
       ("ignoring invalid agent.max_concurrent_agents_by_state entry"
        (state Rework) "limit must be a positive integer")
       ("ignoring invalid agent.max_concurrent_agents_by_state entry"
        (state Merging) "limit must be a positive integer"))))
    |}]
;;

let%expect_test "per-state lookup falls back to the global limit" =
  (match
     parse
       {|---
tracker:
  kind: memory
agent:
  max_concurrent_agents: 7
  max_concurrent_agents_by_state:
    todo: 2
---
p|}
   with
   | Error error -> print_s [%sexp (error : Error.t)]
   | Ok loaded ->
     let%tydi { config; prompt_template = _; front_matter = _ } = loaded in
     print_s
       [%message
         ""
           ~todo:(Config.max_concurrent_agents_for_state config ~state:" TODO " : int)
           ~other:(Config.max_concurrent_agents_for_state config ~state:"Merging" : int)]);
  [%expect {| ((todo 2) (other 7)) |}]
;;

let show_root ?workflow_dir ?env root_yaml =
  match
    parse ?workflow_dir ?env [%string "---\nworkspace:\n  root: %{root_yaml}\n---\np"]
  with
  | Error error -> print_s [%sexp (error : Error.t)]
  | Ok loaded ->
    let%tydi { config; prompt_template = _; front_matter = _ } = loaded in
    print_s [%sexp (config.workspace.root : string)]
;;

let%expect_test "workspace.root: relative resolves against the WORKFLOW.md directory" =
  show_root ~workflow_dir:"/repo/subdir" "./workspaces";
  [%expect {| /repo/subdir/workspaces |}];
  show_root ~workflow_dir:"/repo/subdir" "workspaces";
  [%expect {| /repo/subdir/workspaces |}]
;;

let%expect_test "workspace.root: ~, $VAR, blank, and absolute forms" =
  show_root ~env:[ "HOME", "/home/worker" ] "~/ws";
  [%expect {| /home/worker/ws |}];
  show_root "/abs/path";
  [%expect {| /abs/path |}];
  show_root ~env:[ "WS_ROOT", "/from/env" ] "$WS_ROOT";
  [%expect {| /from/env |}];
  (* Unset or empty referenced variable falls back to the default root. *)
  show_root "$WS_ROOT";
  [%expect {| /tmp/symphony_workspaces |}];
  show_root ~env:[ "WS_ROOT", "" ] "$WS_ROOT";
  [%expect {| /tmp/symphony_workspaces |}];
  show_root {|""|};
  [%expect {| /tmp/symphony_workspaces |}];
  (* ~ with no HOME is an error rather than a literal directory named ~. *)
  show_root "~/ws";
  [%expect
    {|
    (invalid_workflow_config
     ("workspace.root uses ~ but HOME is not set" (root ~/ws)))
    |}]
;;

let%expect_test "codex settings: passthrough values and stall-timeout disabling" =
  (match
     parse
       {|---
tracker:
  kind: memory
codex:
  approval_policy: future-policy
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: futureSandbox
    anything: [1, 2]
  stall_timeout_ms: 0
---
p|}
   with
   | Error error -> print_s [%sexp (error : Error.t)]
   | Ok loaded ->
     let%tydi { config; prompt_template = _; front_matter = _ } = loaded in
     print_s [%sexp (config.codex : Config.Codex.t)]);
  [%expect
    {|
    ((command "codex app-server") (approval_policy (String future-policy))
     (thread_sandbox danger-full-access)
     (turn_sandbox_policy
      ((Object
        ((type (String futureSandbox))
         (anything (Array ((Number 1) (Number 2))))))))
     (turn_timeout 1h) (read_timeout 5s) (stall_timeout ()))
    |}]
;;

let%expect_test "negative stall_timeout_ms also disables (SPEC <= 0), not an error" =
  (match
     parse "---\ntracker:\n  kind: memory\ncodex:\n  stall_timeout_ms: -5\n---\np"
   with
   | Error error -> print_s [%sexp (error : Error.t)]
   | Ok loaded ->
     let%tydi { config; prompt_template = _; front_matter = _ } = loaded in
     print_s [%sexp (config.codex.stall_timeout : Time_ns.Span.t option)]);
  [%expect {| () |}]
;;

let%expect_test "validation errors aggregate across independent fields" =
  show_config
    {|---
tracker:
  kind: memory
polling:
  interval_ms: -5
agent:
  max_turns: 0
codex:
  command: "   "
---
p|};
  [%expect
    {|
    (invalid_workflow_config "polling.interval_ms is invalid"
     "agent.max_turns is invalid" "codex.command is invalid")
    |}]
;;

let%expect_test "server: port 0 is a valid ephemeral request; negatives are invalid" =
  (match parse "---\ntracker:\n  kind: memory\nserver:\n  port: 0\n---\np" with
   | Error error -> print_s [%sexp (error : Error.t)]
   | Ok loaded ->
     let%tydi { config; prompt_template = _; front_matter = _ } = loaded in
     print_s [%sexp (config.server : Config.Server.t)]);
  [%expect {| ((port (0)) (host 127.0.0.1)) |}];
  show_config "---\ntracker:\n  kind: memory\nserver:\n  port: -1\n---\np";
  [%expect {| (invalid_workflow_config "server.port is invalid") |}]
;;

let%expect_test "unknown top-level keys and unknown section fields are ignored" =
  (match
     parse
       {|---
tracker:
  kind: memory
  future_field: whatever
brand_new_section:
  x: 1
---
p|}
   with
   | Error error -> print_s [%sexp (error : Error.t)]
   | Ok loaded ->
     let%tydi { config; prompt_template = _; front_matter = _ } = loaded in
     print_s [%sexp (config.tracker.kind : string option)]);
  [%expect {| (memory) |}]
;;
