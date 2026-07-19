open! Core
open Maestro_codex

let update ?(event = Update.Event.Notification) ?session_id ?detail ?payload () =
  { Update.event
  ; timestamp = Time_ns.epoch
  ; codex_app_server_pid = None
  ; session_id
  ; payload = Option.map payload ~f:Jsonaf.of_string
  ; detail
  }
;;

let show u = print_string (Humanizer.summarize u)

let%expect_test "event-based and method-based summaries" =
  show (update ~event:Session_started ~session_id:"th-1-tu-2" ());
  [%expect {| session started (th-1-tu-2) |}];
  show (update ~event:Approval_auto_approved ~detail:"acceptForSession" ());
  [%expect {| auto-approved: acceptForSession |}];
  show (update ~event:Turn_input_required ());
  [%expect {| turn blocked: waiting for operator input |}];
  show (update ~event:Unsupported_tool_call ());
  [%expect {| unsupported dynamic tool call rejected |}];
  (* Notifications humanize by JSON-RPC method. *)
  show (update ~payload:{|{"method":"turn/started"}|} ());
  [%expect {| turn started |}];
  show
    (update
       ~payload:{|{"method":"turn/failed","params":{"error":{"message":"boom"}}}|}
       ());
  [%expect {| turn failed: boom |}];
  show
    (update
       ~payload:
         {|{"method":"item/commandExecution/requestApproval","params":{"command":"dune build"}}|}
       ());
  [%expect {| approval requested: dune build |}];
  (* An unknown method falls back to the method name. *)
  show (update ~payload:{|{"method":"future/thing"}|} ());
  [%expect {| future/thing |}]
;;

let%expect_test "control bytes stripped and length capped" =
  (* The JSON tab escape decodes to a control byte the humanizer drops. *)
  show
    (update
       ~payload:{|{"method":"turn/failed","params":{"error":{"message":"ab\tc"}}}|}
       ());
  [%expect {| turn failed: abc |}];
  let long = String.make 200 'x' in
  let summary =
    Humanizer.summarize
      (update
         ~payload:
           [%string {|{"method":"turn/failed","params":{"error":{"message":"%{long}"}}}|}]
         ())
  in
  print_s [%sexp (String.length summary : int)];
  [%expect {| 140 |}]
;;
