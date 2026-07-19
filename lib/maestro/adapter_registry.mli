(** Maps [tracker.kind] to a tracker adapter (SPEC §11). This is the one place that knows
    the concrete provider set, keeping the provider libraries out of the orchestrator's
    dependencies. *)

open! Core
open Maestro_tracker

(** [build tracker] constructs the adapter for the configured kind, or
    [unsupported_tracker_kind] for an unknown kind. [memory_issues] backs the [memory]
    adapter (default: none). *)
val build
  :  ?memory_issues:(unit -> Issue.t list)
  -> Maestro_workflow.Config.Tracker.t
  -> Adapter.t Or_error.t
