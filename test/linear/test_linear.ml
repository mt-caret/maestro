open! Core
open! Async
open Maestro_linear

(* The client logs dropped-record and non-200 warnings; keep them out of expect output. *)
let () = Log.Global.set_output []

let settings ?(provider_yaml = {|    api_key: k
    project_slug: proj|}) () =
  let contents =
    [%string {|---
tracker:
  kind: linear
  provider:
%{provider_yaml}
---
p|}]
  in
  let loaded =
    Maestro_workflow.Workflow.parse_contents
      contents
      ~workflow_dir:"/unused"
      ~getenv:(fun (_ : string) -> None)
    |> ok_exn
  in
  Client.Settings.of_tracker_config loaded.config.tracker
;;

(* Scripted transport: pops one canned response per request and records requests. *)
let mock ?(requests = ref []) responses =
  let remaining = ref responses in
  fun (request : Client.Request.t) ->
    requests := !requests @ [ request ];
    match !remaining with
    | [] -> return (Or_error.error_string "mock transport exhausted")
    | response :: rest ->
      remaining := rest;
      return response
;;

let ok_page ?(page_info = {|"pageInfo": {"hasNextPage": false, "endCursor": null}|}) nodes
  =
  Ok (200, [%string {|{"data": {"issues": {"nodes": [%{nodes}], %{page_info}}}}|}])
;;

let node ?(id = "id-1") ?(identifier = "MT-1") ?(extra = "") () =
  [%string
    {|{"id": "%{id}", "identifier": "%{identifier}", "title": "Fix it", "state": {"name": "Todo"}%{extra}}|}]
;;

let show_issues result =
  match result with
  | Ok issues ->
    print_s
      [%sexp
        (List.map issues ~f:(fun (issue : Maestro_tracker.Issue.t) -> issue.identifier)
         : string list)]
  | Error error -> print_s [%sexp (error : Client.Client_error.t)]
;;

let%expect_test "settings validation matrix" =
  let show ?provider_yaml () =
    print_s
      [%sexp (Client.Settings.validate (settings ?provider_yaml ()) : unit Or_error.t)]
  in
  show ();
  [%expect {| (Ok ()) |}];
  show ~provider_yaml:{|    project_slug: proj|} ();
  [%expect {| (Error missing_linear_api_token) |}];
  show ~provider_yaml:{|    api_key: k|} ();
  [%expect {| (Error missing_linear_project_slug) |}];
  show ~provider_yaml:{|    api_key: k
    project_slug: proj
    assignee: "   "|} ();
  [%expect {| (Error invalid_linear_assignee) |}];
  return ()
;;

let%expect_test "empty inputs short-circuit without any provider request" =
  let requests = ref [] in
  let request_fun = mock ~requests [] in
  let settings = settings () in
  let%bind () = Client.fetch_issues_by_states ~request_fun ~settings [] >>| show_issues in
  [%expect {| () |}];
  let%bind () = Client.fetch_issues_by_ids ~request_fun ~settings [] >>| show_issues in
  [%expect {| () |}];
  print_s [%sexp (List.length !requests : int)];
  [%expect {| 0 |}];
  return ()
;;

let%expect_test "a rich node normalizes fully" =
  let extra =
    {|,
      "description": "Details here",
      "priority": 2,
      "branchName": "mt-1-fix",
      "url": "https://linear.app/x/issue/MT-1",
      "assignee": {"id": "user-9"},
      "labels": {"nodes": [{"name": " Bug "}, {"name": "URGENT"}, {"name": "bug"}, {"name": "  "}]},
      "inverseRelations": {"nodes": [
        {"type": "blocks", "issue": {"id": "b1", "identifier": "MT-9", "state": {"name": "Done"}}},
        {"type": "relatesTo", "issue": {"id": "r1", "identifier": "MT-8", "state": {"name": "Todo"}}}]},
      "createdAt": "2026-02-24T20:15:30.000Z",
      "updatedAt": "2026-02-25T09:00:00.000Z"|}
  in
  let request_fun = mock [ ok_page (node ~extra ()) ] in
  let%bind () =
    match%map
      Client.fetch_issues_by_states ~request_fun ~settings:(settings ()) [ "Todo" ]
    with
    | Error error -> print_s [%sexp (error : Client.Client_error.t)]
    | Ok issues -> print_s [%sexp (issues : Maestro_tracker.Issue.t list)]
  in
  [%expect
    {|
    (((id id-1) (native_ref ()) (identifier MT-1) (title "Fix it")
      (description ("Details here")) (priority (2)) (state Todo)
      (branch_name (mt-1-fix)) (url (https://linear.app/x/issue/MT-1))
      (assignee_id (user-9)) (labels (bug urgent))
      (blocked_by (((id (b1)) (identifier (MT-9)) (state (Done)))))
      (dispatchable true) (created_at ((2026-02-24 20:15:30.000000000Z)))
      (updated_at ((2026-02-25 09:00:00.000000000Z)))))
    |}];
  return ()
;;

let%expect_test "pagination preserves order; a missing cursor with more pages is an error"
  =
  let requests = ref [] in
  let request_fun =
    mock
      ~requests
      [ ok_page
          ~page_info:{|"pageInfo": {"hasNextPage": true, "endCursor": "cur-1"}|}
          (node ~id:"a" ~identifier:"MT-1" () ^ ", " ^ node ~id:"b" ~identifier:"MT-2" ())
      ; ok_page (node ~id:"c" ~identifier:"MT-3" ())
      ]
  in
  let%bind () =
    Client.fetch_issues_by_states ~request_fun ~settings:(settings ()) [ "Todo" ]
    >>| show_issues
  in
  [%expect {| (MT-1 MT-2 MT-3) |}];
  (* The second request carries the cursor. *)
  let second_body = (List.nth_exn !requests 1).body in
  print_s [%sexp (String.is_substring second_body ~substring:{|"after":"cur-1"|} : bool)];
  [%expect {| true |}];
  let request_fun =
    mock
      [ ok_page
          ~page_info:{|"pageInfo": {"hasNextPage": true, "endCursor": ""}|}
          (node ())
      ]
  in
  let%bind () =
    Client.fetch_issues_by_states ~request_fun ~settings:(settings ()) [ "Todo" ]
    >>| show_issues
  in
  [%expect {| Missing_end_cursor |}];
  return ()
;;

let%expect_test "malformed records: dropped on poll, fatal on id refresh" =
  let malformed =
    {|{"id": "x", "identifier": "", "title": "t", "state": {"name": "Todo"}}|}
  in
  let request_fun = mock [ ok_page (node () ^ ", " ^ malformed) ] in
  let%bind () =
    Client.fetch_issues_by_states ~request_fun ~settings:(settings ()) [ "Todo" ]
    >>| show_issues
  in
  [%expect {| (MT-1) |}];
  let request_fun = mock [ ok_page (node () ^ ", " ^ malformed) ] in
  let%bind () =
    Client.fetch_issues_by_ids ~request_fun ~settings:(settings ()) [ "id-1"; "x" ]
    >>| show_issues
  in
  [%expect {| Unknown_payload |}];
  return ()
;;

let%expect_test "id refresh re-sorts to request order and tolerates omissions" =
  let request_fun =
    mock
      [ ok_page
          (String.concat
             ~sep:", "
             [ node ~id:"b" ~identifier:"MT-2" (); node ~id:"a" ~identifier:"MT-1" () ])
      ]
  in
  let%bind () =
    Client.fetch_issues_by_ids
      ~request_fun
      ~settings:(settings ())
      [ "a"; "missing"; "b" ]
    >>| show_issues
  in
  [%expect {| (MT-1 MT-2) |}];
  return ()
;;

let%expect_test "dispatchable: assignee filter and todo-blocker gating" =
  let blocked_by state_json =
    [%string
      {|, "inverseRelations": {"nodes": [{"type": "blocks", "issue": {"id": "b", "identifier": "MT-9", "state": %{state_json}}}]}|}]
  in
  let show ?provider_yaml ~extra () =
    let request_fun = mock [ ok_page (node ~extra ()) ] in
    match%map
      Client.fetch_issues_by_states
        ~request_fun
        ~settings:(settings ?provider_yaml ())
        [ "Todo" ]
    with
    | Error error -> print_s [%sexp (error : Client.Client_error.t)]
    | Ok issues ->
      print_s
        [%sexp
          (List.map issues ~f:(fun (i : Maestro_tracker.Issue.t) -> i.dispatchable)
           : bool list)]
  in
  (* No assignee filter: everyone (even unassigned) is dispatchable. *)
  let%bind () = show ~extra:"" () in
  [%expect {| (true) |}];
  (* Literal assignee filter matches on the assignee id only. *)
  let with_assignee = {|    api_key: k
    project_slug: proj
    assignee: user-9|} in
  let%bind () =
    show ~provider_yaml:with_assignee ~extra:{|, "assignee": {"id": "user-9"}|} ()
  in
  [%expect {| (true) |}];
  let%bind () =
    show ~provider_yaml:with_assignee ~extra:{|, "assignee": {"id": "someone-else"}|} ()
  in
  [%expect {| (false) |}];
  let%bind () = show ~provider_yaml:with_assignee ~extra:"" () in
  [%expect {| (false) |}];
  (* Todo + live blocker blocks; terminal blocker doesn't; unreadable blocker state
     blocks; non-Todo states ignore blockers. *)
  let%bind () = show ~extra:(blocked_by {|{"name": "In Progress"}|}) () in
  [%expect {| (false) |}];
  let%bind () = show ~extra:(blocked_by {|{"name": "Done"}|}) () in
  [%expect {| (true) |}];
  let%bind () = show ~extra:(blocked_by "null") () in
  [%expect {| (false) |}];
  let in_progress_with_blocker =
    let todo_blocker = blocked_by {|{"name": "Todo"}|} in
    [%string
      {|{"id": "id-1", "identifier": "MT-1", "title": "Fix it", "state": {"name": "In Progress"}%{todo_blocker}}|}]
  in
  let request_fun = mock [ ok_page in_progress_with_blocker ] in
  let%bind () =
    match%map
      Client.fetch_issues_by_states ~request_fun ~settings:(settings ()) [ "In Progress" ]
    with
    | Error error -> print_s [%sexp (error : Client.Client_error.t)]
    | Ok issues ->
      print_s
        [%sexp
          (List.map issues ~f:(fun (i : Maestro_tracker.Issue.t) -> i.dispatchable)
           : bool list)]
  in
  [%expect {| (true) |}];
  return ()
;;

let%expect_test "assignee me resolves via the viewer query each fetch" =
  let me = {|    api_key: k
    project_slug: proj
    assignee: me|} in
  let requests = ref [] in
  let request_fun =
    mock
      ~requests
      [ Ok (200, {|{"data": {"viewer": {"id": "viewer-1"}}}|})
      ; ok_page (node ~extra:{|, "assignee": {"id": "viewer-1"}|} ())
      ]
  in
  let%bind () =
    match%map
      Client.fetch_issues_by_states
        ~request_fun
        ~settings:(settings ~provider_yaml:me ())
        [ "Todo" ]
    with
    | Error error -> print_s [%sexp (error : Client.Client_error.t)]
    | Ok issues ->
      print_s
        [%sexp
          (List.map issues ~f:(fun (i : Maestro_tracker.Issue.t) -> i.dispatchable)
           : bool list)]
  in
  [%expect {| (true) |}];
  print_s [%sexp (List.length !requests : int)];
  [%expect {| 2 |}];
  (* A viewer payload without an id is a distinct error. *)
  let request_fun = mock [ Ok (200, {|{"data": {"viewer": {}}}|}) ] in
  let%bind () =
    Client.fetch_issues_by_states
      ~request_fun
      ~settings:(settings ~provider_yaml:me ())
      [ "Todo" ]
    >>| show_issues
  in
  [%expect {| Missing_viewer_identity |}];
  return ()
;;

let%expect_test "transport and payload error mapping; raw Authorization header" =
  let requests = ref [] in
  let request_fun = mock ~requests [ Ok (500, "oops") ] in
  let%bind () =
    Client.fetch_issues_by_states ~request_fun ~settings:(settings ()) [ "Todo" ]
    >>| show_issues
  in
  [%expect {| (Api_status 500) |}];
  print_s [%sexp ((List.hd_exn !requests).headers : (string * string) list)];
  [%expect {| ((Authorization k) (Content-Type application/json)) |}];
  let request_fun = mock [ Ok (200, {|{"errors": [{"message": "boom"}]}|}) ] in
  let%bind () =
    Client.fetch_issues_by_states ~request_fun ~settings:(settings ()) [ "Todo" ]
    >>| show_issues
  in
  [%expect {| (Graphql_errors (Array ((Object ((message (String boom))))))) |}];
  let request_fun = mock [ Ok (200, "not json") ] in
  let%bind () =
    Client.fetch_issues_by_states ~request_fun ~settings:(settings ()) [ "Todo" ]
    >>| show_issues
  in
  [%expect {| Unknown_payload |}];
  return ()
;;

let%expect_test "linear_graphql tool: envelopes and exact error messages" =
  let show result = print_s [%sexp (result : Maestro_tracker.Adapter.Tool_result.t)] in
  let execute ?request_fun ?(name = "linear_graphql") arguments =
    Agent_tool.execute ?request_fun ~settings:(settings ()) ~name ~arguments ()
  in
  (* A bare string is the query; a successful response is passed through pretty. *)
  let request_fun = mock [ Ok (200, {|{"data": {"ok": true}}|}) ] in
  let%bind () = execute ~request_fun (`String "query { viewer { id } }") >>| show in
  [%expect
    {|
    ((success true) (output  "{\
                            \n  \"data\": {\
                            \n    \"ok\": true\
                            \n  }\
                            \n}")
     (content_items
      ((Object
        ((type (String inputText))
         (text (String  "{\
                       \n  \"data\": {\
                       \n    \"ok\": true\
                       \n  }\
                       \n}")))))))
    |}];
  (* GraphQL-level errors preserve the body with success=false. *)
  let request_fun = mock [ Ok (200, {|{"errors": [{"message": "nope"}]}|}) ] in
  let%bind () =
    execute ~request_fun (`Object [ "query", `String "mutation { x }" ])
    >>| fun result -> print_s [%sexp (result.success : bool)]
  in
  [%expect {| false |}];
  (* Argument validation messages are the reference's, verbatim. *)
  let%bind () = execute (`String "   ") >>| fun r -> print_string r.output in
  [%expect
    {|
    {
      "error": {
        "message": "`linear_graphql` requires a non-empty `query` string."
      }
    }
    |}];
  let%bind () = execute (`Number "42") >>| fun r -> print_string r.output in
  [%expect
    {|
    {
      "error": {
        "message": "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
    |}];
  let%bind () =
    execute (`Object [ "query", `String "q"; "variables", `String "not-an-object" ])
    >>| fun r -> print_string r.output
  in
  [%expect
    {|
    {
      "error": {
        "message": "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
    |}];
  (* Missing auth has the actionable message. *)
  let%bind () =
    Agent_tool.execute
      ~settings:(settings ~provider_yaml:{|    project_slug: proj|} ())
      ~name:"linear_graphql"
      ~arguments:(`String "query { x }")
      ()
    >>| fun r -> print_string r.output
  in
  [%expect
    {|
    {
      "error": {
        "message": "Symphony is missing Linear auth. Set `tracker.provider.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
    |}];
  (* HTTP failures carry the status. *)
  let request_fun = mock [ Ok (429, "slow down") ] in
  let%bind () = execute ~request_fun (`String "q") >>| fun r -> print_string r.output in
  [%expect
    {|
    {
      "error": {
        "message": "Linear GraphQL request failed with HTTP 429.",
        "status": 429
      }
    }
    |}];
  (* Unknown tool names fail fast, listing what is supported. *)
  let%bind () = execute ~name:"other_tool" `Null >>| fun r -> print_string r.output in
  [%expect
    {|
    {
      "error": {
        "message": "Unsupported dynamic tool: \"other_tool\".",
        "supportedTools": [
          "linear_graphql"
        ]
      }
    }
    |}];
  return ()
;;
