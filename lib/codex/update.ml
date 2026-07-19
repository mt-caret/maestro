open! Core

module Event = struct
  type t =
    | Session_started
    | Startup_failed
    | Turn_completed
    | Turn_failed
    | Turn_cancelled
    | Turn_input_required
    | Approval_required
    | Approval_auto_approved
    | Tool_input_auto_answered
    | Tool_call_completed
    | Tool_call_failed
    | Unsupported_tool_call
    | Notification
    | Other_message
    | Malformed
    | Turn_ended_with_error
  [@@deriving sexp_of, equal]
end

type t =
  { event : Event.t
  ; timestamp : Time_ns.t
  ; codex_app_server_pid : Pid.t option
  ; session_id : string option
  ; payload : Jsonaf.t option
  ; detail : string option
  }
[@@deriving sexp_of]
