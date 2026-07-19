open! Core
open! Async
open Maestro_tracker
open Maestro_linear
open Maestro_codex

(* SPEC §17.8 Real Integration Profile: gated on env, reports why it was skipped rather
   than passing silently, and fails the job when enabled and failing. *)

let getenv name = Option.filter (Sys.getenv name) ~f:(Fn.non String.is_empty)

module Gate = struct
  type t =
    { api_key : string
    ; project_slug : string
    }

  let check () =
    match getenv "MAESTRO_RUN_LIVE_E2E" with
    | None -> `Skipped "MAESTRO_RUN_LIVE_E2E is not set"
    | Some _ ->
      (match getenv "LINEAR_API_KEY", getenv "MAESTRO_LIVE_PROJECT_SLUG" with
       | Some api_key, Some project_slug -> `Enabled { api_key; project_slug }
       | None, _ -> `Skipped "LINEAR_API_KEY is required when the gate is set"
       | _, None -> `Skipped "MAESTRO_LIVE_PROJECT_SLUG is required when the gate is set")
  ;;
end

let settings (gate : Gate.t) =
  let tracker =
    (Maestro_workflow.Workflow.parse_contents
       [%string
         {|---
tracker:
  kind: linear
  provider:
    api_key: "%{gate.api_key}"
    project_slug: "%{gate.project_slug}"
---
p|}]
       ~workflow_dir:"/unused"
       ~getenv:(fun (_ : string) -> None)
     |> ok_exn)
      .config
      .tracker
  in
  Client.Settings.of_tracker_config tracker
;;

let graphql settings ~query ~variables =
  match%map Client.graphql ~settings ~query ~variables () with
  | Ok body -> body
  | Error error ->
    raise_s [%message "linear request failed" ~_:(error : Client.Client_error.t)]
;;

let member name = function
  | `Object fields -> List.Assoc.find_exn fields name ~equal:String.equal
  | json -> raise_s [%message "expected object" (json : Jsonaf.t)]
;;

let string_field name json =
  match member name json with
  | `String s -> s
  | json -> raise_s [%message "expected string" (json : Jsonaf.t)]
;;

let create_issue settings (gate : Gate.t) ~title =
  let query =
    {|mutation ($title: String!, $slug: String!) {
      issueCreate(input: {title: $title, projectId: $slug}) {
        issue { id identifier }
      }
    }|}
  in
  let%map body =
    graphql
      settings
      ~query
      ~variables:(`Object [ "title", `String title; "slug", `String gate.project_slug ])
  in
  let issue = member "data" body |> member "issueCreate" |> member "issue" in
  string_field "id" issue, string_field "identifier" issue
;;

let archive_issue settings ~id =
  let query = {|mutation ($id: String!) { issueArchive(id: $id) { success } }|} in
  let%map (_ : Jsonaf.t) =
    graphql settings ~query ~variables:(`Object [ "id", `String id ])
  in
  ()
;;

let run_agent (gate : Gate.t) ~issue_id ~issue_identifier ~workspace_root ~proof_file =
  let workflow =
    Maestro_workflow.Workflow.parse_contents
      [%string
        {|---
tracker:
  kind: linear
  provider:
    api_key: "%{gate.api_key}"
    project_slug: "%{gate.project_slug}"
  active_states: [Todo, In Progress]
  terminal_states: [Done, Cancelled, Canceled, Duplicate]
workspace:
  root: "%{workspace_root}"
codex:
  command: codex app-server
  approval_policy: never
  turn_timeout_ms: 240000
agent:
  max_turns: 1
---
Create a file named maestro-live-proof.txt in the current directory containing the text
"maestro was here". Then stop.|}]
      ~workflow_dir:workspace_root
      ~getenv:Sys.getenv
    |> ok_exn
  in
  let issue =
    { Issue.id = issue_id
    ; native_ref = None
    ; identifier = issue_identifier
    ; title = "maestro live e2e"
    ; description = None
    ; priority = None
    ; state = "Todo"
    ; branch_name = None
    ; url = None
    ; assignee_id = None
    ; labels = []
    ; blocked_by = []
    ; dispatchable = true
    ; created_at = None
    ; updated_at = None
    }
  in
  let adapter = Linear_adapter.create workflow.config.tracker in
  let%bind result =
    Agent_runner.run
      ~config:workflow.config
      ~workflow
      ~adapter
      ~issue
      ~attempt:None
      ~on_update:(fun (_ : Update.t) -> ())
      ~on_runtime_info:(fun ~workspace_path:(_ : string) -> ())
      ()
  in
  ok_exn result;
  Sys.file_exists_exn proof_file
;;

let%expect_test "live: real Linear issue driven by a real Codex writes proof of work" =
  let%bind () =
    match Gate.check () with
    | `Skipped reason ->
      print_s [%message "SKIPPED live e2e" ~_:(reason : string)];
      return ()
    | `Enabled gate ->
      let settings = settings gate in
      let%bind issue_id, issue_identifier =
        create_issue settings gate ~title:"maestro live e2e"
      in
      Monitor.protect
        ~finally:(fun () -> archive_issue settings ~id:issue_id)
        (fun () ->
          let workspace_root =
            Filename.concat (Core_unix.mkdtemp "/tmp/maestro-live") "ws"
          in
          let proof_file =
            Filename.concat
              (Filename.concat workspace_root issue_identifier)
              "maestro-live-proof.txt"
          in
          let%map wrote =
            run_agent gate ~issue_id ~issue_identifier ~workspace_root ~proof_file
          in
          print_s [%message "live e2e proof written" (wrote : bool)])
  in
  [%expect {| ("SKIPPED live e2e" "MAESTRO_RUN_LIVE_E2E is not set") |}];
  return ()
;;
