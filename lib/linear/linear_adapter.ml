open! Core
open! Async
open Maestro_tracker

let create ?request_fun (tracker : Maestro_workflow.Config.Tracker.t) =
  let settings = Client.Settings.of_tracker_config tracker in
  let lift result =
    Deferred.map result ~f:(Result.map_error ~f:Client.Client_error.to_error)
  in
  { Adapter.fetch_issues_by_states =
      (fun states -> lift (Client.fetch_issues_by_states ?request_fun ~settings states))
  ; fetch_issues_by_ids =
      (fun ids -> lift (Client.fetch_issues_by_ids ?request_fun ~settings ids))
  ; secret_environment_names = tracker.secret_environment_names
  ; agent_tool_specs = [ Agent_tool.spec ]
  ; execute_agent_tool =
      (fun ~name ~arguments ~context_issue:(_ : Issue.t) ->
        (* The normalized issue is available as context per SPEC §10.5; the linear tool
           doesn't need it — the workflow prompt hands the agent its issue ids. *)
        Agent_tool.execute ?request_fun ~settings ~name ~arguments ())
  ; validate_config = (fun () -> Client.Settings.validate settings)
  }
;;
