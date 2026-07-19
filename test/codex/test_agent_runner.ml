open! Core
open! Async
open Maestro_tracker
open Maestro_codex

let () = Log.Global.set_output []

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

(* An adapter whose id-refreshes pop from a scripted queue, so tests control the
   continuation decision after each turn. *)
let scripted_adapter ~refetch_results =
  let remaining = ref refetch_results in
  let base = Memory.create ~issues:(fun () -> []) in
  { base with
    Adapter.fetch_issues_by_ids =
      (fun (_ : string list) ->
        match !remaining with
        | [] -> Deferred.Or_error.error_s [%message "scripted refetch exhausted"]
        | result :: rest ->
          remaining := rest;
          Deferred.return result)
  }
;;

let load_workflow ~dir ~script ~extra_yaml ~prompt =
  Maestro_workflow.Workflow.parse_contents
    [%string
      {|---
tracker:
  kind: memory
workspace:
  root: "%{dir}/ws"
codex:
  command: sh %{script}
  read_timeout_ms: 2000
%{extra_yaml}---
%{prompt}|}]
    ~workflow_dir:dir
    ~getenv:(fun (_ : string) -> None)
  |> ok_exn
;;

let run ~workflow ~adapter ~attempt =
  let%tydi { Maestro_workflow.Workflow.Loaded.config; _ } = workflow in
  Agent_runner.run
    ~config
    ~workflow
    ~adapter
    ~issue:test_issue
    ~attempt
    ~on_update:(fun (_ : Update.t) -> ())
    ~on_runtime_info:(fun ~workspace_path:(_ : string) -> ())
;;

let show_result ~scrub result =
  match result with
  | Ok () -> print_string "run: ok\n"
  | Error error ->
    print_s [%sexp (Error.of_string (scrub (Error.to_string_hum error)) : Error.t)]
;;

let%expect_test "continuation loop: task prompt once, guidance on later turns, stop when \
                 inactive"
  =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let trace = dir ^/ "trace.log" in
    let scrub string = String.substr_replace_all string ~pattern:dir ~with_:"TMP" in
    let%bind script = Fake_codex.write ~dir ~trace () in
    let workflow =
      load_workflow
        ~dir
        ~script
        ~extra_yaml:""
        ~prompt:
          "Work on {{ issue.identifier }}: {{ issue.title }} (attempt {{ attempt }})"
    in
    (* First refetch: still active -> continuation turn. Second: moved out of the active
       states -> loop ends. *)
    let adapter =
      scripted_adapter
        ~refetch_results:
          [ Ok [ test_issue ]; Ok [ { test_issue with state = "Human Review" } ] ]
    in
    let%bind () = run ~workflow ~adapter ~attempt:None >>| show_result ~scrub in
    [%expect {| run: ok |}];
    let%bind trace_lines = Reader.file_lines trace in
    let turn_prompts =
      List.filter_map trace_lines ~f:(fun line ->
        match String.is_substring line ~substring:{|"method":"turn/start"|} with
        | false -> None
        | true ->
          (match
             ( String.is_substring line ~substring:"Work on MT-1: Fix the widget"
             , String.is_substring line ~substring:"Continuation guidance" )
           with
           | true, false -> Some "task-prompt"
           | false, true ->
             (match String.is_substring line ~substring:"turn #2 of 20" with
              | true -> Some "continuation-2-of-20"
              | false -> Some "continuation-other")
           | _ -> Some "unexpected"))
    in
    print_s [%sexp (turn_prompts : string list)];
    [%expect {| (task-prompt continuation-2-of-20) |}];
    return ())
;;

let%expect_test "max_turns caps the in-process loop as a normal exit" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let trace = dir ^/ "trace.log" in
    let scrub string = String.substr_replace_all string ~pattern:dir ~with_:"TMP" in
    let%bind script = Fake_codex.write ~dir ~trace () in
    let workflow =
      load_workflow ~dir ~script ~extra_yaml:"agent:\n  max_turns: 2\n" ~prompt:"p"
    in
    (* Always active: only the cap stops the loop. *)
    let adapter =
      scripted_adapter ~refetch_results:[ Ok [ test_issue ]; Ok [ test_issue ] ]
    in
    let%bind () = run ~workflow ~adapter ~attempt:(Some 3) >>| show_result ~scrub in
    [%expect {| run: ok |}];
    let%bind trace_lines = Reader.file_lines trace in
    let turns =
      List.count trace_lines ~f:(String.is_substring ~substring:{|"method":"turn/start"|})
    in
    print_s [%sexp (turns : int)];
    [%expect {| 2 |}];
    return ())
;;

let%expect_test "issue refresh failure fails the attempt" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let trace = dir ^/ "trace.log" in
    let scrub string = String.substr_replace_all string ~pattern:dir ~with_:"TMP" in
    let%bind script = Fake_codex.write ~dir ~trace () in
    let workflow = load_workflow ~dir ~script ~extra_yaml:"" ~prompt:"p" in
    let adapter =
      scripted_adapter
        ~refetch_results:[ Or_error.error_s [%message "tracker unavailable"] ]
    in
    let%bind () = run ~workflow ~adapter ~attempt:None >>| show_result ~scrub in
    [%expect {| "(issue_state_refresh_failed \"tracker unavailable\")" |}];
    return ())
;;

let%expect_test "before_run failure aborts before any session; after_run always runs" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let trace = dir ^/ "trace.log" in
    let scrub string = String.substr_replace_all string ~pattern:dir ~with_:"TMP" in
    let%bind script = Fake_codex.write ~dir ~trace () in
    let workflow =
      load_workflow
        ~dir
        ~script
        ~extra_yaml:
          "hooks:\n  before_run: |\n    exit 9\n  after_run: |\n    touch after-run-ran\n"
        ~prompt:"p"
    in
    let adapter = scripted_adapter ~refetch_results:[] in
    let%bind () = run ~workflow ~adapter ~attempt:None >>| show_result ~scrub in
    [%expect
      {|
       "(workspace_hook_failed (hook before_run) (status \"exited with code 9\")\
      \n (output \"\"))"
      |}];
    let%bind session_started = Sys.file_exists_exn trace in
    let%bind after_ran = Sys.file_exists_exn (dir ^/ "ws" ^/ "MT-1" ^/ "after-run-ran") in
    print_s [%message (session_started : bool) (after_ran : bool)];
    [%expect {| ((session_started false) (after_ran true)) |}];
    return ())
;;

let%expect_test "strict template failure fails the attempt before any turn" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let trace = dir ^/ "trace.log" in
    let scrub string = String.substr_replace_all string ~pattern:dir ~with_:"TMP" in
    let%bind script = Fake_codex.write ~dir ~trace () in
    let workflow =
      load_workflow ~dir ~script ~extra_yaml:"" ~prompt:"{{ issue.no_such_field }}"
    in
    let adapter = scripted_adapter ~refetch_results:[] in
    let%bind () = run ~workflow ~adapter ~attempt:None >>| show_result ~scrub in
    [%expect
      {| "(template_render_error (\"unknown variable\" (path issue.no_such_field)))" |}];
    return ())
;;
