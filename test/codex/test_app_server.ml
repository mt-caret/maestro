open! Core
open! Async
open Maestro_tracker
open Maestro_codex

let () = Log.Global.set_output []

(* Test-only: mutating the environment is safe in this single-domain test binary. *)
let putenv = (Core_unix.putenv [@alert "-unsafe_multidomain"])
let write_fake_codex = Fake_codex.write

let make_config ~dir ~script ?(codex_yaml = "") ?(tracker_yaml = "  kind: memory") () =
  let contents =
    [%string
      {|---
tracker:
%{tracker_yaml}
workspace:
  root: "%{dir}/ws"
codex:
  command: sh %{script}
  read_timeout_ms: 2000
%{codex_yaml}
---
p|}]
  in
  let loaded =
    Maestro_workflow.Workflow.parse_contents
      contents
      ~workflow_dir:dir
      ~getenv:(fun (_ : string) -> None)
    |> ok_exn
  in
  loaded.config
;;

let test_issue =
  { Issue.id = "id-1"
  ; native_ref = None
  ; identifier = "MT-1"
  ; title = "Fix the widget"
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
;;

let memory_adapter = Memory.create ~issues:(fun () -> [ test_issue ])

let collect_updates () =
  let updates = ref [] in
  let on_update (update : Update.t) = updates := update :: !updates in
  let show () =
    List.rev !updates
    |> List.iter ~f:(fun (update : Update.t) ->
      print_s
        [%message
          "" ~_:(update.event : Update.Event.t) ~detail:(update.detail : string option)])
  in
  on_update, show
;;

let with_session ~dir ~config ~adapter ~f =
  let%bind workspace =
    Maestro_workspace.Workspace.create_for_issue ~config ~identifier:"MT-1" >>| ok_exn
  in
  let on_update, show_updates = collect_updates () in
  match%bind
    App_server.start_session ~config ~workspace:workspace.path ~adapter ~on_update
  with
  | Error error ->
    print_s [%sexp (error : Error.t)];
    show_updates ();
    return (`No_session (dir ^/ "unused"))
  | Ok session ->
    let%bind () = f session in
    let%map () = App_server.stop_session session in
    show_updates ();
    `Ran
;;

let show_turn_result result =
  match result with
  | Ok () -> print_string "turn: completed\n"
  | Error error ->
    (* The payload sexp includes the whole message; keep just the head for stability. *)
    let head =
      match Error.sexp_of_t error with
      | Sexp.List (Sexp.Atom head :: _) | Sexp.Atom head -> head
      | Sexp.List _ -> "?"
    in
    print_string [%string "turn: error %{head}\n"]
;;

let%expect_test "handshake + one turn: wire contents and event stream" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let trace = dir ^/ "trace.log" in
    let%bind script = write_fake_codex ~dir ~trace () in
    let config = make_config ~dir ~script () in
    let%bind (_ : [ `Ran | `No_session of string ]) =
      with_session ~dir ~config ~adapter:memory_adapter ~f:(fun session ->
        print_s [%message (App_server.Session.thread_id session : string)];
        let%map result =
          App_server.run_turn session ~prompt:"Do the thing." ~issue:test_issue
        in
        show_turn_result result)
    in
    [%expect
      {|
      ("App_server.Session.thread_id session" th-1)
      turn: completed
      (Session_started (detail ()))
      (Turn_completed (detail ()))
      |}];
    (* What we sent: initialize with client identity, thread/start with cwd +
       dynamicTools, turn/start with title + prompt + default sandbox policy. *)
    let%bind trace_lines = Reader.file_lines trace in
    let has substring =
      List.exists trace_lines ~f:(fun line -> String.is_substring line ~substring)
    in
    print_s
      [%message
        ""
          ~initialize_client:(has {|"clientInfo":{"name":"maestro"|} : bool)
          ~experimental_api:(has {|"experimentalApi":true|} : bool)
          ~thread_start_dynamic_tools:(has {|"dynamicTools":[]|} : bool)
          ~thread_cwd:(has {|/ws/MT-1|} : bool)
          ~turn_title:(has {|"title":"MT-1: Fix the widget"|} : bool)
          ~prompt:(has {|Do the thing.|} : bool)
          ~default_sandbox:(has {|"type":"workspaceWrite"|} : bool)
          ~network_off:(has {|"networkAccess":false|} : bool)];
    [%expect
      {|
      ((initialize_client true) (experimental_api true)
       (thread_start_dynamic_tools true) (thread_cwd true) (turn_title true)
       (prompt true) (default_sandbox true) (network_off true))
      |}];
    return ())
;;

let%expect_test "approvals auto-accepted only under policy \"never\", with \
                 per-generation decision strings"
  =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let trace = dir ^/ "trace.log" in
    let on_turn_start =
      {|printf '%s\n' '{"id":90,"method":"item/commandExecution/requestApproval","params":{}}'|}
    in
    let extra_cases =
      {|    *'"id":90,"result"'*) printf '%s\n' '{"id":91,"method":"execCommandApproval","params":{}}' ;;
    *'"id":91,"result"'*) printf '%s\n' '{"method":"turn/completed"}' ;;|}
    in
    let%bind script = write_fake_codex ~dir ~trace ~on_turn_start ~extra_cases () in
    let config = make_config ~dir ~script ~codex_yaml:"  approval_policy: never" () in
    let%bind (_ : [ `Ran | `No_session of string ]) =
      with_session ~dir ~config ~adapter:memory_adapter ~f:(fun session ->
        let%map result = App_server.run_turn session ~prompt:"p" ~issue:test_issue in
        show_turn_result result)
    in
    [%expect
      {|
      turn: completed
      (Session_started (detail ()))
      (Approval_auto_approved (detail (acceptForSession)))
      (Approval_auto_approved (detail (approved_for_session)))
      (Turn_completed (detail ()))
      |}];
    let%bind trace_lines = Reader.file_lines trace in
    let decisions =
      List.filter trace_lines ~f:(String.is_substring ~substring:"decision")
    in
    print_s [%sexp (decisions : string list)];
    [%expect
      {|
      ("{\"id\":90,\"result\":{\"decision\":\"acceptForSession\"}}"
       "{\"id\":91,\"result\":{\"decision\":\"approved_for_session\"}}")
      |}];
    return ())
;;

let%expect_test "default (strict) policy hard-fails approvals instead of hanging" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let trace = dir ^/ "trace.log" in
    let on_turn_start =
      {|printf '%s\n' '{"id":90,"method":"item/fileChange/requestApproval","params":{}}'; sleep 30|}
    in
    let%bind script = write_fake_codex ~dir ~trace ~on_turn_start () in
    let config = make_config ~dir ~script () in
    let%bind (_ : [ `Ran | `No_session of string ]) =
      with_session ~dir ~config ~adapter:memory_adapter ~f:(fun session ->
        let%map result = App_server.run_turn session ~prompt:"p" ~issue:test_issue in
        show_turn_result result)
    in
    [%expect
      {|
      turn: error approval_required
      (Session_started (detail ()))
      (Approval_required (detail ()))
      |}];
    return ())
;;

let%expect_test "requestUserInput: approve-ish label when auto; canned answer otherwise; \
                 missing id fails"
  =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let trace = dir ^/ "trace.log" in
    let question ~id_field =
      [%string
        {|{"id":80,"method":"item/tool/requestUserInput","params":{"questions":[{%{id_field}"header":"h","question":"Allow?","options":[{"label":"Approve this Session"},{"label":"Deny"}]}]}}|}]
    in
    let on_turn_start =
      let question_with_id = question ~id_field:{|"id":"q1",|} in
      [%string {|printf '%s\n' '%{question_with_id}'|}]
    in
    let extra_cases =
      {|    *'"answers"'*) printf '%s\n' '{"method":"turn/completed"}' ;;|}
    in
    let%bind script = write_fake_codex ~dir ~trace ~on_turn_start ~extra_cases () in
    (* Auto-approve: picks the approval label. *)
    let config = make_config ~dir ~script ~codex_yaml:"  approval_policy: never" () in
    let%bind (_ : [ `Ran | `No_session of string ]) =
      with_session ~dir ~config ~adapter:memory_adapter ~f:(fun session ->
        let%map result = App_server.run_turn session ~prompt:"p" ~issue:test_issue in
        show_turn_result result)
    in
    [%expect
      {|
      turn: completed
      (Session_started (detail ()))
      (Approval_auto_approved (detail ("Approve this Session")))
      (Turn_completed (detail ()))
      |}];
    let%bind trace_lines = Reader.file_lines trace in
    let answers =
      List.filter trace_lines ~f:(String.is_substring ~substring:{|"answers"|})
    in
    print_s [%sexp (answers : string list)];
    [%expect
      {|
      ("{\"id\":80,\"result\":{\"answers\":{\"q1\":{\"answers\":[\"Approve this Session\"]}}}}")
      |}];
    (* Strict policy: every question still gets the canned non-interactive answer. *)
    let trace2 = dir ^/ "trace2.log" in
    let%bind script =
      write_fake_codex ~dir ~trace:trace2 ~on_turn_start ~extra_cases ()
    in
    let config = make_config ~dir ~script () in
    let%bind (_ : [ `Ran | `No_session of string ]) =
      with_session ~dir ~config ~adapter:memory_adapter ~f:(fun session ->
        let%map result = App_server.run_turn session ~prompt:"p" ~issue:test_issue in
        show_turn_result result)
    in
    [%expect
      {|
      turn: completed
      (Session_started (detail ()))
      (Tool_input_auto_answered
       (detail
        ("This is a non-interactive session. Operator input is unavailable.")))
      (Turn_completed (detail ()))
      |}];
    (* A question without an id cannot be answered: hard input-required failure. *)
    let trace3 = dir ^/ "trace3.log" in
    let on_turn_start = [%string {|printf '%s\n' '%{question ~id_field:""}'|}] in
    let%bind script = write_fake_codex ~dir ~trace:trace3 ~on_turn_start () in
    let config = make_config ~dir ~script ~codex_yaml:"  approval_policy: never" () in
    let%bind (_ : [ `Ran | `No_session of string ]) =
      with_session ~dir ~config ~adapter:memory_adapter ~f:(fun session ->
        let%map result = App_server.run_turn session ~prompt:"p" ~issue:test_issue in
        show_turn_result result)
    in
    [%expect
      {|
      turn: error turn_input_required
      (Session_started (detail ()))
      (Turn_input_required (detail ()))
      |}];
    return ())
;;

let%expect_test "dynamic tool calls execute host-side and never stall; MCP elicitation \
                 fails even under never"
  =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let trace = dir ^/ "trace.log" in
    let on_turn_start =
      {|printf '%s\n' '{"id":70,"method":"item/tool/call","params":{"tool":"nope_tool","arguments":{}}}'|}
    in
    let extra_cases =
      {|    *'"id":70,"result"'*) printf '%s\n' '{"method":"turn/completed"}' ;;|}
    in
    let%bind script = write_fake_codex ~dir ~trace ~on_turn_start ~extra_cases () in
    let config = make_config ~dir ~script () in
    let%bind (_ : [ `Ran | `No_session of string ]) =
      with_session ~dir ~config ~adapter:memory_adapter ~f:(fun session ->
        let%map result = App_server.run_turn session ~prompt:"p" ~issue:test_issue in
        show_turn_result result)
    in
    [%expect
      {|
      turn: completed
      (Session_started (detail ()))
      (Tool_call_failed (detail ()))
      (Turn_completed (detail ()))
      |}];
    let%bind trace_lines = Reader.file_lines trace in
    let tool_replies =
      List.filter trace_lines ~f:(String.is_substring ~substring:{|"success":false|})
    in
    print_s [%sexp (List.length tool_replies : int)];
    [%expect {| 1 |}];
    (* MCP elicitation is a hard input failure regardless of policy. *)
    let trace2 = dir ^/ "trace2.log" in
    let on_turn_start =
      {|printf '%s\n' '{"id":60,"method":"mcpServer/elicitation/request","params":{}}'|}
    in
    let%bind script = write_fake_codex ~dir ~trace:trace2 ~on_turn_start () in
    let config = make_config ~dir ~script ~codex_yaml:"  approval_policy: never" () in
    let%bind (_ : [ `Ran | `No_session of string ]) =
      with_session ~dir ~config ~adapter:memory_adapter ~f:(fun session ->
        let%map result = App_server.run_turn session ~prompt:"p" ~issue:test_issue in
        show_turn_result result)
    in
    [%expect
      {|
      turn: error turn_input_required
      (Session_started (detail ()))
      (Turn_input_required (detail ()))
      |}];
    return ())
;;

let%expect_test "stderr noise never disturbs the protocol stream" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let trace = dir ^/ "trace.log" in
    let on_turn_start =
      {|printf 'ERROR: scary diagnostic noise\n' >&2; printf '%s\n' '{"method":"turn/completed"}'|}
    in
    let%bind script = write_fake_codex ~dir ~trace ~on_turn_start () in
    let config = make_config ~dir ~script () in
    let%bind (_ : [ `Ran | `No_session of string ]) =
      with_session ~dir ~config ~adapter:memory_adapter ~f:(fun session ->
        let%map result = App_server.run_turn session ~prompt:"p" ~issue:test_issue in
        show_turn_result result)
    in
    [%expect
      {|
      turn: completed
      (Session_started (detail ()))
      (Turn_completed (detail ()))
      |}];
    return ())
;;

let%expect_test "subprocess exit mid-turn is port_exit; slow startup is response_timeout" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let trace = dir ^/ "trace.log" in
    let on_turn_start = {|exit 0|} in
    let%bind script = write_fake_codex ~dir ~trace ~on_turn_start () in
    let config = make_config ~dir ~script () in
    let%bind (_ : [ `Ran | `No_session of string ]) =
      with_session ~dir ~config ~adapter:memory_adapter ~f:(fun session ->
        let%map result = App_server.run_turn session ~prompt:"p" ~issue:test_issue in
        show_turn_result result)
    in
    [%expect {|
      turn: error port_exit
      (Session_started (detail ()))
      |}];
    (* A server that never answers initialize trips the read timeout. *)
    let%bind () = Writer.save (dir ^/ "slow.sh") ~contents:"sleep 30\n" in
    let config =
      make_config ~dir ~script:(dir ^/ "slow.sh") ~codex_yaml:"  read_timeout_ms: 150" ()
    in
    let on_update, (_ : unit -> unit) = collect_updates () in
    let%bind workspace =
      Maestro_workspace.Workspace.create_for_issue ~config ~identifier:"MT-1" >>| ok_exn
    in
    let%bind () =
      match%map
        App_server.start_session
          ~config
          ~workspace:workspace.path
          ~adapter:memory_adapter
          ~on_update
      with
      | Ok (_ : App_server.Session.t) -> print_string "unexpectedly started\n"
      | Error error ->
        (match Error.sexp_of_t error with
         | Sexp.List (head :: _) -> print_s head
         | sexp -> print_s sexp)
    in
    [%expect {| response_timeout |}];
    return ())
;;

let%expect_test "secret env names are scrubbed at spawn and survive bash -l profiles" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let trace = dir ^/ "trace.log" in
    (* The fake HOME re-exports the secret from its profile; the client must unset it
       after the profile runs. MARKER proves the profile actually loaded. *)
    let home = dir ^/ "home" in
    let%bind () = Unix.mkdir ~p:() home in
    let%bind () =
      Writer.save
        (home ^/ ".bash_profile")
        ~contents:
          "export LINEAR_API_KEY=leaked-by-profile\nexport PROFILE_MARKER=loaded\n"
    in
    putenv ~key:"HOME" ~data:home;
    putenv ~key:"LINEAR_API_KEY" ~data:"secret-from-parent";
    let probe = dir ^/ "probe.sh" in
    let%bind () =
      Writer.save
        probe
        ~contents:
          [%string
            {|printf 'SECRET:[%s] MARKER:[%s]\n' "$LINEAR_API_KEY" "$PROFILE_MARKER" >> "%{trace}"
exec sh %{dir}/fake-codex.sh|}]
    in
    let%bind (_ : string) = write_fake_codex ~dir ~trace () in
    let tracker_yaml =
      {|  kind: linear
  provider:
    api_key: k
    project_slug: proj|}
    in
    let config =
      let contents =
        [%string
          {|---
tracker:
%{tracker_yaml}
workspace:
  root: "%{dir}/ws"
codex:
  command: sh %{probe}
  read_timeout_ms: 2000
---
p|}]
      in
      (Maestro_workflow.Workflow.parse_contents
         contents
         ~workflow_dir:dir
         ~getenv:Sys.getenv
       |> ok_exn)
        .config
    in
    let%bind (_ : [ `Ran | `No_session of string ]) =
      with_session ~dir ~config ~adapter:memory_adapter ~f:(fun session ->
        let%map result = App_server.run_turn session ~prompt:"p" ~issue:test_issue in
        show_turn_result result)
    in
    [%expect
      {|
      turn: completed
      (Session_started (detail ()))
      (Turn_completed (detail ()))
      |}];
    let%bind trace_lines = Reader.file_lines trace in
    let probe_line =
      List.find trace_lines ~f:(String.is_substring ~substring:"SECRET:")
    in
    print_s [%sexp (probe_line : string option)];
    [%expect {| ("SECRET:[] MARKER:[loaded]") |}];
    return ())
;;
