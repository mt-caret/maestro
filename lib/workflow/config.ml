open! Core

let normalize_state_name name = String.lowercase (String.strip name)

(* Field-extraction helpers over front-matter objects. Errors carry the dotted path so the
   final [invalid_workflow_config] error lists every offending field. *)
module Get = struct
  let find fields name = List.Assoc.find fields name ~equal:String.equal

  let section front_matter name =
    match (front_matter : Jsonaf.t) with
    | `Object fields ->
      (match find fields name with
       | None | Some `Null -> Ok []
       | Some (`Object fields) -> Ok fields
       | Some (`True | `False | `String _ | `Number _ | `Array _) ->
         Or_error.error_s [%message [%string "%{name} must be a map"]])
    | `Null -> Ok []
    | `True | `False | `String _ | `Number _ | `Array _ ->
      Or_error.error_s [%message "workflow front matter must be a map"]
  ;;

  let scalar fields ~section ~name ~default ~of_jsonaf =
    match find fields name with
    | None | Some `Null -> Ok default
    | Some value ->
      (match of_jsonaf value with
       | Some parsed -> Ok parsed
       | None -> Or_error.error_s [%message [%string "%{section}.%{name} is invalid"]])
  ;;

  let string_opt = function
    | `String s -> Some (Some s)
    | _ -> None
  ;;

  let int = function
    | `Number s -> Option.try_with (fun () -> Int.of_string s)
    | _ -> None
  ;;

  let positive_int value = Option.filter (int value) ~f:Int.is_positive
  let positive_span_ms value = Option.map (positive_int value) ~f:Time_ns.Span.of_int_ms

  let bool = function
    | `True -> Some true
    | `False -> Some false
    | _ -> None
  ;;

  let string_list = function
    | `Array elements ->
      List.map elements ~f:(function
        | `String s -> Some s
        | _ -> None)
      |> Option.all
    | _ -> None
  ;;
end

module Tracker = struct
  type t =
    { kind : string option
    ; provider : (string * Jsonaf.t) list
    ; resolved_provider : ((string * Jsonaf.t) list[@sexp.opaque])
    ; required_labels : string list
    ; active_states : string list option
    ; terminal_states : string list option
    ; secret_environment_names : string list
    }
  [@@deriving sexp_of]
end

module Polling = struct
  type t = { interval : Time_ns.Span.t } [@@deriving sexp_of]
end

module Workspace = struct
  type t = { root : string } [@@deriving sexp_of]
end

module Hooks = struct
  type t =
    { after_create : string option
    ; before_run : string option
    ; after_run : string option
    ; before_remove : string option
    ; timeout : Time_ns.Span.t
    }
  [@@deriving sexp_of]
end

module Agent = struct
  type t =
    { max_concurrent_agents : int
    ; max_turns : int
    ; max_retry_backoff : Time_ns.Span.t
    ; max_concurrent_agents_by_state : int String.Map.t
    }
  [@@deriving sexp_of]
end

module Codex = struct
  type t =
    { command : string
    ; approval_policy : Jsonaf.t
    ; thread_sandbox : string
    ; turn_sandbox_policy : Jsonaf.t option
    ; turn_timeout : Time_ns.Span.t
    ; read_timeout : Time_ns.Span.t
    ; stall_timeout : Time_ns.Span.t option
    }
  [@@deriving sexp_of]
end

module Observability = struct
  type t =
    { dashboard_enabled : bool
    ; refresh : Time_ns.Span.t
    }
  [@@deriving sexp_of]
end

module Server = struct
  type t =
    { port : int option
    ; host : string
    }
  [@@deriving sexp_of]
end

type t =
  { tracker : Tracker.t
  ; polling : Polling.t
  ; workspace : Workspace.t
  ; hooks : Hooks.t
  ; agent : Agent.t
  ; codex : Codex.t
  ; observability : Observability.t
  ; server : Server.t
  ; warnings : Error.t list
  }
[@@deriving sexp_of]

(* A config value is an environment reference iff it is the whole string [$NAME] where
   NAME is a valid environment variable identifier. No interpolation inside longer
   strings; the legacy [env:NAME] syntax is deliberately not resolved. *)
let env_reference value =
  match String.chop_prefix value ~prefix:"$" with
  | None -> None
  | Some name ->
    let valid =
      (not (String.is_empty name))
      && (Char.is_alpha (String.get name 0) || Char.equal (String.get name 0) '_')
      && String.for_all name ~f:(fun c -> Char.is_alphanum c || Char.equal c '_')
    in
    Option.some_if valid name
;;

let blank_to_none value =
  match value with
  | Some "" -> None
  | Some _ | None -> value
;;

(* Secret resolution (ref-exact): a [$NAME] reference resolves from the environment; a
   referenced variable that is set-to-empty defeats the fallback (yields missing), while
   an unset one falls back to [fallback_env]. Literal values pass through. The final empty
   string normalizes to missing. *)
let resolve_secret value ~fallback_env ~getenv =
  let resolved =
    match value with
    | Some value ->
      (match env_reference value with
       | Some name ->
         (match getenv name with
          | Some resolved -> Some resolved
          | None -> getenv fallback_env)
       | None -> Some value)
    | None -> getenv fallback_env
  in
  blank_to_none resolved
;;

let linear_default_endpoint = "https://api.linear.app/graphql"
let linear_default_active_states = [ "Todo"; "In Progress" ]

let linear_default_terminal_states =
  [ "Closed"; "Cancelled"; "Canceled"; "Duplicate"; "Done" ]
;;

let jsonaf_string = function
  | `String s -> Some s
  | `Null | `True | `False | `Number _ | `Array _ | `Object _ -> None
;;

let parse_tracker fields ~getenv =
  let open Get in
  let%map.Or_error kind =
    scalar fields ~section:"tracker" ~name:"kind" ~default:None ~of_jsonaf:string_opt
  and provider =
    match find fields "provider" with
    | None | Some `Null -> Ok []
    | Some (`Object provider_fields) -> Ok provider_fields
    | Some (`True | `False | `String _ | `Number _ | `Array _) ->
      Or_error.error_s [%message "tracker.provider is invalid"]
  and required_labels =
    scalar
      fields
      ~section:"tracker"
      ~name:"required_labels"
      ~default:[]
      ~of_jsonaf:string_list
  and active_states =
    scalar
      fields
      ~section:"tracker"
      ~name:"active_states"
      ~default:None
      ~of_jsonaf:(fun v -> Option.map (string_list v) ~f:Option.some)
  and terminal_states =
    scalar
      fields
      ~section:"tracker"
      ~name:"terminal_states"
      ~default:None
      ~of_jsonaf:(fun v -> Option.map (string_list v) ~f:Option.some)
  in
  let required_labels =
    List.map required_labels ~f:normalize_state_name
    |> List.stable_dedup ~compare:String.compare
  in
  (* Legacy top-level aliases merge into the provider map with provider keys winning
     (ref-exact, linear only). *)
  let provider, resolved_provider, secret_environment_names =
    match kind with
    | Some "linear" ->
      let alias name =
        match find fields name with
        | Some (`String _ as value) -> [ name, value ]
        | Some _ | None -> []
      in
      let put_new provider entries =
        List.fold entries ~init:provider ~f:(fun provider (name, value) ->
          match List.Assoc.mem provider name ~equal:String.equal with
          | true -> provider
          | false -> provider @ [ name, value ])
      in
      let provider =
        put_new
          provider
          (List.concat
             [ alias "endpoint"
             ; alias "api_key"
             ; alias "project_slug"
             ; alias "assignee"
             ; [ "endpoint", `String linear_default_endpoint ]
             ])
      in
      let resolve name ~fallback_env =
        resolve_secret
          (Option.bind (find provider name) ~f:jsonaf_string)
          ~fallback_env
          ~getenv
      in
      let resolved name ~fallback_env =
        match resolve name ~fallback_env with
        | Some value -> [ name, `String value ]
        | None -> []
      in
      let resolved_provider =
        List.Assoc.remove provider "api_key" ~equal:String.equal
        |> fun p ->
        List.Assoc.remove p "assignee" ~equal:String.equal
        @ resolved "api_key" ~fallback_env:"LINEAR_API_KEY"
        @ resolved "assignee" ~fallback_env:"LINEAR_ASSIGNEE"
      in
      let secret_environment_names =
        "LINEAR_API_KEY"
        :: (Option.bind (find provider "api_key") ~f:jsonaf_string
            |> Option.bind ~f:env_reference
            |> Option.to_list)
        |> List.stable_dedup ~compare:String.compare
      in
      provider, resolved_provider, secret_environment_names
    | Some _ | None -> provider, provider, []
  in
  let with_state_defaults states ~default =
    match states, kind with
    | Some states, _ -> Some states
    | None, Some ("linear" | "memory") -> Some default
    | None, (Some _ | None) -> None
  in
  { Tracker.kind
  ; provider
  ; resolved_provider
  ; required_labels
  ; active_states =
      with_state_defaults active_states ~default:linear_default_active_states
  ; terminal_states =
      with_state_defaults terminal_states ~default:linear_default_terminal_states
  ; secret_environment_names
  }
;;

let parse_polling fields =
  let open Get in
  let%map.Or_error interval =
    scalar
      fields
      ~section:"polling"
      ~name:"interval_ms"
      ~default:(Time_ns.Span.of_int_ms 30_000)
      ~of_jsonaf:positive_span_ms
  in
  { Polling.interval }
;;

(* The system temp directory comes through [getenv] (not [Filename.temp_dir_name], which
   reads the real environment at module-load time) so config parsing stays a pure function
   of its inputs. *)
let default_workspace_root ~getenv =
  let tmpdir = Option.value (blank_to_none (getenv "TMPDIR")) ~default:"/tmp" in
  Filename.concat tmpdir "symphony_workspaces"
;;

let parse_workspace fields ~workflow_dir ~getenv =
  let open Get in
  let%bind.Or_error root =
    scalar fields ~section:"workspace" ~name:"root" ~default:None ~of_jsonaf:string_opt
  in
  let root =
    match root with
    | None | Some "" -> Some (default_workspace_root ~getenv)
    | Some value ->
      (match env_reference value with
       | Some name ->
         (match blank_to_none (getenv name) with
          | Some resolved -> Some resolved
          | None -> Some (default_workspace_root ~getenv))
       | None -> Some value)
  in
  let%map.Or_error root =
    match root with
    | None -> Or_error.error_s [%message "workspace.root is invalid"]
    | Some root ->
      (match String.chop_prefix root ~prefix:"~" with
       | None -> Ok root
       | Some rest ->
         (match String.is_empty rest || String.is_prefix rest ~prefix:"/" with
          | false ->
            (* [~user/...] expansion is not supported; treat as invalid rather than as a
               literal directory name. *)
            Or_error.error_s [%message "workspace.root is invalid" ~root]
          | true ->
            (match blank_to_none (getenv "HOME") with
             | Some home -> Ok [%string "%{home}%{rest}"]
             | None ->
               Or_error.error_s
                 [%message "workspace.root uses ~ but HOME is not set" ~root])))
  in
  let root =
    match Filename.is_absolute root with
    | true -> root
    | false ->
      (* SPEC §5.3.3: relative roots resolve against the directory containing WORKFLOW.md,
         not the process cwd. *)
      Filename.concat workflow_dir root
  in
  { Workspace.root }
;;

let parse_hooks fields =
  let open Get in
  let script name =
    scalar fields ~section:"hooks" ~name ~default:None ~of_jsonaf:string_opt
  in
  let%map.Or_error after_create = script "after_create"
  and before_run = script "before_run"
  and after_run = script "after_run"
  and before_remove = script "before_remove"
  and timeout =
    scalar
      fields
      ~section:"hooks"
      ~name:"timeout_ms"
      ~default:(Time_ns.Span.of_int_ms 60_000)
      ~of_jsonaf:positive_span_ms
  in
  { Hooks.after_create; before_run; after_run; before_remove; timeout }
;;

let parse_agent fields =
  let open Get in
  let%map.Or_error max_concurrent_agents =
    scalar
      fields
      ~section:"agent"
      ~name:"max_concurrent_agents"
      ~default:10
      ~of_jsonaf:positive_int
  and max_turns =
    scalar fields ~section:"agent" ~name:"max_turns" ~default:20 ~of_jsonaf:positive_int
  and max_retry_backoff =
    scalar
      fields
      ~section:"agent"
      ~name:"max_retry_backoff_ms"
      ~default:(Time_ns.Span.of_int_ms 300_000)
      ~of_jsonaf:positive_span_ms
  and by_state_entries =
    match find fields "max_concurrent_agents_by_state" with
    | None | Some `Null -> Ok []
    | Some (`Object entries) -> Ok entries
    | Some (`True | `False | `String _ | `Number _ | `Array _) ->
      Or_error.error_s [%message "agent.max_concurrent_agents_by_state is invalid"]
  in
  (* SPEC §5.3.5: invalid per-state entries are ignored (the reference rejects them
     instead; PLAN.md §7). Ignored entries surface as warnings for the caller to log. *)
  let max_concurrent_agents_by_state, warnings =
    List.fold
      by_state_entries
      ~init:(String.Map.empty, [])
      ~f:(fun (limits, warnings) (state, limit) ->
        let ignore_entry why =
          ( limits
          , Error.create_s
              [%message
                "ignoring invalid agent.max_concurrent_agents_by_state entry"
                  ~state
                  ~_:(why : string)]
            :: warnings )
        in
        match normalize_state_name state, Get.positive_int limit with
        | "", _ -> ignore_entry "blank state name"
        | _, None -> ignore_entry "limit must be a positive integer"
        | state, Some limit ->
          (match Map.add limits ~key:state ~data:limit with
           | `Ok limits -> limits, warnings
           | `Duplicate -> ignore_entry "duplicate state name"))
  in
  ( { Agent.max_concurrent_agents
    ; max_turns
    ; max_retry_backoff
    ; max_concurrent_agents_by_state
    }
  , List.rev warnings )
;;

let default_approval_policy : Jsonaf.t =
  `Object
    [ ( "reject"
      , `Object [ "sandbox_approval", `True; "rules", `True; "mcp_elicitations", `True ] )
    ]
;;

let parse_codex fields =
  let open Get in
  let%map.Or_error command =
    scalar
      fields
      ~section:"codex"
      ~name:"command"
      ~default:"codex app-server"
      ~of_jsonaf:(fun value ->
        Option.filter
          (Option.join (string_opt value))
          ~f:(fun command -> not (String.is_empty (String.strip command))))
  and approval_policy =
    match find fields "approval_policy" with
    | None | Some `Null -> Ok default_approval_policy
    | Some ((`String _ | `Object _) as policy) -> Ok policy
    | Some (`True | `False | `Number _ | `Array _) ->
      Or_error.error_s [%message "codex.approval_policy is invalid"]
  and thread_sandbox =
    scalar
      fields
      ~section:"codex"
      ~name:"thread_sandbox"
      ~default:"workspace-write"
      ~of_jsonaf:(fun value -> Option.join (string_opt value))
  and turn_sandbox_policy =
    match find fields "turn_sandbox_policy" with
    | None | Some `Null -> Ok None
    | Some (`Object _ as policy) -> Ok (Some policy)
    | Some (`True | `False | `String _ | `Number _ | `Array _) ->
      Or_error.error_s [%message "codex.turn_sandbox_policy is invalid"]
  and turn_timeout =
    scalar
      fields
      ~section:"codex"
      ~name:"turn_timeout_ms"
      ~default:(Time_ns.Span.of_int_ms 3_600_000)
      ~of_jsonaf:positive_span_ms
  and read_timeout =
    scalar
      fields
      ~section:"codex"
      ~name:"read_timeout_ms"
      ~default:(Time_ns.Span.of_int_ms 5_000)
      ~of_jsonaf:positive_span_ms
  and stall_timeout =
    (* Any integer accepted; <= 0 disables stall detection (SPEC §5.3.6). *)
    scalar
      fields
      ~section:"codex"
      ~name:"stall_timeout_ms"
      ~default:(Some (Time_ns.Span.of_int_ms 300_000))
      ~of_jsonaf:(fun value ->
        Option.map (int value) ~f:(fun ms ->
          Option.some_if (ms > 0) (Time_ns.Span.of_int_ms ms)))
  in
  { Codex.command
  ; approval_policy
  ; thread_sandbox
  ; turn_sandbox_policy
  ; turn_timeout
  ; read_timeout
  ; stall_timeout
  }
;;

let parse_observability fields =
  let open Get in
  let%map.Or_error dashboard_enabled =
    scalar
      fields
      ~section:"observability"
      ~name:"dashboard_enabled"
      ~default:true
      ~of_jsonaf:bool
  and refresh =
    scalar
      fields
      ~section:"observability"
      ~name:"refresh_ms"
      ~default:(Time_ns.Span.of_int_ms 1_000)
      ~of_jsonaf:positive_span_ms
  in
  { Observability.dashboard_enabled; refresh }
;;

let parse_server fields =
  let open Get in
  let%map.Or_error port =
    scalar fields ~section:"server" ~name:"port" ~default:None ~of_jsonaf:(fun value ->
      Option.map (int value) ~f:(fun port -> Option.some_if (port >= 0) port)
      |> Option.join
      |> Option.map ~f:Option.some)
  and host =
    scalar
      fields
      ~section:"server"
      ~name:"host"
      ~default:"127.0.0.1"
      ~of_jsonaf:(fun value -> Option.join (string_opt value))
  in
  { Server.port; host }
;;

let of_front_matter front_matter ~workflow_dir ~getenv =
  (let%bind.Or_error tracker_fields = Get.section front_matter "tracker"
   and polling_fields = Get.section front_matter "polling"
   and workspace_fields = Get.section front_matter "workspace"
   and hooks_fields = Get.section front_matter "hooks"
   and agent_fields = Get.section front_matter "agent"
   and codex_fields = Get.section front_matter "codex"
   and observability_fields = Get.section front_matter "observability"
   and server_fields = Get.section front_matter "server" in
   let%map.Or_error tracker = parse_tracker tracker_fields ~getenv
   and polling = parse_polling polling_fields
   and workspace = parse_workspace workspace_fields ~workflow_dir ~getenv
   and hooks = parse_hooks hooks_fields
   and agent, warnings = parse_agent agent_fields
   and codex = parse_codex codex_fields
   and observability = parse_observability observability_fields
   and server = parse_server server_fields in
   { tracker; polling; workspace; hooks; agent; codex; observability; server; warnings })
  |> Or_error.tag ~tag:"invalid_workflow_config"
;;

let max_concurrent_agents_for_state t ~state =
  match Map.find t.agent.max_concurrent_agents_by_state (normalize_state_name state) with
  | Some limit -> limit
  | None -> t.agent.max_concurrent_agents
;;
