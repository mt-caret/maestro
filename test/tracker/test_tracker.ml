open! Core
open! Async
open Maestro_tracker

let issue
  ?(id = "id-1")
  ?(identifier = "MT-1")
  ?(state = "Todo")
  ?(labels = [])
  ?(dispatchable = true)
  ()
  =
  { Issue.id
  ; native_ref = None
  ; identifier
  ; title = "t"
  ; description = None
  ; priority = None
  ; state
  ; branch_name = None
  ; url = None
  ; assignee_id = None
  ; labels
  ; blocked_by = []
  ; dispatchable
  ; created_at = None
  ; updated_at = None
  }
;;

let%expect_test "routable = dispatchable + every required label, case-insensitively" =
  let show ~labels ~dispatchable ~required_labels =
    print_s
      [%sexp (Issue.routable (issue ~labels ~dispatchable ()) ~required_labels : bool)]
  in
  show ~labels:[ "bug"; "urgent" ] ~dispatchable:true ~required_labels:[ "BUG " ];
  [%expect {| true |}];
  show ~labels:[ "bug" ] ~dispatchable:true ~required_labels:[ "bug"; "urgent" ];
  [%expect {| false |}];
  show ~labels:[ "bug" ] ~dispatchable:false ~required_labels:[];
  [%expect {| false |}];
  show ~labels:[] ~dispatchable:true ~required_labels:[];
  [%expect {| true |}];
  (* A blank configured label matches no issue. *)
  show ~labels:[ "bug" ] ~dispatchable:true ~required_labels:[ "" ];
  [%expect {| false |}];
  return ()
;;

let%expect_test "memory adapter: state and id filtering over a live issue list" =
  let backing =
    ref
      [ issue ~id:"a" ~identifier:"MT-1" ~state:"Todo" ()
      ; issue ~id:"b" ~identifier:"MT-2" ~state:"In Progress" ()
      ; issue ~id:"c" ~identifier:"MT-3" ~state:"Done" ()
      ]
  in
  let adapter = Memory.create ~issues:(fun () -> !backing) in
  let show issues =
    print_s
      [%sexp
        (List.map issues ~f:(fun (issue : Issue.t) -> issue.identifier) : string list)]
  in
  let%bind () =
    adapter.fetch_issues_by_states [ " TODO "; "in progress" ] >>| ok_exn >>| show
  in
  [%expect {| (MT-1 MT-2) |}];
  let%bind () = adapter.fetch_issues_by_states [] >>| ok_exn >>| show in
  [%expect {| () |}];
  let%bind () = adapter.fetch_issues_by_ids [ "c"; "a"; "nope" ] >>| ok_exn >>| show in
  [%expect {| (MT-1 MT-3) |}];
  (* The closure serves the list as of call time. *)
  backing := [ issue ~id:"d" ~identifier:"MT-4" ~state:"Todo" () ];
  let%bind () = adapter.fetch_issues_by_states [ "todo" ] >>| ok_exn >>| show in
  [%expect {| (MT-4) |}];
  let%bind () =
    adapter.execute_agent_tool ~name:"anything" ~arguments:`Null ~context_issue:(issue ())
    >>| fun result -> print_s [%sexp (result : Adapter.Tool_result.t)]
  in
  [%expect
    {|
    ((success false)
     (output
       "{\
      \n  \"error\": {\
      \n    \"message\": \"Unsupported dynamic tool: \\\"anything\\\".\",\
      \n    \"supportedTools\": []\
      \n  }\
      \n}")
     (content_items
      ((Object
        ((type (String inputText))
         (text
          (String
            "{\
           \n  \"error\": {\
           \n    \"message\": \"Unsupported dynamic tool: \\\"anything\\\".\",\
           \n    \"supportedTools\": []\
           \n  }\
           \n}")))))))
    |}];
  return ()
;;
