open! Core
open! Async
open Maestro_workflow
open Maestro_orchestrator
open Orchestrator

type t =
  { workflow_store : Workflow_store.t
  ; make_adapter : Config.Tracker.t -> Maestro_tracker.Adapter.t Or_error.t
  ; events : Event.t Pipe.Writer.t
  ; mutable state : State.t
  ; mutable config : Config.t
  ; mutable workflow : Workflow.Loaded.t
  ; mutable adapter : Maestro_tracker.Adapter.t
  ; mutable config_valid : bool
  (** Whether the on-disk WORKFLOW.md currently loads and its adapter builds. *)
  ; worker_stops : unit Ivar.t String.Table.t
  (** issue_id -> stop signal for its worker *)
  ; on_change : (unit -> unit) Bag.t
  ; stopped : unit Ivar.t
  ; logs_root : string
  }

let notify_observers t = Bag.iter t.on_change ~f:(fun f -> f ())

(* Re-read the workflow each cycle so reloads take effect (SPEC §6.2). Two things happen
   atomically: [force_reload] reports whether the on-disk file currently loads (→
   [config_valid], which gates new dispatch per §5.5/§6.3), and the
   config/workflow/adapter triple is swapped only when a fresh load AND its adapter both
   succeed — otherwise the whole last-known-good triple is kept so config and adapter
   never disagree. *)
let refresh_config t =
  match%map Workflow_store.force_reload t.workflow_store with
  | Error error ->
    (* The file is currently unreadable/unparsable: keep last-known-good, block dispatch. *)
    [%log.error
      "workflow file invalid; keeping last known good configuration and blocking dispatch"
        ~_:(error : Error.t)];
    t.config_valid <- false
  | Ok loaded ->
    (match t.make_adapter loaded.config.tracker with
     | Ok adapter ->
       t.workflow <- loaded;
       t.config <- loaded.config;
       t.adapter <- adapter;
       t.config_valid <- true
     | Error error ->
       [%log.error
         "tracker config unusable; keeping last known good configuration and blocking \
          dispatch"
           ~_:(error : Error.t)];
       t.config_valid <- false)
;;

let post t event =
  match Pipe.is_closed t.events with
  | true -> ()
  | false -> Pipe.write_without_pushback t.events event
;;

let spawn_worker t ~(issue : Maestro_tracker.Issue.t) ~attempt ~run_token =
  [%log.info
    "dispatching issue"
      ~issue_id:issue.id
      ~issue_identifier:issue.identifier
      (attempt : int option)];
  let stop = Ivar.create () in
  Hashtbl.set t.worker_stops ~key:issue.id ~data:stop;
  (* Snapshot config/workflow/adapter for the whole worker lifetime (SPEC §10.5). *)
  let config = t.config
  and workflow = t.workflow
  and adapter = t.adapter in
  don't_wait_for
    (let%bind result =
       Maestro_codex.Agent_runner.run
         ~stop:(Ivar.read stop)
         ~session_log_dir:
           (t.logs_root
            ^/ "sessions"
            ^/ Maestro_workspace.Workspace.key ~identifier:issue.identifier)
         ~config
         ~workflow
         ~adapter
         ~issue
         ~attempt
         ~on_update:(fun update -> post t (Codex_update { issue_id = issue.id; update }))
         ~on_runtime_info:(fun ~workspace_path ->
           post t (Worker_runtime_info { issue_id = issue.id; workspace_path }))
         ()
     in
     Hashtbl.remove t.worker_stops issue.id;
     let outcome =
       match result with
       | Ok () ->
         [%log.info
           "worker completed" ~issue_id:issue.id ~issue_identifier:issue.identifier];
         Worker_outcome.Completed
       | Error error ->
         [%log.info
           "worker failed"
             ~issue_id:issue.id
             ~issue_identifier:issue.identifier
             ~reason:(Error.to_string_hum error : string)];
         Worker_outcome.Failed (Error.to_string_hum error)
     in
     post t (Worker_exited { issue_id = issue.id; run_token; outcome });
     return ())
;;

let remove_workspace t ~identifier =
  don't_wait_for
    (match%map
       Maestro_workspace.Workspace.remove_for_issue ~config:t.config ~identifier
     with
     | Ok () -> ()
     | Error error ->
       [%log.info "workspace cleanup failed" ~identifier ~_:(error : Error.t)])
;;

let interpret_effect t (effect : Effect.t) =
  match effect with
  | Spawn_worker { issue; attempt; run_token } ->
    spawn_worker t ~issue ~attempt ~run_token
  | Stop_worker { issue_id } ->
    (match Hashtbl.find t.worker_stops issue_id with
     | Some stop -> Ivar.fill_if_empty stop ()
     | None -> ())
  | Schedule_retry { issue_id; delay; token } ->
    don't_wait_for
      (let%map () = Clock_ns.after delay in
       post t (Retry_due { issue_id; token }))
  | Remove_workspace { identifier } -> remove_workspace t ~identifier
  | Schedule_tick { delay; token } ->
    don't_wait_for
      (let%map () = Clock_ns.after delay in
       post t (Tick { token = Some token }))
  | Notify -> notify_observers t
;;

let process_event t event =
  let%map state, effects =
    Orchestrator.handle
      t.state
      ~config:t.config
      ~adapter:t.adapter
      ~now:(Time_ns.now ())
      ~config_valid:t.config_valid
      event
  in
  t.state <- state;
  List.iter effects ~f:(interpret_effect t)
;;

let startup_cleanup t =
  (* Remove stale workspaces for issues already in terminal states (SPEC §8.6); failure is
     a warning, not fatal. *)
  let terminal = Option.value t.config.tracker.terminal_states ~default:[] in
  match%bind t.adapter.fetch_issues_by_states terminal with
  | Error error ->
    [%log.info "startup terminal cleanup skipped" ~_:(error : Error.t)];
    return ()
  | Ok issues ->
    Deferred.List.iter issues ~how:`Sequential ~f:(fun issue ->
      match%map
        Maestro_workspace.Workspace.remove_for_issue
          ~config:t.config
          ~identifier:issue.identifier
      with
      | Ok () | Error _ -> ())
;;

let start ~workflow_store ~make_adapter ~logs_root =
  let%bind workflow = Workflow_store.current workflow_store in
  match make_adapter workflow.config.tracker with
  | Error _ as error -> return error
  | Ok adapter ->
    let events, writer = Pipe.create () in
    let t =
      { workflow_store
      ; make_adapter
      ; events = writer
      ; state = State.create ()
      ; config = workflow.config
      ; workflow
      ; adapter
      ; config_valid = true
      ; worker_stops = String.Table.create ()
      ; on_change = Bag.create ()
      ; stopped = Ivar.create ()
      ; logs_root
      }
    in
    (* Refresh config at the head of every event so ticks/retries see the latest. *)
    don't_wait_for
      (let%bind () =
         Pipe.iter events ~f:(fun event ->
           let%bind () = refresh_config t in
           process_event t event)
       in
       Ivar.fill_if_empty t.stopped ();
       return ());
    let%bind () = startup_cleanup t in
    post t (Tick { token = None });
    return (Ok t)
;;

let snapshot t =
  return (Orchestrator.to_snapshot t.state ~config:t.config ~now:(Time_ns.now ()))
;;

let request_refresh t =
  post t (Tick { token = None });
  return (Maestro_http.Http_server.Refresh_result.Queued { coalesced = false })
;;

let on_change t ~f = ignore (Bag.add t.on_change f : (unit -> unit) Bag.Elt.t)

let close t =
  Pipe.close t.events;
  Hashtbl.iter t.worker_stops ~f:(fun stop -> Ivar.fill_if_empty stop ());
  Ivar.read t.stopped
;;
