open! Core
open! Async
open Maestro_tracker
open Maestro_workflow
open Maestro

(* A fake codex app-server that completes each turn and writes a proof-of-work file, so a
   full run through the real driver reaches a running state and then completes. *)
let fake_codex_script ~result_file =
  [%string
    {|while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    *'"method":"initialized"'*) : ;;
    *'"method":"thread/start"'*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"th-1"}}}' ;;
    *'"method":"turn/start"'*) printf '%s\n' '{"id":3,"result":{"turn":{"id":"tu-1"}}}'; printf 'done\n' > "%{result_file}"; printf '%s\n' '{"method":"turn/completed"}' ;;
  esac
done|}]
;;

let issue ~id ~identifier ~state =
  { Issue.id
  ; native_ref = None
  ; identifier
  ; title = "Do the thing"
  ; description = None
  ; priority = None
  ; state
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

let%expect_test "end-to-end: driver dispatches, runs a real fake-codex, and reflects \
                 state"
  =
  Log.Global.set_output [];
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let script = dir ^/ "fake-codex.sh" in
    let result_file = dir ^/ "proof.txt" in
    let%bind () = Writer.save script ~contents:(fake_codex_script ~result_file) in
    let workflow_path = dir ^/ "WORKFLOW.md" in
    let%bind () =
      Writer.save
        workflow_path
        ~contents:
          [%string
            {|---
tracker:
  kind: memory
  active_states: [Todo, In Progress]
  terminal_states: [Done]
workspace:
  root: "%{dir}/ws"
polling:
  interval_ms: 60000
codex:
  command: sh %{script}
  read_timeout_ms: 2000
  approval_policy: never
---
Work on {{ issue.identifier }}.|}]
    in
    (* The board holds one active issue; the memory adapter serves it live. *)
    let board = ref [ issue ~id:"a" ~identifier:"MT-1" ~state:"Todo" ] in
    let%bind store =
      Workflow_store.create ~path:workflow_path ~getenv:(fun (_ : string) -> None)
      >>| ok_exn
    in
    let%bind driver =
      Driver.start ~workflow_store:store ~make_adapter:(fun tracker ->
        Adapter_registry.build ~memory_issues:(fun () -> !board) tracker)
      >>| ok_exn
    in
    (* Wait until the fake codex has written its proof file (the turn ran). *)
    let%bind () =
      Deferred.repeat_until_finished () (fun () ->
        match%bind Sys.file_exists_exn result_file with
        | true -> return (`Finished ())
        | false ->
          let%map () = Clock_ns.after (Time_ns.Span.of_int_ms 20) in
          `Repeat ())
    in
    let%bind proof = Reader.file_contents result_file in
    print_s [%message "proof of work written" (proof : string)];
    [%expect {| ("proof of work written" (proof "done\n")) |}];
    (* The issue reaches Done; drive a refresh so reconciliation cleans it up. Give the
       worker a moment to exit and the continuation retry to release it. *)
    board := [ issue ~id:"a" ~identifier:"MT-1" ~state:"Done" ];
    let%bind (_ : _) = Driver.request_refresh driver in
    let%bind () =
      Deferred.repeat_until_finished 0 (fun tries ->
        let%bind snapshot = Driver.snapshot driver in
        match List.is_empty snapshot.running, tries > 200 with
        | true, _ | _, true -> return (`Finished ())
        | false, false ->
          let%bind (_ : _) = Driver.request_refresh driver in
          let%map () = Clock_ns.after (Time_ns.Span.of_int_ms 20) in
          `Repeat (tries + 1))
    in
    let%bind snapshot = Driver.snapshot driver in
    print_s
      [%message
        ""
          ~running:(List.length snapshot.running : int)
          ~total_tokens:(snapshot.codex_totals.total_tokens : int)];
    [%expect {| ((running 0) (total_tokens 0)) |}];
    let%bind () = Driver.close driver in
    Workflow_store.close store;
    return ())
;;
