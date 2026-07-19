open! Core
open! Async
open Maestro_workflow

let getenv (_ : string) = None

let valid_workflow ~prompt = [%string {|---
tracker:
  kind: memory
---
%{prompt}|}]

let%expect_test "store: strict startup, reload on read, last-known-good on bad edits" =
  (* The store logs reload failures to the global log; silence it so timestamps and temp
     paths don't pollute the expect output. *)
  Log.Global.set_output [];
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let path = dir ^/ "WORKFLOW.md" in
    let scrub string = String.substr_replace_all string ~pattern:dir ~with_:"TMP" in
    (* Startup with a missing file is strict. *)
    let%bind () =
      match%map Workflow_store.create ~path ~getenv with
      | Ok (_ : Workflow_store.t) -> print_string "unexpectedly created\n"
      | Error error ->
        print_s [%sexp (Error.of_string (scrub (Error.to_string_hum error)) : Error.t)]
    in
    [%expect
      {|
       "(missing_workflow_file\
      \n (path TMP/WORKFLOW.md)\
      \n (reason \"No such file or directory (open)\"))"
      |}];
    (* Valid initial load. *)
    let%bind () =
      Writer.save path ~contents:(valid_workflow ~prompt:"Original prompt.")
    in
    let%bind store = Workflow_store.create ~path ~getenv >>| ok_exn in
    let show () =
      let%map loaded = Workflow_store.current store in
      let%tydi { config; prompt_template; front_matter = _ } = loaded in
      print_s
        [%message (prompt_template : string) ~kind:(config.tracker.kind : string option)]
    in
    let%bind () = show () in
    [%expect {| ((prompt_template "Original prompt.") (kind (memory))) |}];
    (* An edit is picked up on the next read, without waiting for the poll. *)
    let%bind () = Writer.save path ~contents:(valid_workflow ~prompt:"Edited prompt.") in
    let%bind () = show () in
    [%expect {| ((prompt_template "Edited prompt.") (kind (memory))) |}];
    (* An invalid edit keeps the last known good workflow... *)
    let%bind () = Writer.save path ~contents:"---\n- not\n- a\n- map\n---\nbad" in
    let%bind () = show () in
    [%expect {| ((prompt_template "Edited prompt.") (kind (memory))) |}];
    (* ...and force_reload surfaces the error while still keeping the good state. *)
    let%bind () =
      match%map Workflow_store.force_reload store with
      | Ok (_ : Workflow.Loaded.t) -> print_string "unexpectedly reloaded\n"
      | Error error -> print_s [%sexp (error : Error.t)]
    in
    [%expect {| workflow_front_matter_not_a_map |}];
    let%bind () = show () in
    [%expect {| ((prompt_template "Edited prompt.") (kind (memory))) |}];
    (* Fixing the file recovers on the next read. *)
    let%bind () = Writer.save path ~contents:(valid_workflow ~prompt:"Fixed prompt.") in
    let%bind () = show () in
    [%expect {| ((prompt_template "Fixed prompt.") (kind (memory))) |}];
    Workflow_store.close store;
    return ())
;;
