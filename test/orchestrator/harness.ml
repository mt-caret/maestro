open! Core
open! Async
open Maestro_tracker
open Maestro_orchestrator
open Orchestrator

(* A deterministic driver for the orchestrator: an explicit virtual clock, a scriptable
   tracker adapter (issue list plus injectable fetch errors), and effect collection so
   tests fire timers and inspect decisions without real Async timing. *)
type t =
  { mutable state : State.t
  ; mutable now : Time_ns.t
  ; mutable issues : Issue.t list
  ; mutable states_error : string option
  ; mutable ids_error : string option
  ; config : Maestro_workflow.Config.t
  ; adapter : Adapter.t
  ; mutable removed_workspaces : string list
  }

let default_config_yaml =
  {|---
tracker:
  kind: memory
  active_states: [Todo, In Progress]
  terminal_states: [Done, Cancelled]
agent:
  max_concurrent_agents: 2
codex:
  stall_timeout_ms: 300000
---
p|}
;;

let create ?(config_yaml = default_config_yaml) () =
  let config =
    (Maestro_workflow.Workflow.parse_contents
       config_yaml
       ~workflow_dir:"/unused"
       ~getenv:(fun (_ : string) -> None)
     |> ok_exn)
      .config
  in
  let t_ref = ref None in
  let get () = Option.value_exn !t_ref in
  let adapter =
    { Adapter.fetch_issues_by_states =
        (fun states ->
          let t = get () in
          match t.states_error with
          | Some error -> Deferred.Or_error.error_string error
          | None ->
            let want =
              List.map states ~f:Maestro_workflow.Config.normalize_state_name
              |> String.Set.of_list
            in
            List.filter t.issues ~f:(fun (issue : Issue.t) ->
              Set.mem want (Maestro_workflow.Config.normalize_state_name issue.state))
            |> Deferred.Or_error.return)
    ; fetch_issues_by_ids =
        (fun ids ->
          let t = get () in
          match t.ids_error with
          | Some error -> Deferred.Or_error.error_string error
          | None ->
            let want = String.Set.of_list ids in
            List.filter t.issues ~f:(fun (issue : Issue.t) -> Set.mem want issue.id)
            |> Deferred.Or_error.return)
    ; secret_environment_names = []
    ; agent_tool_specs = []
    ; execute_agent_tool =
        (fun ~name:_ ~arguments:_ ~context_issue:_ ->
          return { Adapter.Tool_result.success = false; output = ""; content_items = [] })
    ; validate_config = (fun () -> Ok ())
    }
  in
  let t =
    { state = State.create ()
    ; now = Time_ns.epoch
    ; issues = []
    ; states_error = None
    ; ids_error = None
    ; config
    ; adapter
    ; removed_workspaces = []
    }
  in
  t_ref := Some t;
  t
;;

let advance t span = t.now <- Time_ns.add t.now span

let interpret t effects =
  List.iter effects ~f:(fun (effect : Effect.t) ->
    match effect with
    | Remove_workspace { identifier } ->
      t.removed_workspaces <- t.removed_workspaces @ [ identifier ]
    | Spawn_worker _ | Stop_worker _ | Schedule_retry _ | Schedule_tick _ | Notify -> ())
;;

let feed t event =
  let%map state, effects =
    Orchestrator.handle t.state ~config:t.config ~adapter:t.adapter ~now:t.now event
  in
  t.state <- state;
  interpret t effects;
  effects
;;

let snapshot t = Orchestrator.to_snapshot t.state ~config:t.config ~now:t.now

(* --- Effect inspection ------------------------------------------------------ *)

let spawns effects =
  List.filter_map effects ~f:(function
    | Effect.Spawn_worker { issue; attempt; run_token } -> Some (issue, attempt, run_token)
    | _ -> None)
;;

let retries effects =
  List.filter_map effects ~f:(function
    | Effect.Schedule_retry { issue_id; delay; token } -> Some (issue_id, delay, token)
    | _ -> None)
;;

let ticks effects =
  List.filter_map effects ~f:(function
    | Effect.Schedule_tick { delay; token } -> Some (delay, token)
    | _ -> None)
;;

let stops effects =
  List.filter_map effects ~f:(function
    | Effect.Stop_worker { issue_id } -> Some issue_id
    | _ -> None)
;;

(* --- Convenience: run a poll tick and return its spawns --------------------- *)

let poll t =
  let%map effects = feed t (Tick { token = None }) in
  spawns effects
;;

let dispatched_identifiers spawns =
  List.map spawns ~f:(fun (issue, _, _) -> issue.Issue.identifier)
;;

(* --- Issue builder ---------------------------------------------------------- *)

let issue
  ?(native_ref = None)
  ?(title = "t")
  ?(description = None)
  ?(priority = None)
  ?(state = "Todo")
  ?(labels = [])
  ?(dispatchable = true)
  ?(created_at = None)
  ~id
  ~identifier
  ()
  =
  { Issue.id
  ; native_ref
  ; identifier
  ; title
  ; description
  ; priority
  ; state
  ; branch_name = None
  ; url = Some [%string "https://tracker/%{identifier}"]
  ; assignee_id = None
  ; labels
  ; blocked_by = []
  ; dispatchable
  ; created_at
  ; updated_at = None
  }
;;
