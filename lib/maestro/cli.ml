open! Core
open! Async

let ack_flag = "i-understand-that-this-will-be-running-without-the-usual-guardrails"

let guardrails_banner =
  String.concat_lines
    [ "maestro runs a coding agent with the approval and sandbox posture set in"
    ; "WORKFLOW.md. It is intended for trusted environments. Re-run with"
    ; [%string "  --%{ack_flag}"]
    ; "to acknowledge and proceed."
    ]
;;

let command =
  Command.async_or_error
    ~summary:"Orchestrate coding agents across tracker issues (Symphony spec)"
    (let%map_open.Command acknowledged =
       flag
         ("--" ^ ack_flag)
         no_arg
         ~aliases:[ "-" ^ ack_flag ]
         ~doc:" required acknowledgement to run"
     and logs_root =
       flag
         "--logs-root"
         (optional_with_default "." string)
         ~aliases:[ "-logs-root" ]
         ~doc:"DIR log directory (default .)"
     and port =
       flag
         "--port"
         (optional int)
         ~aliases:[ "-port" ]
         ~doc:"PORT enable the HTTP dashboard on PORT"
     and host =
       flag
         "--host"
         (optional string)
         ~aliases:[ "-host" ]
         ~doc:"HOST bind the HTTP dashboard to HOST"
     and reset_scheduler_state =
       flag
         "--reset-scheduler-state"
         no_arg
         ~doc:" replace an unreadable scheduler snapshot with empty state"
     and workflow_path =
       anon (maybe_with_default "./WORKFLOW.md" ("path-to-WORKFLOW.md" %: string))
     in
     fun () ->
       match acknowledged with
       | false ->
         Writer.write_line (force Writer.stderr) guardrails_banner;
         Deferred.Or_error.error_string "missing guardrails acknowledgement"
       | true -> App.run ~workflow_path ~logs_root ~port ~host ~reset_scheduler_state ())
;;
