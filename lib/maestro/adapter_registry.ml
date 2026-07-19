open! Core
open Maestro_tracker

let build ?(memory_issues = fun () -> []) (tracker : Maestro_workflow.Config.Tracker.t) =
  match tracker.kind with
  | Some "linear" -> Ok (Maestro_linear.Linear_adapter.create tracker)
  | Some "memory" -> Ok (Memory.create ~issues:memory_issues)
  | Some kind -> Or_error.error_s [%message "unsupported_tracker_kind" kind]
  | None -> Or_error.error_s [%message "missing_tracker_kind"]
;;
