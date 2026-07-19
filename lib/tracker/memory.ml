open! Core
open! Async
open Maestro_workflow

let create ~issues =
  { Adapter.fetch_issues_by_states =
      (fun states ->
        let states =
          List.map states ~f:Config.normalize_state_name |> String.Set.of_list
        in
        issues ()
        |> List.filter ~f:(fun (issue : Issue.t) ->
          Set.mem states (Config.normalize_state_name issue.state))
        |> Deferred.Or_error.return)
  ; fetch_issues_by_ids =
      (fun ids ->
        let ids = String.Set.of_list ids in
        issues ()
        |> List.filter ~f:(fun (issue : Issue.t) -> Set.mem ids issue.id)
        |> Deferred.Or_error.return)
  ; secret_environment_names = []
  ; agent_tool_specs = []
  ; execute_agent_tool =
      (fun ~name ~arguments:(_ : Jsonaf.t) ~context_issue:(_ : Issue.t) ->
        return
          (Adapter.Tool_result.of_error_message
             ~extra:[ "supportedTools", `Array [] ]
             [%string "Unsupported dynamic tool: \"%{name}\"."]))
  ; validate_config = (fun () -> Ok ())
  }
;;
