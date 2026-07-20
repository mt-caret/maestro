(** Structured runtime events the app-server client emits upstream to the orchestrator
    (SPEC §10.4).

    [payload] carries the raw protocol message (when there is one) so downstream token
    accounting and humanization interpret it by event type and payload path, never by
    field name alone (SPEC §13.5). *)

open! Core

module Event : sig
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
  [@@deriving sexp, equal]
end

type t =
  { event : Event.t
  ; timestamp : Time_ns.t
  ; codex_app_server_pid : Pid.t option
  ; session_id : string option (** [<thread_id>-<turn_id>] once a turn exists. *)
  ; payload : Jsonaf.t option
  ; detail : string option
  (** Approval decision, auto-answer text, or error summary, when applicable. *)
  }
[@@deriving sexp_of]
