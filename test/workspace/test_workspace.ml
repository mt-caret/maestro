open! Core
open! Async
open Maestro_workspace

(* Hook failures log to the global log; silence it so timestamps and temp paths don't
   pollute the expect output. *)
let () = Log.Global.set_output []

let%expect_test "keys: clean identifiers pass through; sanitization appends a stable hash"
  =
  let show identifier = print_s [%sexp (Workspace.key ~identifier : string)] in
  show "MT-101";
  [%expect {| MT-101 |}];
  show "team_a-1.x";
  [%expect {| team_a-1.x |}];
  (* Distinct identifiers that sanitize to the same text get distinct keys. *)
  show "team/a-1";
  [%expect {| team_a-1--7c03d5a56ca4204b |}];
  show "team_a-1";
  [%expect {| team_a-1 |}];
  show "ABC 123/x";
  [%expect {| ABC_123_x--884ce005276fdcc0 |}];
  return ()
;;

let make_config ~root ~extra_yaml =
  let contents =
    [%string
      "---\n\
       tracker:\n\
      \  kind: memory\n\
       workspace:\n\
      \  root: \"%{root}\"\n\
       %{extra_yaml}---\n\
       p"]
  in
  let loaded =
    Maestro_workflow.Workflow.parse_contents
      contents
      ~workflow_dir:"/unused"
      ~getenv:(fun (_ : string) -> None)
    |> ok_exn
  in
  loaded.config
;;

let%expect_test "create: fresh, reuse preserving contents, and debris replacement" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let root = dir ^/ "workspaces" in
    let config = make_config ~root ~extra_yaml:"" in
    let scrub string = String.substr_replace_all string ~pattern:dir ~with_:"TMP" in
    let create () =
      match%map Workspace.create_for_issue ~config ~identifier:"MT-1" with
      | Ok created ->
        let%tydi { path; created_now } = created in
        print_s [%message (scrub path : string) (created_now : bool)]
      | Error error ->
        print_s [%sexp (Error.of_string (scrub (Error.to_string_hum error)) : Error.t)]
    in
    let%bind () = create () in
    [%expect {| (("scrub path" TMP/workspaces/MT-1) (created_now true)) |}];
    (* Reuse: local state survives. *)
    let%bind () = Writer.save (root ^/ "MT-1" ^/ "state.txt") ~contents:"kept" in
    let%bind () = create () in
    [%expect {| (("scrub path" TMP/workspaces/MT-1) (created_now false)) |}];
    let%bind contents = Reader.file_contents (root ^/ "MT-1" ^/ "state.txt") in
    print_string contents;
    [%expect {| kept |}];
    (* Non-directory debris at the workspace path is replaced. *)
    let%bind () = Workspace.remove_for_issue ~config ~identifier:"MT-1" >>| ok_exn in
    let%bind () = Writer.save (root ^/ "MT-1") ~contents:"debris" in
    let%bind () = create () in
    [%expect {| (("scrub path" TMP/workspaces/MT-1) (created_now true)) |}];
    return ())
;;

let%expect_test "after_create runs only on fresh directories; failure removes the new dir"
  =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let root = dir ^/ "ws" in
    let scrub string = String.substr_replace_all string ~pattern:dir ~with_:"TMP" in
    (* A hook that leaves evidence, then a hook that fails. *)
    let ok_config =
      make_config
        ~root
        ~extra_yaml:"hooks:\n  after_create: |\n    touch created-by-hook\n"
    in
    let%bind () =
      Workspace.create_for_issue ~config:ok_config ~identifier:"MT-2"
      >>| ok_exn
      >>| (ignore : Workspace.Created.t -> unit)
    in
    let%bind hook_ran = Sys.file_exists_exn (root ^/ "MT-2" ^/ "created-by-hook") in
    print_s [%sexp (hook_ran : bool)];
    [%expect {| true |}];
    (* Reuse does not re-run the hook. *)
    let%bind () = Unix.unlink (root ^/ "MT-2" ^/ "created-by-hook") in
    let%bind () =
      Workspace.create_for_issue ~config:ok_config ~identifier:"MT-2"
      >>| ok_exn
      >>| (ignore : Workspace.Created.t -> unit)
    in
    let%bind hook_ran = Sys.file_exists_exn (root ^/ "MT-2" ^/ "created-by-hook") in
    print_s [%sexp (hook_ran : bool)];
    [%expect {| false |}];
    (* A failing after_create fails creation and removes the fresh directory so the next
       attempt re-creates it from scratch. *)
    let failing_config =
      make_config
        ~root
        ~extra_yaml:"hooks:\n  after_create: |\n    echo boom >&2\n    exit 3\n"
    in
    let%bind () =
      match%map Workspace.create_for_issue ~config:failing_config ~identifier:"MT-3" with
      | Ok (_ : Workspace.Created.t) -> print_string "unexpectedly created\n"
      | Error error ->
        print_s [%sexp (Error.of_string (scrub (Error.to_string_hum error)) : Error.t)]
    in
    [%expect
      {|
       "(workspace_hook_failed (hook after_create) (status \"exited with code 3\")\
      \n (output \"boom\\n\"))"
      |}];
    let%bind dir_left = Sys.file_exists_exn (root ^/ "MT-3") in
    print_s [%sexp (dir_left : bool)];
    [%expect {| false |}];
    return ())
;;

let%expect_test "hook timeout is bounded and reported" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let root = dir ^/ "ws" in
    let config =
      make_config
        ~root
        ~extra_yaml:"hooks:\n  timeout_ms: 100\n  after_create: |\n    sleep 30\n"
    in
    let%bind () =
      match%map Workspace.create_for_issue ~config ~identifier:"MT-4" with
      | Ok (_ : Workspace.Created.t) -> print_string "unexpectedly created\n"
      | Error error -> print_s [%sexp (error : Error.t)]
    in
    [%expect {| (workspace_hook_timeout (hook after_create) (timeout 100ms)) |}];
    return ())
;;

let%expect_test "containment: traversal, symlink escape, equals-root, symlinked root" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let root = dir ^/ "ws" in
    let config = make_config ~root ~extra_yaml:"" in
    let scrub string = String.substr_replace_all string ~pattern:dir ~with_:"TMP" in
    let%bind () = Unix.mkdir ~p:() root in
    let try_create identifier =
      match%map Workspace.create_for_issue ~config ~identifier with
      | Ok created ->
        let%tydi { path; created_now = _ } = created in
        print_s [%sexp (scrub path : string)]
      | Error error ->
        print_s [%sexp (Error.of_string (scrub (Error.to_string_hum error)) : Error.t)]
    in
    (* [..] is made of allowed characters, so the key survives sanitization — the
       containment check is what rejects it. *)
    let%bind () = try_create ".." in
    [%expect
      {|
       "(workspace_outside_root\
      \n (workspace TMP)\
      \n (root TMP/ws))"
      |}];
    let%bind () = try_create "" in
    [%expect
      {|
       "(workspace_equals_root\
      \n (workspace TMP/ws)\
      \n (root TMP/ws))"
      |}];
    (* A symlink inside the root pointing outside is rejected before any hook runs. *)
    let%bind () = Unix.mkdir ~p:() (dir ^/ "outside") in
    let%bind () = Unix.symlink ~link_name:(root ^/ "esc") ~target:(dir ^/ "outside") in
    let%bind () = try_create "esc" in
    [%expect
      {|
       "(workspace_symlink_escape\
      \n (workspace TMP/ws/esc)\
      \n (root TMP/ws))"
      |}];
    (* A symlinked root itself is fine: workspaces land under its canonical target. *)
    let%bind () = Unix.symlink ~link_name:(dir ^/ "ws-link") ~target:root in
    let linked_config = make_config ~root:(dir ^/ "ws-link") ~extra_yaml:"" in
    let%bind () =
      match%map Workspace.create_for_issue ~config:linked_config ~identifier:"MT-5" with
      | Ok created ->
        let%tydi { path; created_now = _ } = created in
        print_s [%sexp (scrub path : string)]
      | Error error -> print_s [%sexp (error : Error.t)]
    in
    [%expect {| TMP/ws/MT-5 |}];
    return ())
;;

let%expect_test "remove: absent is ok; before_remove runs best-effort and cannot block" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let root = dir ^/ "ws" in
    let config =
      make_config
        ~root
        ~extra_yaml:
          "hooks:\n  before_remove: |\n    touch ../removed-marker\n    exit 7\n"
    in
    (* Removing a workspace that never existed is fine. *)
    let%bind () = Workspace.remove_for_issue ~config ~identifier:"MT-9" >>| ok_exn in
    print_string "ok\n";
    [%expect {| ok |}];
    (* The hook runs (leaves a marker), its failure is ignored, removal proceeds. *)
    let%bind () =
      Workspace.create_for_issue ~config ~identifier:"MT-9"
      >>| ok_exn
      >>| (ignore : Workspace.Created.t -> unit)
    in
    let%bind () = Workspace.remove_for_issue ~config ~identifier:"MT-9" >>| ok_exn in
    let%bind marker = Sys.file_exists_exn (root ^/ "removed-marker") in
    let%bind removed = Sys.file_exists_exn (root ^/ "MT-9") >>| not in
    print_s [%message (marker : bool) (removed : bool)];
    [%expect {| ((marker true) (removed true)) |}];
    return ())
;;
