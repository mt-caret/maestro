open! Core
open! Async
open Maestro_workflow
open Maestro_tracker
open Maestro_workspace

let state_active (config : Config.t) state =
  let active =
    Option.value config.tracker.active_states ~default:[]
    |> List.map ~f:Config.normalize_state_name
    |> String.Set.of_list
  in
  Set.mem active (Config.normalize_state_name state)
;;

let run_turns
  ~(config : Config.t)
  ~workflow
  ~(adapter : Adapter.t)
  ~issue
  ~attempt
  ~session
  =
  let max_turns = config.agent.max_turns in
  let rec turn ~turn_number ~(issue : Issue.t) =
    let%bind.Deferred.Or_error prompt =
      match turn_number with
      | 1 -> Deferred.return (Prompt_builder.first_turn_prompt ~workflow ~issue ~attempt)
      | turn_number ->
        Deferred.Or_error.return
          (Prompt_builder.continuation_prompt ~turn_number ~max_turns)
    in
    let%bind.Deferred.Or_error () = App_server.run_turn session ~prompt ~issue in
    (* Re-check the tracker after each normal turn: continue on the same live thread while
       the issue stays active and routable (SPEC §7.1). *)
    match%bind.Deferred.Or_error
      adapter.fetch_issues_by_ids [ issue.id ]
      |> Deferred.Or_error.tag ~tag:"issue_state_refresh_failed"
    with
    | [] -> Deferred.Or_error.return ()
    | refreshed :: (_ : Issue.t list) ->
      let continue_ =
        state_active config refreshed.state
        && Issue.routable refreshed ~required_labels:config.tracker.required_labels
      in
      (match continue_ with
       | false -> Deferred.Or_error.return ()
       | true ->
         (match turn_number >= max_turns with
          | true ->
            [%log.info
              "reached agent.max_turns; returning control to the orchestrator"
                ~issue_id:refreshed.id
                ~issue_identifier:refreshed.identifier
                (max_turns : int)];
            Deferred.Or_error.return ()
          | false -> turn ~turn_number:(turn_number + 1) ~issue:refreshed))
  in
  turn ~turn_number:1 ~issue
;;

let run
  ?(stop = Deferred.never ())
  ~config
  ~workflow
  ~adapter
  ~issue
  ~attempt
  ~on_update
  ~on_runtime_info
  ()
  =
  let%tydi { Config.hooks; _ } = config in
  match%bind Workspace.create_for_issue ~config ~identifier:issue.Issue.identifier with
  | Error _ as error -> return error
  | Ok created ->
    let%tydi { Workspace.Created.path = workspace; created_now = _ } = created in
    on_runtime_info ~workspace_path:workspace;
    let run_hooked () =
      let%bind.Deferred.Or_error () =
        match hooks.before_run with
        | None -> Deferred.Or_error.return ()
        | Some script ->
          Hook.run ~name:"before_run" ~script ~workspace ~timeout:hooks.timeout
      in
      match%bind App_server.start_session ~config ~workspace ~adapter ~on_update with
      | Error _ as error -> return error
      | Ok session ->
        (* Race the turn loop against an external stop (reconciliation terminating this
           run): stopping the session kills the subprocess, unwedging any in-flight turn. *)
        let%bind result =
          Deferred.any
            [ run_turns ~config ~workflow ~adapter ~issue ~attempt ~session
            ; (stop >>| fun () -> Or_error.error_s [%message "stopped_by_orchestrator"])
            ]
        in
        let%map () = App_server.stop_session session in
        result
    in
    let%bind result = run_hooked () in
    (* after_run executes after every attempt — success, failure, or timeout — and its own
       failure is logged and ignored (SPEC §9.4). *)
    let%map () =
      match hooks.after_run with
      | None -> return ()
      | Some script ->
        Hook.run_best_effort ~name:"after_run" ~script ~workspace ~timeout:hooks.timeout
    in
    result
;;
